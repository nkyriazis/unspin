// The flow file (docs/protocol.md) as data, and what unspin draws from it.
// The same rules as skills/unspin/lib/render.awk, which the status line uses.

export type State = 'run' | 'ok' | 'fail' | 'stale' | 'note'

export interface Item {
  state: State
  text: string
  t0?: number
  t1?: number
  pid?: string
  ns?: string
  // Both times carry fractions, so a short duration can show tenths
  precise?: boolean
  detail?: string
  count?: string
  label?: string
  // First and latest numeric readings of the count, for the rate behind the ETA
  n0?: number
  at0?: number
  nl?: number
}

export interface Flow {
  title: string
  total?: string
  started?: number
  last?: number
  items: Item[]
  steps: number
}

// A piece of a drawn line, with its look
export interface Seg {
  text: string
  color?: 'green' | 'red' | 'yellow'
  dim?: boolean
  bold?: boolean
}

const GLYPHS = ['▶', '✔', '✘', '·', '%']
const KEYS: Record<string, string[]> = { '▶': ['id', 'pid', 'ns'], '✔': ['id'], '✘': ['id'], '%': ['id'], '·': [] }

// Strip "@ts" and the key=value tokens a glyph may carry (each key once)
function meta(s: string, keys: string[]): { rest: string; ts?: number; fine: boolean; m: Record<string, string> } {
  const m: Record<string, string> = {}
  const first = /^@(\d+(?:\.\d+)?)(?: |$)/.exec(s)
  if (!first) return { rest: s, fine: false, m }
  let rest = s.slice(first[0].length)
  for (;;) {
    const tok = /^([a-z]+)=(\S*)(?: |$)/.exec(rest)
    if (!tok || !keys.includes(tok[1]) || tok[1] in m) break
    m[tok[1]] = tok[2]
    rest = rest.slice(tok[0].length)
  }
  return { rest, ts: Number(first[1]), fine: first[1].includes('.'), m }
}

function clean(s: string): string {
  return s.replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, '').replace(/[\x00-\x1f\x7f]/g, ' ')
}

export function parse(text: string): Flow {
  const flow: Flow = { title: '', items: [], steps: 0 }
  const byId = new Map<string, Item>()
  const lines = text.split('\n')
  const lastRunning = () => {
    for (let i = flow.items.length - 1; i >= 0; i--) if (flow.items[i].state === 'run') return flow.items[i]
    return undefined
  }
  const stamp = (ts?: number) => {
    if (ts !== undefined && (flow.last === undefined || ts > flow.last)) flow.last = ts
  }
  lines.forEach((raw, i) => {
    if (raw === '') return
    const line = clean(raw)
    const glyph = GLYPHS.find((g) => line.startsWith(g + ' '))
    if (i === 0 && !glyph) {
      let t = line
      const at = /^@(\d+(?:\.\d+)?) /.exec(t)
      if (at) {
        flow.started = Number(at[1])
        t = t.slice(at[0].length)
      }
      const total = / \[(\d+)\]$/.exec(t)
      if (total) {
        flow.total = total[1]
        t = t.slice(0, total.index)
      }
      flow.title = t
      return
    }
    if (!glyph) {
      if (/\S/.test(line)) flow.items.push({ state: 'note', text: line })
      return
    }
    const { rest, ts, fine, m } = meta(line.slice(glyph.length + 1), KEYS[glyph])
    stamp(ts)
    const target = m.id !== undefined ? byId.get(m.id) : lastRunning()
    switch (glyph) {
      case '▶': {
        const item: Item = { state: 'run', text: rest, t0: ts, precise: fine, pid: /^\d+$/.test(m.pid ?? '') ? m.pid : undefined, ns: m.ns }
        flow.items.push(item)
        if (m.id !== undefined) byId.set(m.id, item)
        flow.steps++
        break
      }
      case '✔':
      case '✘': {
        const state = glyph === '✔' ? 'ok' : 'fail'
        if (target && target.state === 'run') {
          target.state = state
          target.t1 = ts
          target.precise = target.precise && fine
          target.detail = rest
        } else if (!target) {
          flow.items.push({ state, text: rest, t0: ts })
          flow.steps++
        }
        break
      }
      case '%': {
        if (!target || target.state !== 'run') break
        const sp = rest.indexOf(' ')
        const count = sp < 0 ? rest : rest.slice(0, sp)
        target.label = sp < 0 ? '' : rest.slice(sp + 1)
        if (count === '-' || count === '') break
        target.count = count
        const f = frac(count)
        if (f) {
          if (target.n0 === undefined) {
            target.n0 = f.n
            target.at0 = ts
          }
          target.nl = f.n
        }
        break
      }
      case '·':
        flow.items.push({ state: 'note', text: rest, t0: ts })
        break
    }
  })
  return flow
}

// Steps whose shell is gone without closing them were interrupted
export function settle(flow: Flow, isAlive: (item: Item) => boolean): Flow {
  for (const item of flow.items) if (item.state === 'run' && !isAlive(item)) item.state = 'stale'
  return flow
}

const MULT: Record<string, number> = { K: 1e3, M: 1e6, G: 1e9, T: 1e12, P: 1e15 }
const MULTI: Record<string, number> = { K: 1024, M: 1024 ** 2, G: 1024 ** 3, T: 1024 ** 4 }

function mult(unit: string): number {
  const c = unit.charAt(0).toUpperCase()
  if (/^[KMGT]i/.test(unit)) return MULTI[c] ?? 1
  return MULT[c] ?? 1
}

// "N/T", "P%" with optional units ("12s/60s", "1.5G/4G")
export function frac(count: string): { n: number; t: number; unit: string } | undefined {
  const pct = /^(\d+(?:\.\d+)?)%$/.exec(count)
  if (pct) return { n: Number(pct[1]), t: 100, unit: '%' }
  const m = /^(\d+(?:\.\d+)?)([A-Za-z]*)\/(\d+(?:\.\d+)?)([A-Za-z]*)$/.exec(count)
  if (!m) return undefined
  const t = Number(m[3]) * mult(m[4])
  if (!(t > 0)) return undefined
  return { n: Number(m[1]) * mult(m[2]), t, unit: m[4] }
}

export function dur(d: number, precise = false): string {
  if (!(d > 0)) d = 0
  if (d < 10 && precise) return d.toFixed(1) + 's'
  if (d < 60) return Math.floor(d) + 's'
  if (d < 3600) return Math.floor(d / 60) + 'm' + String(Math.floor(d % 60)).padStart(2, '0') + 's'
  return Math.floor(d / 3600) + 'h' + String(Math.floor((d % 3600) / 60)).padStart(2, '0') + 'm'
}

// Ten cells: a heavy line for the part done and a light one for the rest,
// meeting in a half cell
export function bar(n: number, t: number, cells = 10): [done: string, rest: string] {
  const f = Math.min(1, Math.max(0, t > 0 ? n / t : 0))
  const h = Math.floor(f * cells * 2)
  const done = '━'.repeat(Math.floor(h / 2)) + (h % 2 ? '╾' : '')
  return [done, '─'.repeat(cells - Math.ceil(h / 2))]
}

function eta(item: Item, now: number): number | undefined {
  const f = item.count ? frac(item.count) : undefined
  if (!f || f.unit === 's' || f.unit === '%' || f.n >= f.t) return undefined
  if (item.at0 === undefined || item.n0 === undefined || item.nl === undefined) return undefined
  if (now - item.at0 < 2 || item.nl <= item.n0) return undefined
  const rate = (item.nl - item.n0) / (now - item.at0)
  const left = (f.t - f.n) / rate
  return left >= 1 ? left : undefined
}

const SPIN = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

export function spinner(now: number, perSecond = 2): string {
  return SPIN[Math.floor(now * perSecond) % SPIN.length]
}

export function counts(flow: Flow) {
  let running = 0
  let failed = 0
  let stale = 0
  for (const item of flow.items) {
    if (item.state === 'run') running++
    else if (item.state === 'fail') failed++
    else if (item.state === 'stale') stale++
  }
  return { running, failed, stale }
}

// The header: what the flow is and how far along
export function header(flow: Flow, now: number): Seg[] {
  const { running, failed, stale } = counts(flow)
  const start = flow.started ?? flow.items.find((i) => i.t0 !== undefined)?.t0
  const title = flow.title || 'flow'
  if (running) {
    let meta = 'step ' + flow.steps + (flow.total ? '/' + flow.total : '')
    if (running > 1) meta += ' · ' + running + ' running'
    if (start !== undefined) meta += ' · ' + dur(now - start)
    return [{ text: '▶ ', color: 'yellow' }, { text: title, bold: true }, { text: '  ' + meta, dim: true }]
  }
  let meta = flow.steps + (flow.steps === 1 ? ' step' : ' steps')
  if (failed) meta += ', ' + failed + ' failed'
  if (stale) meta += ', ' + stale + ' interrupted'
  if (start !== undefined && flow.last !== undefined) meta += ' · ' + dur(flow.last - start)
  const bad = failed + stale > 0
  return [{ text: bad ? '✘ ' : '✔ ', color: bad ? 'red' : 'green' }, { text: title, bold: true }, { text: '  ' + meta, dim: true }]
}

// One step or note, without its glyph
export function body(item: Item, now: number, textCap = 0): Seg[] {
  const cap = (s: string) => (textCap > 0 && s.length > textCap ? s.slice(0, textCap - 1) + '…' : s)
  if (item.state === 'note') return [{ text: item.text, dim: true }]
  if (item.state === 'run') {
    const segs: Seg[] = [{ text: cap(item.text), color: 'yellow' }]
    const el = item.t0 !== undefined ? now - item.t0 : -1
    const f = item.count ? frac(item.count) : undefined
    if (f) {
      if (f.unit !== 's' && el >= 1) segs.push({ text: ' ' + dur(el), dim: true })
      const [done, rest] = bar(f.n, f.t)
      segs.push({ text: '  ' }, { text: done, color: 'yellow' }, { text: rest, dim: true }, { text: ' ' })
      segs.push({ text: item.count! })
      const left = eta(item, now)
      if (left !== undefined) segs.push({ text: ' · eta ' + dur(left), dim: true })
    } else {
      if (el >= 1) segs.push({ text: ' ' + dur(el), dim: true })
      if (item.count) segs.push({ text: ' · ' + item.count })
    }
    if (item.label) segs.push({ text: ' · ' + item.label, dim: true })
    return segs
  }
  const segs: Seg[] = [{ text: item.text }]
  const f = item.count ? frac(item.count) : undefined
  if (item.count && !(f && f.unit === 's')) segs.push({ text: ' ' + item.count })
  if (item.state === 'stale') {
    segs.push({ text: ' — interrupted', color: 'red' })
    return segs
  }
  const d = item.detail ?? ''
  if (item.t0 === undefined && /^[0-9.]+m?[0-9.]*s$/.test(d)) {
    segs.push({ text: ' ' + d, dim: true })
    return segs
  }
  if (d) segs.push({ text: ' — ' + d })
  if (item.t0 !== undefined && item.t1 !== undefined) segs.push({ text: ' ' + dur(item.t1 - item.t0, item.precise), dim: true })
  return segs
}

export function glyph(item: Item, now: number): Seg {
  switch (item.state) {
    case 'run':
      return { text: spinner(now), color: 'yellow' }
    case 'ok':
      return { text: '✔', color: 'green' }
    case 'fail':
    case 'stale':
      return { text: '✘', color: 'red' }
    default:
      return { text: '·', dim: true }
  }
}

// Which items get a row: running steps first, then failures, then the most
// recent, shown in their original order
export function pick(flow: Flow, rows: number): Item[] {
  const chosen = new Set<number>()
  const want = (test: (i: Item) => boolean) => {
    for (let i = flow.items.length - 1; i >= 0 && chosen.size < rows; i--) if (test(flow.items[i])) chosen.add(i)
  }
  want((i) => i.state === 'run')
  want((i) => i.state === 'fail' || i.state === 'stale')
  want(() => true)
  return [...chosen].sort((a, b) => a - b).map((i) => flow.items[i])
}

// For Claude Code's spinner: the step that is running now, in a few words
export function brief(flow: Flow, now: number): string {
  const running = flow.items.filter((i) => i.state === 'run')
  if (running.length === 0) return ''
  const cur = running[running.length - 1]
  let s = cur.text.length > 40 ? cur.text.slice(0, 39) + '…' : cur.text
  const f = cur.count ? frac(cur.count) : undefined
  if (f && f.unit !== 's') {
    s += ' ' + cur.count
    const left = eta(cur, now)
    if (left !== undefined) s += ', eta ' + dur(left)
  } else if (cur.label) {
    s += ': ' + (cur.label.length > 30 ? cur.label.slice(0, 29) + '…' : cur.label)
  }
  if (running.length > 1) s += ' (+' + (running.length - 1) + ' more)'
  return s
}
