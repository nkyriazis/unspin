// unspin as a Claude Code mod. While a batched command runs, the step it is
// on shows in Claude Code's own spinner, and the whole flow in the band above
// the prompt, both redrawn from this session's flow file twice a second.
// Nothing to set up: the status line stays yours.
//
// UNSPIN_BAND=0 or UNSPIN_SPINNER=0 turns either off, UNSPIN_ROWS sets how
// many steps the band shows (4).
import { body, brief, glyph, header, parse, pick, settle, type Flow, type Item, type Seg } from './flow.ts'

let sid = ''
let file = ''
let seen = -1
let busy = false
let flow: Flow | undefined
let now = 0
let showBand = true
let showSpinner = true
let rows = 4
let hasProc = false
let ownNs = ''
let checked = 0

// The session's flow file, resolved the way unspin.sh resolves it
async function locate($) {
  showBand = (await $.env.get('UNSPIN_BAND')) !== '0'
  showSpinner = (await $.env.get('UNSPIN_SPINNER')) !== '0'
  rows = Math.max(1, Number((await $.env.get('UNSPIN_ROWS')) ?? '4') || 4)
  hasProc = await $.fs.exists('/proc/self/stat')
  let dir = (await $.env.get('UNSPIN_DIR')) ?? ''
  if (dir === '') {
    const xdg = (await $.env.get('XDG_RUNTIME_DIR')) ?? ''
    if (xdg !== '' && (await $.fs.exists(xdg))) {
      dir = xdg + '/unspin'
    } else {
      const id = await $.process.run(['id', '-u'])
      dir = '/tmp/unspin-' + id.stdout.trim()
    }
  }
  if (hasProc) {
    const link = await $.process.run(['readlink', '/proc/self/ns/pid'])
    ownNs = link.stdout.replace(/[^0-9]/g, '')
  }
  file = dir + '/' + sid.replace(/[^A-Za-z0-9._-]/g, '_') + '.log'
  seen = -1
  flow = undefined
}

// A step whose shell is gone without closing it was interrupted. Across pid
// namespaces (a sandbox) the pid means nothing here, so it counts as alive.
async function alive($, item: Item): Promise<boolean> {
  if (!item.pid) return true
  if (item.ns && ownNs && item.ns !== ownNs) return true
  if (hasProc) return $.fs.exists('/proc/' + item.pid)
  const r = await $.process.run(['kill', '-0', item.pid])
  return r.exitCode === 0
}

// One tick at a time, even when a slow one overlaps the next
async function refresh($) {
  if (busy) return
  busy = true
  try {
    await tick($)
  } finally {
    busy = false
  }
}

// Read the flow again when the file changed, and redraw while it moves. A new
// session id (after /clear, /resume or /branch) means another file.
async function tick($) {
  now = (await $.clock.now()) / 1000
  const id = String(await $.session.id())
  if (id !== sid) {
    sid = id
    await locate($)
  }
  const stat = await $.fs.stat(file).catch(() => undefined)
  if (!stat) {
    if (flow) {
      flow = undefined
      $.ui.invalidate('ui.render')
    }
    return
  }
  let changed = false
  if (stat.mtimeMs !== seen) {
    seen = stat.mtimeMs
    const text = await $.fs.read(file).catch(() => '')
    flow = text ? parse(text) : undefined
    changed = true
  }
  if (!flow) return
  const running = flow.items.filter((i) => i.state === 'run')
  if (running.length > 0 && (changed || now - checked >= 2)) {
    checked = now
    const live = new Set<Item>()
    for (const item of running) if (await alive($, item)) live.add(item)
    settle(flow, (item) => live.has(item))
  }
  if (changed || flow.items.some((i) => i.state === 'run')) $.ui.invalidate('ui.render')
}

export function register(on) {
  // The first tick finds the file; the session does not wait for it.
  on('session.start', async ($, e, next) => {
    $.clock.every(500, () => refresh($))
    return next(e)
  })

  // Claude Code's spinner, with the running step after its word:
  // "Baking · building image 37/72, eta 33s… (1m 12s)"
  on('ui.render', { component: 'Spinner' }, async ($, e, next) => {
    if (!showSpinner || !flow) return next(e)
    const what = brief(flow, now)
    if (!what) return next(e)
    return next({ ...e, props: { ...e.props, suffix: ' · ' + what + '…' } })
  })

  // The band above the prompt: a header and the steps that matter most,
  // with anything other mods draw there kept below.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (!showBand || !flow || e.props.hasSurvey) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const width = e.props.bodyColumns
    const room = Math.max(1, Math.min(rows, e.props.maxRows - 2))
    const draw = (seg: Seg) =>
      seg.color || seg.dim || seg.bold
        ? Text({ color: seg.color, dimColor: seg.dim, bold: seg.bold, children: [seg.text] })
        : seg.text
    const line = (segs: Seg[]) => Text({ wrap: 'truncate-end', children: segs.map(draw) })
    const lines = [line(header(flow, now))]
    for (const item of pick(flow, room)) {
      const cap = item.state === 'run' && item.count ? Math.floor(width * 0.4) : 0
      lines.push(line([{ text: '  ' }, glyph(item, now), { text: ' ' }, ...body(item, now, cap)]))
    }
    const theirs = await next(e)
    return Box({ flexDirection: 'column', children: theirs ? [...lines, theirs] : lines })
  })
}
