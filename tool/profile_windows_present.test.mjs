import test from 'node:test';
import assert from 'node:assert/strict';
import { analyzeNative, normalizeNativeFrames, parseNativeCapture } from './profile_windows_present.mjs';

const nativeFrame = (ms, delay = 10, extra = {}) => ({
  swapChain: 100, cpuStartQpc: ms * 10, presentStartQpc: (ms + 2) * 10,
  displayedTimeMs: 16, displayLatencyMs: delay + 2, untilDisplayedMs: delay,
  presentMode: 3, presentRuntime: 1, frameType: 2, ...extra,
});
const capture = (frames) => ({
  source: 'existing-PresentMon-service-frame-query', nativePresentationMeasured: true,
  startQpcMs: 0, endQpcMs: 1000, fullBatches: 0,
  metadata: { qpcFrequency: 10000, processId: 123 }, frames,
});

test('legacy PowerShell non-finite native scalars become missing, never displayed frames', () => {
  const parsed = parseNativeCapture('{"frames":[{"displayedTimeMs":NaN,"displayLatencyMs":Infinity,"gpuWaitMs":-Infinity}],"literal":"keep: NaN, Infinity, -Infinity; \\\"quoted\\\""}');
  assert.equal(parsed.legacyNonFiniteTokens, 3);
  assert.deepEqual(parsed.frames[0], { displayedTimeMs: null, displayLatencyMs: null, gpuWaitMs: null });
  assert.equal(parsed.literal, 'keep: NaN, Infinity, -Infinity; "quoted"');
  assert.equal(parseNativeCapture('\uFEFF{"number": 42}').number, 42);
  assert.throws(() => parseNativeCapture('{"number": other}'));
});

test('native display timestamp uses present QPC + native untilDisplayed, cross-checked independently', () => {
  const [frame] = normalizeNativeFrames(capture([nativeFrame(100)]));
  assert.equal(frame.presentQpcMs, 102);
  assert.equal(frame.displayQpcMs, 112);
  assert.equal(frame.displayClockCheckErrorMs, 0);
});

test('motion intervals never bridge idle pauses or sum separate swapchains', () => {
  const result = analyzeNative(capture([nativeFrame(100), nativeFrame(116), nativeFrame(500), nativeFrame(516), nativeFrame(100, 10, { swapChain: 200 }), nativeFrame(132, 10, { swapChain: 200 })]),
    [{ startQpcMs: 100, endQpcMs: 140 }, { startQpcMs: 500, endQpcMs: 540 }], 60);
  assert.equal(result.multipleActiveSwapChains, true);
  assert.equal(result.swapChains[0].display.intervals, 2);
  assert.equal(result.swapChains[0].display.intervalMs.mean, 16);
  assert.equal(result.swapChains[1].display.intervalMs.mean, 32);
});

test('late native presentation remains counted and dropped frames do not inflate display FPS', () => {
  const result = analyzeNative(capture([nativeFrame(100), nativeFrame(116, 0, { displayedTimeMs: 0 }), nativeFrame(132, 80)]), [{ startQpcMs: 100, endQpcMs: 140 }], 60);
  const chain = result.swapChains[0];
  assert.equal(chain.presents.intervals, 2);
  assert.equal(chain.display.intervals, 1);
  assert.equal(chain.display.intervalMs.max, 102);
  assert.equal(chain.display.over100ms, 1);
  assert.equal(chain.windows[0].nonDisplayedFrames, 1);
});

test('native results fail closed on empty capture, unsafe clocks, or invalid native timestamps', () => {
  const windows = [{ startQpcMs: 100, endQpcMs: 200 }];
  assert.throws(() => analyzeNative(capture([]), windows, 60));
  assert.throws(() => analyzeNative(capture([nativeFrame(100, 10, { presentStartQpc: Number.MAX_VALUE })]), windows, 60));
  assert.throws(() => analyzeNative(capture([nativeFrame(100), nativeFrame(116, 0, { untilDisplayedMs: -6, displayedTimeMs: 16 })]), windows, 60));
});
