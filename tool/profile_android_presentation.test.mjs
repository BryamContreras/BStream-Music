// Host-only CLI tests. Never invoke ADB, a VM service, or write diagnostics.
// node --experimental-vm-modules --test tool/profile_android_presentation.test.mjs
import vm from 'node:vm';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import test from 'node:test';

const source = readFileSync(new URL('./profile_android_presentation.mjs', import.meta.url), 'utf8');
const searchLabel = 'B\u00fasqueda';
async function runCase(extra = [], cfg = {}) {
  const writes = [], calls = [];
  let dumps = 0, snapshots = 0;
  const process = { argv: ['node', 'tool', '--adb', 'fake', '--device', 'fake', '--out', 'ignored.json', '--cycles', '1', ...extra] };
  const points = cfg.empty ? [] : cfg.late ? [[1.6, 1.7]] : [[0.99, 1.005], [1.10, 1.11], [1.12, 1.13], [1.48, 1.49], [1.52, 1.55], [1.60, 1.61], [1.61, 1.62], [1.65, 1.66], [2.08, 2.09], [2.12, 2.15], [2.22, 2.26], [2.26, 2.27]];
  const textRows = (shift = 0) => '8333333\n' + points.map(([r, p]) => `${Math.round(r * 1e9) + shift} ${Math.round(p * 1e9) + shift} ${Math.round((r + 0.001) * 1e9) + shift}`).join('\n') + '\n0 0 0\n9223372036854775807 9223372036854775807 9223372036854775807\n';
  const commandMarkers = (tabs) => {
    const times = tabs ? (cfg.oneTap ? [1, 1.02] : [1, 1.02, 1.52, 1.54]) : [1, 1.5, 1.6, 2.1];
    if (cfg.reverse) times[2] = 1.01;
    if (cfg.missing) times.pop();
    return times.map((t) => `BSTREAM_CLOCK ${Math.round((100 + t) * 1e9)} ${Math.round(t * 1e9)}`).join('\n');
  };
  const run = async (_exe, argv) => {
    const cmd = argv[3]; calls.push(cmd);
    if (cmd === 'pidof process-tracker | wc -w') return { stdout: cfg.trackers ?? '0\n' };
    if (cmd.startsWith('uiautomator dump')) {
      dumps++;
      return { stdout: (cfg.failUiBefore && dumps === 1) || (cfg.failUiAfter && dumps === 2) ? 'ERROR: could not get idle state' : 'UI hierchary dumped to: /sdcard/bstream_presentation_ui.xml\n' };
    }
    if (cmd === 'cat /sdcard/bstream_presentation_ui.xml') return { stdout: cfg.xml ?? `<hierarchy><node content-desc="${cfg.splitLabels && dumps === 1 ? 'Inicio' : 'B&#250;squeda'}"/></hierarchy>` };
    if (cmd === '/data/local/tmp/bstream_profile_clock') return { stdout: cfg.badClock ? 'BSTREAM_CLOCK 9223372036854775807 1\n' : 'BSTREAM_CLOCK 100900000000 900000000\n' };
    if (cmd.includes('180; sleep 0.2')) return { stdout: '' };
    if (cmd === 'dumpsys SurfaceFlinger --list') {
      const p = '1693cac SurfaceView[com.bstream.bstream_music/com.bstream.bstream_music.MainActivity]@0(BLAST)#123';
      return { stdout: cfg.noSurface ? 'global display' : cfg.ambiguous ? p + '\n' + p.replace('#123', '#456') : cfg.plain ? p : 'RequestedLayerState{' + p + '}' };
    }
    if (cmd.startsWith('dumpsys SurfaceFlinger --latency')) {
      snapshots++;
      return { stdout: cfg.vanish && snapshots >= 2 ? '8333333\n' : textRows(cfg.ringLoss && snapshots >= 2 ? 10e9 : 0) };
    }
    if (cmd.startsWith('set -e; for i')) {
      if (cfg.inputFail) throw Error('input failed');
      return { stdout: commandMarkers(cmd.includes('input tap')) };
    }
    throw Error('Unexpected ADB mock command: ' + cmd);
  };
  const context = vm.createContext({ process, console: { log() {} }, setTimeout: (f) => { queueMicrotask(f); return 1; } });
  const modules = {
    'node:child_process': { execFile: run },
    'node:fs/promises': { mkdir: async () => {}, writeFile: async (_p, s) => writes.push(JSON.parse(s)), readFile: async (p) => { assert.equal(p, 'coords.json'); return '[[10,20],[30,40]]'; } },
    'node:path': { dirname: () => '.' }, 'node:util': { promisify: (f) => f },
  };
  const module = new vm.SourceTextModule(source, { context });
  await module.link((name) => {
    const exports = modules[name];
    return new vm.SyntheticModule(Object.keys(exports), function () { for (const [k, v] of Object.entries(exports)) this.setExport(k, v); }, { context });
  });
  try { await module.evaluate(); return { result: writes.at(-1), calls, process }; }
  catch (error) { return { error, writes, calls, process }; }
}

test('scroll native defaults: merged tails, long gaps, safe pending-row rejection', async () => {
  const a = await runCase(); assert.ifError(a.error);
  assert.equal(a.result.summary.nativeOnly, true);
  assert.equal(a.result.summary.presentation.activeIntervals, 4);
  assert.equal(a.result.summary.presentationWithTail.intervals, 9);
  assert.equal(a.result.summary.presentationWithTail.over100ms, 3);
  assert.equal(a.result.presentationFramesWithTail.length, 10);
  assert.ok(a.calls.findIndex((c) => c.startsWith('dumpsys SurfaceFlinger --latency')) < a.calls.findIndex((c) => c.startsWith('set -e; for i')));
});
test('zero/max tails and plain surface-name compatibility', async () => {
  const z = await runCase(['--motion-tail-ms', '0']); assert.ifError(z.error);
  assert.deepEqual(z.result.summary.presentation.intervalMs, z.result.summary.presentationWithTail.intervalMs);
  const m = await runCase(['--motion-tail-ms', '500']); assert.ifError(m.error); assert.equal(m.result.presentationFramesWithTail.length, 11);
  const p = await runCase([], { plain: true }); assert.ifError(p.error); assert.match(p.result.summary.presentation.surfaceName, /^1693cac SurfaceView/);
});
test('VM profiler discovers Android14 bare and Android16 wrapped app surfaces', async () => {
  const profileSource = readFileSync(new URL('./profile_android_scroll.mjs', import.meta.url), 'utf8');
  // Execute the actual discovery block without connecting to a VM or device.
  const discovery = profileSource.match(/  const layers = await run\([\s\S]*?  surfaceName = candidates\[0\];/)?.[0];
  assert.ok(discovery, 'VM profiler discovery block must remain covered');
  const subject = new vm.Script(`(async () => { let surfaceName; ${discovery} return surfaceName; })()`);
  const discover = (stdout) => subject.runInNewContext({ run: async () => ({ stdout }), options: new Map([['--adb', 'fake'], ['--device', 'fake']]) });
  const bare = 'SurfaceView[com.bstream.bstream_music/com.bstream.bstream_music.MainActivity]@0(BLAST)#28711';
  const modern = `1693cac ${bare}`;
  assert.equal(await discover(bare), bare);
  assert.equal(await discover(`RequestedLayerState{${modern}}`), modern);
  assert.equal(await discover(`${bare}\n${bare}`), bare);
  await assert.rejects(discover(`${bare}\n${bare.replace('#28711', '#28712')}`), /unambiguous/);
  await assert.rejects(discover('Display0\nSurfaceView[other.app/Activity]@0(BLAST)#1'), /unambiguous/);
});
test('UI exact numeric entities and reset execute only before/after capture', async () => {
  const a = await runCase(['--expect-label', searchLabel, '--reset-scroll', 'true']); assert.ifError(a.error);
  const input = a.calls.findIndex((c) => c.startsWith('set -e; for i') && !c.includes('180; sleep'));
  const dumps = a.calls.flatMap((v, i) => v.startsWith('uiautomator dump') ? [i] : []);
  assert.ok(dumps[0] < input && dumps[1] > input);
  assert.equal(a.result.summary.uiVerification.after.passed, true);
});
test('tabs: separate labels, bounded actual-present proxy, per-transition frame count', async () => {
  const a = await runCase(['--mode', 'tabs', '--taps', '[[10,20],[30,40]]', '--expect-label-before', 'Inicio', '--expect-label-after', searchLabel], { splitLabels: true }); assert.ifError(a.error);
  assert.equal(a.result.transitions.length, 2);
  assert.equal(a.result.transitions[0].firstPresentationAfterTapProxy.latencyMs, 5);
  assert.equal(a.result.transitions[0].firstPresentationAfterTapProxy.requestedBeforeTapMarker, true);
  assert.equal(a.result.transitions[0].presentation.frames, 3);
  assert.match(a.result.summary.firstPresentationAfterTapProxy.limitation, /NOT first destination-tab/);
  assert.ok(a.calls.some((c) => c.includes('input tap 10 20') && c.includes('sleep 0.5')));
  const f = await runCase(['--mode', 'tabs', '--taps-file', 'coords.json']); assert.ifError(f.error); assert.equal(f.result.transitions[1].x, 30);
  const l = await runCase(['--mode', 'tabs', '--taps', '[[1,2]]'], { oneTap: true, late: true }); assert.match(l.error.message, /No app frame presented/); assert.equal(l.writes.length, 0);
});
test('clock/input/surface failures abort without publishing', async () => {
  for (const [cfg, re] of [[{ ambiguous: true }, /unambiguous/], [{ noSurface: true }, /unambiguous/], [{ badClock: true }, /safe integers/], [{ missing: true }, /Expected 4/], [{ reverse: true }, /strictly increasing/], [{ empty: true }, /No app presentation/], [{ inputFail: true }, /input failed/], [{ trackers: '5' }, /process-tracker/]]) {
    const a = await runCase([], cfg); assert.match(a.error.message, re); assert.equal(a.writes.length, 0);
  }
});
test('failed/stale UI dump and substring labels never publish', async () => {
  for (const cfg of [{ failUiBefore: true }, { failUiAfter: true }, { xml: '<hierarchy><node content-desc="B&#250;squeda extra"/></hierarchy>' }]) {
    const a = await runCase(['--expect-label', searchLabel], cfg); assert.match(a.error.message, /screen verification/); assert.equal(a.writes.length, 0);
  }
});
test('ring loss and vanished surface are explicitly incomplete with exit1', async () => {
  for (const cfg of [{ ringLoss: true }, { vanish: true }]) {
    const a = await runCase([], cfg); assert.ifError(a.error); assert.equal(a.process.exitCode, 1); assert.equal(a.result.summary.presentationWithTail.reliableCoverage, false); assert.ok(a.result.summary.presentationWithTail.errors.length);
  }
});
test('invalid CLI parameters fail before any device command', async () => {
  const cases = [['--motion-tail-ms', '-1'], ['--motion-tail-ms', '501'], ['--motion-tail-ms', ''], ['--motion-tail-ms', 'NaN'], ['--clock-helper', '/data/local/tmp/a;echo'], ['--mode', 'tabs'], ['--mode', 'tabs', '--taps', '[[1080,1]]'], ['--mode', 'tabs', '--taps', '[[1.1,2]]'], ['--mode', 'tabs', '--taps', '[]'], ['--mode', 'tabs', '--taps', '[[1,2]]', '--taps-file', 'coords.json'], ['--mode', 'tabs', '--taps', '[[1,2]]', '--reset-scroll', 'true'], ['--expect-label', ''], ['--expect-label', 'x'.repeat(121)], ['--expect-label', 'a\0b'], ['--tap-wait-ms', '99'], ['--width', '-1'], ['--cycles', '0'], ['--mode', 'idle'], ['--unknown', 'true']];
  for (const args of cases) { const a = await runCase(args); assert.ok(a.error, args.join(' ')); assert.equal(a.calls.length, 0); }
});
