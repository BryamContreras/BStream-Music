import test from 'node:test';
import assert from 'node:assert/strict';
import { distribution, parseOptions, summarizeFrames, tabLatencies, validateWindows } from './profile_windows_frames.mjs';

const frame = (startTime, build = 2000, raster = 5000) => ({ startTime, build, raster, vsyncOverhead: 100, elapsed: build + raster + 100 });

test('distributions retain worst samples and empty timing stays unavailable', () => {
  assert.equal(distribution([]), null);
  assert.deepEqual(distribution([33, 16, 17]), { count: 3, mean: 22, p50: 17, p90: 33, p95: 33, p99: 33, max: 33 });
  assert.throws(() => distribution([NaN]));
});

test('framework cadence is never silently advertised as screen FPS', () => {
  const sample = [frame(1000), frame(17667), frame(150000)];
  const whole = summarizeFrames(sample, 60);
  assert.equal(whole.frameworkCadenceFps, null);
  assert.equal(whole.buildStartIntervalMs.max, 132.333);
  const continuous = summarizeFrames(sample.slice(0, 2), 60, true);
  assert.ok(Math.abs(continuous.frameworkCadenceFps - 60) < 0.01);
  assert.equal(summarizeFrames([], 60, true).frameworkCadenceFps, null);
});

test('build and raster budget checks do not add pipelined thread durations', () => {
  const summary = summarizeFrames([frame(0, 10000, 10000), frame(16667, 17000, 20000)], 60);
  assert.equal(summary.slowBuildFrames, 1);
  assert.equal(summary.slowRasterFrames, 1);
  assert.equal(summary.slowPipelineFrames, 1);
});

test('window validation rejects overlap, invalid clocks, and capture-edge leakage', () => {
  assert.deepEqual(validateWindows([{ startUnixMs: 110, endUnixMs: 120 }], 100, 200), [{ startUnixMs: 110, endUnixMs: 120 }]);
  for (const value of [null, {}, [{ startUnixMs: 0, endUnixMs: 120 }], [{ startUnixMs: 120, endUnixMs: 120 }], [{ startUnixMs: 110, endUnixMs: Infinity }], [{ startUnixMs: 110, endUnixMs: 150 }, { startUnixMs: 140, endUnixMs: 160 }]]) {
    assert.throws(() => validateWindows(value, 100, 200));
  }
  assert.deepEqual(validateWindows([{ startQpcMs: 110, endQpcMs: 120 }], 100, 200, 'qpc'), [{ startQpcMs: 110, endQpcMs: 120 }]);
  assert.throws(() => validateWindows([{ startUnixMs: 110, endUnixMs: 120 }], 100, 200, 'qpc'));
});

test('latencies require matching request and selection and remain framework-only', () => {
  const result = tabLatencies([
    { name: 'BStream.tab.request', ts: 1000, args: { requestId: 1, from: 0, to: 1 } },
    { name: 'BStream.tab.firstBuildComplete', ts: 6000, args: { requestId: 1, to: 1, stillSelected: true } },
    { name: 'BStream.tab.request', ts: 9000, args: { requestId: 2, from: 1, to: 2 } },
    { name: 'BStream.tab.firstBuildComplete', ts: 12000, args: { requestId: 2, to: 2, stillSelected: false } },
    { name: 'BStream.tab.request', ts: 15000, args: { requestId: 3, from: 2, to: 0 } },
  ]);
  assert.equal(result.handlerToFirstBuildMs.mean, 5);
  assert.equal(result.matches.length, 2);
  assert.equal(result.missingCompletions.length, 1);
});

test('CLI validates finite durations, flags and URI protocols before connecting', () => {
  const required = ['--uri', 'http://127.0.0.1:123/TOKEN=/', '--out', 'result.json'];
  assert.equal(parseOptions(required).uri.href, 'ws://127.0.0.1:123/TOKEN=/ws');
  assert.equal(parseOptions([...required, '--tab-markers', 'true']).tabMarkers, true);
  for (const rest of [['--seconds', 'NaN'], ['--seconds', '0'], ['--hz', '0'], ['--tab-markers', 'yes'], ['--unknown', 'x'], ['--out', 'other'], ['--seconds']]) {
    assert.throws(() => parseOptions([...required, ...rest]));
  }
  assert.throws(() => parseOptions(['--uri', 'file:///abc', '--out', 'x']));
});
