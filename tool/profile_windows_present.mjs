// Analyze native output from profile_windows_present.ps1 using verified QPC
// motion windows from profile_windows_input.ps1. Never infer app FPS from Hz.
// node tool/profile_windows_present.mjs --capture native.json --windows input.json
//   --hz 60 --out analyzed.json
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { distribution, validateWindows } from './profile_windows_frames.mjs';

export function parseNativeCapture(text) {
  // Older PowerShell 5 captures wrote SDK NaN/Infinity as bare tokens. Keep the
  // original artifact intact; map only unquoted native non-finite tokens to
  // null while reading. Literal strings and all finite values stay unchanged.
  let normalized = '';
  let quoted = false;
  let escaped = false;
  let legacyNonFiniteTokens = 0;
  text = text.replace(/^\uFEFF/, '');
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (quoted) {
      normalized += char;
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === '"') quoted = false;
    } else if (char === '"') {
      quoted = true;
      normalized += char;
    } else {
      const token = ['N', 'I', '-'].includes(char) ? /^(?:NaN|-?Infinity)(?=\s*[,}\]])/.exec(text.slice(i))?.[0] : null;
      if (token) {
        normalized += 'null';
        legacyNonFiniteTokens++;
        i += token.length - 1;
      } else normalized += char;
    }
  }
  const capture = JSON.parse(normalized);
  if (legacyNonFiniteTokens) capture.legacyNonFiniteTokens = legacyNonFiniteTokens;
  return capture;
}

export function normalizeNativeFrames(capture) {
  if (capture.source !== 'existing-PresentMon-service-frame-query' || capture.nativePresentationMeasured !== true) throw new Error('Expected native PresentMon service capture');
  const frequency = capture.metadata?.qpcFrequency;
  if (!Number.isFinite(frequency) || frequency <= 0 || !Array.isArray(capture.frames)) throw new Error('Invalid native QPC metadata/frames');
  const frames = capture.frames.map((frame, row) => {
    for (const key of ['presentStartQpc', 'cpuStartQpc', 'swapChain']) {
      if (!Number.isSafeInteger(frame[key]) || frame[key] < 0) throw new Error(`Unsafe native ${key} at row ${row}`);
    }
    const presentQpcMs = frame.presentStartQpc * 1000 / frequency;
    const cpuStartQpcMs = frame.cpuStartQpc * 1000 / frequency;
    if (Number.isFinite(frame.displayedTimeMs) && frame.displayedTimeMs > 0 &&
        (!Number.isFinite(frame.untilDisplayedMs) || frame.untilDisplayedMs < 0 || frame.presentStartQpc <= 0)) {
      throw new Error(`Displayed native frame has an invalid presentation clock at row ${row}`);
    }
    const displayed = Number.isFinite(frame.displayedTimeMs) && frame.displayedTimeMs > 0 &&
      Number.isFinite(frame.untilDisplayedMs) && frame.untilDisplayedMs >= 0;
    const displayQpcMs = displayed ? presentQpcMs + frame.untilDisplayedMs : null;
    const alternateDisplayQpcMs = displayed && Number.isFinite(frame.displayLatencyMs)
      ? cpuStartQpcMs + frame.displayLatencyMs : null;
    return {
      ...frame, row, presentQpcMs, cpuStartQpcMs, displayed, displayQpcMs,
      displayClockCheckErrorMs: alternateDisplayQpcMs == null ? null : Math.abs(displayQpcMs - alternateDisplayQpcMs),
    };
  });
  return frames.toSorted((a, b) => a.presentQpcMs - b.presentQpcMs);
}

export function nativeIntervalStats(values, hz) {
  const stats = distribution(values);
  return {
    intervals: values.length, intervalMs: stats,
    fps: stats?.mean > 0 ? 1000 / stats.mean : null,
    missedVsyncIntervals: values.filter((ms) => ms > 1500 / hz).length,
    missedVsyncPercent: values.length ? 100 * values.filter((ms) => ms > 1500 / hz).length / values.length : null,
    over50ms: values.filter((ms) => ms > 50).length,
    over100ms: values.filter((ms) => ms > 100).length,
  };
}

export function analyzeNative(capture, requestedWindows, hz) {
  if (!Number.isFinite(hz) || hz < 10 || hz > 1000) throw new Error('Invalid refresh rate');
  const windows = validateWindows(requestedWindows, capture.startQpcMs, capture.endQpcMs, 'qpc');
  if (!windows.length) throw new Error('At least one verified motion window is required');
  const frames = normalizeNativeFrames(capture);
  const grouped = new Map();
  for (const frame of frames) {
    const rows = grouped.get(frame.swapChain) ?? [];
    rows.push(frame);
    grouped.set(frame.swapChain, rows);
  }
  if (!grouped.size) throw new Error('No native per-app frames; display FPS is unavailable');
  const swapChains = [...grouped].map(([swapChain, rows]) => {
    // Repeated frames (type3) are not new application frames; do not inflate FPS.
    const displayedRows = rows.filter((frame) => frame.displayed && frame.frameType !== 3);
    const presentIntervals = [];
    const displayIntervals = [];
    const clockErrors = [];
    const byWindow = windows.map((window) => {
      const contains = (frame) => frame.presentQpcMs >= window.startQpcMs && frame.presentQpcMs <= window.endQpcMs;
      const currentPresentIntervals = [];
      const currentDisplayIntervals = [];
      for (let i = 1; i < rows.length; i++) {
        if (contains(rows[i - 1]) && contains(rows[i])) currentPresentIntervals.push(rows[i].presentQpcMs - rows[i - 1].presentQpcMs);
      }
      for (let i = 1; i < displayedRows.length; i++) {
        const previous = displayedRows[i - 1];
        const current = displayedRows[i];
        // Use present requests for membership: a late displayed frame is not
        // discarded simply because it appears after input/animation window end.
        if (contains(previous) && contains(current)) currentDisplayIntervals.push(current.displayQpcMs - previous.displayQpcMs);
      }
      presentIntervals.push(...currentPresentIntervals);
      displayIntervals.push(...currentDisplayIntervals);
      const currentFrames = rows.filter(contains);
      clockErrors.push(...currentFrames.map((frame) => frame.displayClockCheckErrorMs).filter(Number.isFinite));
      return {
        ...window, frames: currentFrames.length,
        displayedFrames: currentFrames.filter((frame) => frame.displayed).length,
        nonDisplayedFrames: currentFrames.filter((frame) => !frame.displayed).length,
        firstPresentRequestAfterWindowStartMs: currentFrames.length ? currentFrames[0].presentQpcMs - window.startQpcMs : null,
        lastPresentRequestBeforeWindowEndMs: currentFrames.length ? window.endQpcMs - currentFrames.at(-1).presentQpcMs : null,
        firstDisplayAfterWindowStartProxyMs: currentFrames.some((frame) => frame.displayed)
          ? Math.min(...currentFrames.filter((frame) => frame.displayed).map((frame) => frame.displayQpcMs - window.startQpcMs)) : null,
        firstDisplayProxyCaveat: 'First display of a frame requested within this window; may be a previous animation frame, not proof of new-tab content readiness.',
        presents: nativeIntervalStats(currentPresentIntervals, hz),
        display: nativeIntervalStats(currentDisplayIntervals, hz),
      };
    });
    if (displayIntervals.some((interval) => interval <= 0)) throw new Error('Native display timestamps are duplicated/non-monotonic; cannot publish display FPS');
    const activeRows = rows.filter((frame) => windows.some((window) => frame.presentQpcMs >= window.startQpcMs && frame.presentQpcMs <= window.endQpcMs));
    const workMs = Object.fromEntries(['cpuBusyMs', 'cpuWaitMs', 'gpuTimeMs', 'gpuBusyMs', 'gpuWaitMs', 'inPresentApiMs', 'displayLatencyMs', 'untilDisplayedMs']
      .map((key) => [key, distribution(activeRows.map((frame) => frame[key]).filter((value) => Number.isFinite(value) && value >= 0))]));
    return {
      swapChain, capturedFrames: rows.length,
      capturedDisplayedFrames: displayedRows.length,
      presentModes: [...new Set(rows.map((frame) => frame.presentMode))],
      presentRuntimes: [...new Set(rows.map((frame) => frame.presentRuntime))],
      displayClockCrossCheckMs: distribution(clockErrors),
      workMs,
      workMetricsCaveat: 'PresentMon CPU and Present API spans are wall durations, not sampled CPU utilization. GPU metrics are driver/ETW estimates and can be less accurate with hardware GPU scheduling.',
      presents: nativeIntervalStats(presentIntervals, hz),
      display: nativeIntervalStats(displayIntervals, hz), windows: byWindow,
    };
  }).sort((a, b) => b.display.intervals - a.display.intervals);
  if (!swapChains.some((chain) => chain.display.intervals > 0)) throw new Error('No native display intervals during verified motion; display FPS is unavailable');
  return {
    nativePresentationMeasured: true, processId: capture.metadata.processId, hz,
    legacyNonFiniteTokens: capture.legacyNonFiniteTokens ?? 0,
    fullBatches: capture.fullBatches, coverageWarning: capture.fullBatches > 0 ? 'At least one full reader batch; inspect coverage before trusting pacing.' : null,
    multipleActiveSwapChains: swapChains.filter((chain) => chain.display.intervals > 0).length > 1,
    caveat: 'Per-app native display cadence during supplied motion windows, grouped by swapchain. Present/request clock defines window membership so late presentation remains counted. Not idle FPS; all long intervals retained. Multiple active swapchains require identifying the visible app surface rather than summing FPS.',
    swapChains,
  };
}

async function main(argv) {
  const options = new Map();
  const allowed = new Set(['--capture', '--windows', '--hz', '--out']);
  for (let i = 0; i < argv.length; i += 2) {
    if (!allowed.has(argv[i]) || !argv[i + 1] || options.has(argv[i])) throw new Error(`Invalid option: ${argv[i]}`);
    options.set(argv[i], argv[i + 1]);
  }
  for (const key of ['--capture', '--windows', '--out']) if (!options.has(key)) throw new Error(`Missing ${key}`);
  const readJson = async (path) => JSON.parse((await readFile(path, 'utf8')).replace(/^\uFEFF/, ''));
  const capture = parseNativeCapture(await readFile(options.get('--capture'), 'utf8'));
  const windows = await readJson(options.get('--windows'));
  const result = analyzeNative(capture, windows, Number(options.get('--hz') ?? 60));
  await mkdir(dirname(options.get('--out')), { recursive: true });
  await writeFile(options.get('--out'), JSON.stringify(result, null, 2));
  console.log(JSON.stringify(result, null, 2));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((error) => { console.error(error.message); process.exitCode = 1; });
}
