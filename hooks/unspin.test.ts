import { expect, mock, test } from 'claude-code/testing'

const NOW = 1792047075
const FLOW = [
  '@1792047000.100 Ship the release [6]',
  '▶ @1792047000.200 id=1.1 pid=100 installing dependencies',
  '✔ @1792047014.400 id=1.1',
  '▶ @1792047015.800 id=1.3 pid=100 running tests',
  '% @1792047039.000 id=1.3 120/120 test_120.py',
  '✘ @1792047039.100 id=1.3 1 of 120 failed',
  '· @1792047039.200 test_88.py is a known flake',
  '▶ @1792047039.300 id=1.4 pid=100 building image',
  '% @1792047040.000 id=1.4 0/72 starting',
  '% @1792047070.000 id=1.4 37/72 layer 12',
].join('\n')

// Answer everything the mod asks Claude Code for, with this flow on disk
function world(on, text: string, opts: { alive?: boolean; sid?: string; missing?: boolean } = {}) {
  const clock = mock.clock(on, { now: NOW * 1000 })
  mock.env(on, { XDG_RUNTIME_DIR: '/run/user/1000' })
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: opts.sid ?? 'abc-123' }))
  on('fs.exists', ($, e) => ({ value: e.path.startsWith('/proc/') ? opts.alive !== false || e.path === '/proc/self/stat' : true }))
  on('fs.stat', ($, e) =>
    !opts.missing && e.path === '/run/user/1000/unspin/' + (opts.sid ?? 'abc-123') + '.log'
      ? { value: { kind: 'file', size: text.length, mtimeMs: 1, isLink: false } }
      : { deny: 'ENOENT' },
  )
  on('fs.read', () => ({ value: text }))
  on('process.run', ($, e) => ({ value: { exitCode: 0, stdout: e.argv[0] === 'readlink' ? 'pid:[4026531836]\n' : '1000\n', stderr: '' } }))
  on('ui.render', ($, e) => ({ type: 'Text', props: {}, children: [e.component === 'Spinner' ? e.props.word + e.props.suffix : ''] }))
  return clock
}

const BAND = {
  plugin: 'unspin',
  component: 'AbovePrompt',
  requestId: 'band',
  viewport: { columns: 100, rows: 30 },
  props: { hasSurvey: false, isWorking: true, maxRows: 12, bodyColumns: 100, scroll: { offset: 0, bodyRows: 11 }, view: {} },
} as const

const SPINNER = {
  plugin: 'unspin',
  component: 'Spinner',
  requestId: 'main',
  viewport: { columns: 100, rows: 30 },
  props: { word: 'Baking', message: null, suffix: '…', mode: 'tool-use' },
} as const

test('the band shows the flow, failures kept in view', async ($, on) => {
  const clock = world(on, FLOW)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await clock.advance(500)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /Ship the release/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /step 3\/6/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /running tests/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /37\/72/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /eta 33s/ })).toBeDefined()
})

test('the spinner says which step is running', async ($, on) => {
  const clock = world(on, FLOW)
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await clock.advance(500)
  const ui = await $.ui.mount({ ...SPINNER, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: 'Baking · building image 37/72, eta 33s…' })).toBeDefined()
})

test('a step whose shell died shows as interrupted', async ($, on) => {
  const clock = world(on, FLOW, { alive: false })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await clock.advance(500)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await band.find({ type: 'Text', text: /interrupted/ })).toBeDefined()
  const spin = await $.ui.mount({ ...SPINNER, surface: 'terminal' })
  expect(await spin.find({ type: 'Text', text: 'Baking…' })).toBeDefined()
})

test('no flow file, nothing drawn', async ($, on) => {
  const clock = world(on, FLOW, { missing: true })
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await clock.advance(500)
  const spin = await $.ui.mount({ ...SPINNER, surface: 'terminal' })
  expect(await spin.find({ type: 'Text', text: 'Baking…' })).toBeDefined()
})
