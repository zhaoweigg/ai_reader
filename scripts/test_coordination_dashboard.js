const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const {test} = require('node:test');
const vm = require('node:vm');

const html = readFileSync(join(__dirname, 'coordination_dashboard.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const start = '2026-10-23T20:00:00.000000+00:00';
const startMs = Date.parse(start);

// Exercise the shipped inline script, including its scheduler and DOM updates,
// with a deterministic clock and a registry response that can remain unchanged.
async function dashboard(slots = {}) {
  class Element {
    constructor(tag) { this.tag = tag; this.children = []; this.attributes = {}; this.style = {}; this._text = ''; this.classList = {add() {}, remove() {}}; }
    set textContent(value) { this._text = value; this.children = []; }
    get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
    append(...children) { this.children.push(...children); }
    replaceChildren(...children) { this._text = ''; this.children = children; }
    setAttribute(name, value) { this.attributes[name] = value; }
  }
  const elements = new Map();
  const intervals = [], timeouts = [];
  let now = startMs + 62_900;
  let state = {updated_at: start, agents: {}, slots, slot_requests: []};
  let available = true;
  class Clock extends Date { static now() { return now; } }
  const context = vm.createContext({Date: Clock, document: {
    createElement: tag => new Element(tag),
    getElementById: id => { if (!elements.has(id)) elements.set(id, new Element('div')); return elements.get(id); },
  }, fetch: async () => ({ok: available, json: async () => state}),
  setInterval: (callback, delay) => intervals.push({callback, delay}),
  setTimeout: (callback, delay) => timeouts.push({callback, delay})});
  vm.runInContext(script, context);
  await new Promise(setImmediate);
  return {context, elements, intervals, timeouts,
    advance: ms => { now += ms; intervals.forEach(interval => interval.callback()); },
    poll: async next => { state = next || state; await context.refresh(); },
    disconnect: async () => { available = false; await context.refresh(); },
    runtime: slot => ({...context.runtimeDisplay(slot, now)}),
    texts: () => elements.get('slots').children.map(article => article.children[1].children.find(child => child.className === 'runtime').textContent),
  };
}

test('formats whole seconds, minute/hour rollover, zero and runs longer than a day', async () => {
  const {context} = await dashboard();
  for (const [seconds, expected] of [[0, '00:00:00'], [59.999, '00:00:59'], [60, '00:01:00'], [3599, '00:59:59'], [3600, '01:00:00'], [90061, '25:01:01']]) {
    assert.equal(context.formatRuntime(seconds), expected);
  }
});

test('ticks once per second without registry changes and renders any number of slots', async () => {
  const running = {state: 'testing', started_at: start};
  const ui = await dashboard({A: running, B: running, C: running});
  assert.equal(ui.elements.get('slot-summary').textContent, '3 devices, one owner per device.');
  assert.deepEqual(ui.texts(), Array(3).fill('Job runtime 00:01:02'));
  assert.deepEqual(ui.intervals.map(timer => timer.delay), [1000]);
  ui.advance(1000);
  assert.deepEqual(ui.texts(), Array(3).fill('Job runtime 00:01:03'));
  await ui.poll(); // Identical JSON must not stop the independent clock.
  ui.advance(1000);
  assert.deepEqual(ui.texts(), Array(3).fill('Job runtime 00:01:04'));
  for (const article of ui.elements.get('slots').children) {
    assert.equal(article.children[1].children.find(child => child.className === 'runtime').attributes['aria-live'], 'off');
  }
});

test('finished testing/finalizing/completed runs freeze using persisted monotonic elapsed time', async () => {
  const ui = await dashboard();
  for (const state of ['testing', 'finalizing', 'completed']) {
    const slot = {state, started_at: start, finished_at: '2026-10-23T20:00:40Z', elapsed_seconds: 39.8};
    assert.deepEqual(ui.runtime(slot), {label: 'Job runtime', value: '00:00:39', note: 'Finished'});
    ui.advance(60000);
    assert.equal(ui.runtime(slot).value, '00:00:39');
    delete slot.elapsed_seconds;
    assert.equal(ui.runtime(slot).value, '00:00:40');
    for (const invalid of [-1, '40', null, Infinity, NaN, Number.MAX_VALUE]) {
      slot.elapsed_seconds = invalid;
      assert.equal(ui.runtime(slot).value, '00:00:40');
    }
  }
});

test('completion and release stop the old clock; a new lease cannot inherit last-run timing', async () => {
  const ui = await dashboard({A: {state: 'testing', started_at: start}});
  const last_run = {lease_id: 'old', started_at: start, finished_at: '2026-10-23T20:00:50Z', elapsed_seconds: 49.9};
  await ui.poll({slots: {A: {state: 'finalizing', ...last_run}}});
  assert.deepEqual(ui.texts(), ['Job runtime 00:00:49 · Finished']);
  ui.advance(10000);
  assert.deepEqual(ui.texts(), ['Job runtime 00:00:49 · Finished']);
  for (const state of ['available', 'released']) {
    await ui.poll({slots: {A: {state, last_run}}});
    ui.advance(10000);
    assert.deepEqual(ui.texts(), ['Last job runtime 00:00:49 · Finished']);
  }
  for (const state of ['assigned', 'reserved']) {
    await ui.poll({slots: {A: {state, last_run, ...last_run}}});
    assert.deepEqual(ui.texts(), ['Job runtime — · Not started']);
  }
  await ui.poll({slots: {A: {state: 'testing', last_run}}});
  assert.deepEqual(ui.texts(), ['Job runtime — · Start time unavailable']);
});

test('never substitutes assignment/ack times or displays invalid, future or reversed clocks', async () => {
  const ui = await dashboard();
  const assigned = {assigned_at: start, start_acknowledged_at: start};
  assert.equal(ui.runtime({state: 'testing', ...assigned}).value, '—');
  for (const started_at of [undefined, null, 0, '', 'invalid', '2026-02-30T20:00:00Z', '2026-10-23', '2026-10-23T20:00:00', '2026-10-23T20:00:00-07:00', '2027-10-23T20:00:00Z']) {
    assert.equal(ui.runtime({state: 'testing', started_at, ...assigned}).value, '—');
  }
  for (const finished_at of ['', 'invalid', '2026-10-23T19:59:59Z']) {
    assert.equal(ui.runtime({state: 'completed', started_at: start, finished_at, elapsed_seconds: 50}).value, '—');
  }
  assert.equal(ui.runtime({state: 'finalizing', started_at: start}).value, '—');
  assert.equal(ui.runtime({state: 'available', last_run: {started_at: start}}).value, '—');
  assert.equal(ui.runtime({state: 'testing', finished_at: '2026-10-23T20:01:00Z', elapsed_seconds: 60}).value, '—');
});

test('registry failure retains last assignment and visibly reports disconnected state', async () => {
  const ui = await dashboard({A: {state: 'testing', started_at: start}});
  await ui.disconnect();
  assert.equal(ui.elements.get('connection').textContent, 'Disconnected');
  assert.match(ui.elements.get('error').textContent, /last received assignments/);
  ui.advance(1000);
  assert.deepEqual(ui.texts(), ['Job runtime 00:01:03']);
  assert.ok(ui.timeouts.every(timer => timer.delay === 2000));
});
