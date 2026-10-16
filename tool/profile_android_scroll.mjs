// Capture actual Flutter FrameTiming events from a profile build while ADB
// performs repeatable scroll gestures. Requires Node 22+ and an adb-forwarded
// Dart VM service. Example:
// node tool/profile_android_scroll.mjs --uri http://127.0.0.1:8450/TOKEN=/ \
//   --adb PATH_TO_ADB --device SERIAL --out build/diagnostics/scroll.json
// Add --trace true to collect expensive engine spans; default timing-only
// collection avoids the overhead of recording the complete engine timeline.
// Gesture coordinates default to the S22 Ultra's 1080x2316 display and avoid
// the mini player. Use --width/--height for other portrait displays.
// Use --pattern alternate for short lists, so repeated gestures do not spend
// most of the sample pushing against the bottom or top scroll extent.
// --reset-scroll true injects four quick downward swipes and settles before
// recording, so each run starts at the same top scroll extent.
// --presentation true also samples the actual Flutter SurfaceView's native
// SurfaceFlinger presentation timestamps. It reports pacing only within the
// recorded input gestures, with clock-sync uncertainty excluded at the edges.
// --motion-tail-ms 150 also reports presentationWithTail over the union of
// gesture windows extended after input ends, so release-time hitches are not
// hidden. This is not idle FPS: a quiet tail may intentionally stop rendering.
// --clock-helper /data/local/tmp/bstream_profile_clock uses device-native
// BOOTTIME/MONOTONIC markers around each input command instead of estimating
// their offset over ADB. See android_profile_clock.c for the tiny helper.
// Markers bracket the input process, not actual touchscreen delivery events.
// --expect-label 'Búsqueda' requires that exact Android content-desc before
// resetting/recording and after collection. UI checks run outside the measured
// window; a failed dump or wrong screen aborts without publishing a result.
// Flutter.Frame.startTime is buildStart, not vsyncStart. Large vsyncOverhead
// precedes that timestamp; never add it to startTime to align a system trace.
// --hz is the active-scroll refresh rate, not an idle FPS target;
// an idle scene should render only when something changes.
import { execFile } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { promisify } from 'node:util';

const run = promisify(execFile);
const options = new Map();
for (let i = 2; i < process.argv.length; i += 2) {
  options.set(process.argv[i], process.argv[i + 1]);
}
for (const required of ['--uri', '--adb', '--device', '--out']) {
  if (!options.get(required)) throw new Error(`Missing ${required}`);
}
const cycles = Number(options.get('--cycles') ?? 4);
const mode = options.get('--mode') ?? 'scroll';
const hz = Number(options.get('--hz') ?? 120);
const idleSeconds = Number(options.get('--seconds') ?? 6);
const width = Number(options.get('--width') ?? 1080);
const height = Number(options.get('--height') ?? 2316);
const pattern = options.get('--pattern') ?? 'sweep';
const resetScroll = options.get('--reset-scroll') === 'true';
const clockHelper = options.get('--clock-helper');
const expectedLabel = options.get('--expect-label');
const motionTailMs = Number(options.get('--motion-tail-ms') ?? 150);
const nativeClockUncertaintyMs = 0.25;
if (!Number.isFinite(motionTailMs) || motionTailMs < 0 || motionTailMs > 500 ||
    (options.has('--motion-tail-ms') && !options.get('--motion-tail-ms')?.trim())) {
  throw new Error('--motion-tail-ms must be a number between 0 and 500');
}
if (options.has('--expect-label') &&
    (typeof expectedLabel !== 'string' || expectedLabel.length < 1 || expectedLabel.length > 120 || expectedLabel.includes('\0'))) {
  throw new Error('--expect-label must contain 1 to 120 characters and no NUL');
}
if (options.has('--reset-scroll') && !['true', 'false'].includes(options.get('--reset-scroll'))) {
  throw new Error('--reset-scroll must be true or false');
}
if (clockHelper != null && !/^\/data\/local\/tmp\/[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(clockHelper)) {
  throw new Error('--clock-helper must name an executable directly inside /data/local/tmp');
}
if (!Number.isInteger(cycles) || cycles < 1 || cycles > 20) {
  throw new Error('--cycles must be an integer between 1 and 20');
}
if (!['scroll', 'idle'].includes(mode) || !Number.isFinite(hz) || hz <= 0) {
  throw new Error('Invalid --mode or --hz');
}
if (!Number.isFinite(idleSeconds) || idleSeconds < 1 || idleSeconds > 30) {
  throw new Error('--seconds must be between 1 and 30');
}
if (![width, height].every((value) => Number.isInteger(value) && value > 0 && value <= 10000)) {
  throw new Error('--width and --height must be positive screen dimensions');
}
if (!['sweep', 'alternate'].includes(pattern)) {
  throw new Error('--pattern must be sweep or alternate');
}
const trackerResult = await run(options.get('--adb'), [
  '-s', options.get('--device'), 'shell', 'pidof process-tracker | wc -w',
], { timeout: 15000 });
const trackerCount = Number(trackerResult.stdout.trim());
if (!Number.isFinite(trackerCount) || trackerCount > 4) {
  throw new Error(`Unreliable profiling conditions: ${trackerCount} process-tracker monitors. Close Android Studio and remove duplicate monitors first.`);
}
const uri = new URL(options.get('--uri'));
uri.protocol = uri.protocol === 'https:' ? 'wss:' : 'ws:';
uri.pathname = `${uri.pathname.replace(/\/$/, '')}/ws`;
const socket = new WebSocket(uri);
await new Promise((resolve, reject) => {
  socket.addEventListener('open', resolve, { once: true });
  socket.addEventListener('error', reject, { once: true });
});
const pending = new Map();
const frames = [];
let nextId = 0;
socket.addEventListener('message', ({ data }) => {
  const message = JSON.parse(data);
  if (message.id != null) {
    const callback = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) callback?.reject(new Error(JSON.stringify(message.error)));
    else callback?.resolve(message.result);
  }
  const event = message.params?.event;
  if (event?.extensionKind === 'Flutter.Frame') frames.push(event.extensionData);
});
function rpc(method, params = {}) {
  const id = ++nextId;
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Timed out: ${method}`));
    }, 15000);
    pending.set(id, {
      resolve: (value) => { clearTimeout(timeout); resolve(value); },
      reject: (error) => { clearTimeout(timeout); reject(error); },
    });
    socket.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
  });
}
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
function distribution(values) {
  const sorted = values.toSorted((a, b) => a - b);
  if (!sorted.length) return null;
  const quantile = (p) => sorted[Math.min(sorted.length - 1, Math.ceil(p * sorted.length) - 1)];
  return {
    mean: values.reduce((sum, value) => sum + value, 0) / values.length,
    p50: quantile(0.5), p90: quantile(0.9), p95: quantile(0.95),
    p99: quantile(0.99), max: sorted.at(-1),
  };
}
function longIntervalCounts(values) {
  return {
    over16ms: values.filter((ms) => ms > 16).length,
    over25ms: values.filter((ms) => ms > 25).length,
    over50ms: values.filter((ms) => ms > 50).length,
    over100ms: values.filter((ms) => ms > 100).length,
  };
}
function mergeTimeWindows(windows) {
  const merged = [];
  for (const window of windows.toSorted((a, b) => a.startNs - b.startNs)) {
    if (window.endNs < window.startNs) continue;
    const previous = merged.at(-1);
    if (previous && window.startNs <= previous.endNs) {
      previous.endNs = Math.max(previous.endNs, window.endNs);
    } else {
      merged.push({ ...window });
    }
  }
  return merged;
}
function presentationIntervalsMs(presentationFrames, windows) {
  const intervals = [];
  for (let i = 1; i < presentationFrames.length; i++) {
    const previous = presentationFrames[i - 1];
    const current = presentationFrames[i];
    // Membership follows requested times: a late presentation is still a
    // hitch even when its actual presentation falls after the window ends.
    // Count every interval once, including genuine gaps above 50/100 ms.
    if (windows.some((window) => previous.requestedNs >= window.startNs &&
        current.requestedNs <= window.endNs && current.requestedNs >= previous.requestedNs)) {
      intervals.push((current.presentedNs - previous.presentedNs) / 1e6);
    }
  }
  return intervals;
}
function parseClockMarkers(output) {
  const markers = [];
  for (const line of output.trim().split(/\r?\n/)) {
    const match = /^BSTREAM_CLOCK ([0-9]+) ([0-9]+)$/.exec(line.trim());
    if (!match) continue;
    const bootNs = Number(match[1]);
    const monotonicNs = Number(match[2]);
    if (!Number.isSafeInteger(bootNs) || !Number.isSafeInteger(monotonicNs) || bootNs <= 0 || monotonicNs <= 0) {
      throw new Error('Clock helper returned invalid or unsafe nanosecond timestamps');
    }
    markers.push({ bootNs, monotonicNs });
  }
  return markers;
}
function escapeXmlAttribute(value) {
  return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');
}
function hasExactContentDescription(xml, label) {
  const expected = escapeXmlAttribute(label);
  for (const [, attribute] of xml.matchAll(/(?:^|\s)content-desc="([^"]*)"/g)) {
    // Normalize equivalent XML entities before comparing escaped attributes.
    // Literal '&amp;' labels still compare correctly: decode only one pass.
    const decoded = attribute.replace(/&(amp|lt|gt|quot|apos|#x[0-9a-fA-F]+|#[0-9]+);/g, (_, entity) => {
      if (entity.startsWith('#x')) return String.fromCodePoint(Number.parseInt(entity.slice(2), 16));
      if (entity.startsWith('#')) return String.fromCodePoint(Number.parseInt(entity.slice(1), 10));
      return { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" }[entity];
    });
    if (escapeXmlAttribute(decoded) === expected) return true;
  }
  return false;
}
async function verifyExpectedScreen(stage) {
  const uiPath = '/sdcard/bstream_profile_ui.xml';
  try {
    const dump = await run(options.get('--adb'), [
      '-s', options.get('--device'), 'shell', `uiautomator dump ${uiPath}`,
    ], { timeout: 20000 });
    const output = `${dump.stdout}\n${dump.stderr ?? ''}`;
    // UI Automator can exit 0 on an idle timeout without replacing the XML.
    // Do not read a previous dump unless this invocation confirms success.
    if (/\bERROR\b/i.test(output) ||
        !/UI hier(?:archy|chary) dumped to:\s*\/sdcard\/bstream_profile_ui\.xml(?:\s|$)/.test(output)) {
      throw new Error(`UI Automator did not confirm a fresh dump: ${output.trim()}`);
    }
    const result = await run(options.get('--adb'), [
      '-s', options.get('--device'), 'shell', `cat ${uiPath}`,
    ], { timeout: 15000 });
    if (!/<hierarchy(?:\s|>)/.test(result.stdout) ||
        !hasExactContentDescription(result.stdout, expectedLabel)) {
      throw new Error(`Expected exact content-desc ${JSON.stringify(expectedLabel)} was not found`);
    }
  } catch (error) {
    throw new Error(`Incomplete profiling run: screen verification ${stage} failed: ${error.message}`, { cause: error });
  }
}
function completeTimelineEvents(events) {
  const completed = [];
  const stacks = new Map();
  for (const event of events) {
    if (event.ph === 'B') {
      const stack = stacks.get(event.tid) ?? [];
      stack.push(event);
      stacks.set(event.tid, stack);
    } else if (event.ph === 'E') {
      const stack = stacks.get(event.tid);
      const begin = stack?.pop();
      // Ring-buffer snapshots can start/end halfway through a stack. Pair
      // only complete spans within one snapshot, before deduplicating them:
      // two valid zero-duration sibling events may otherwise look identical.
      if (begin && begin.name === event.name && event.ts >= begin.ts) {
        completed.push({ ...begin, ph: 'X', dur: event.ts - begin.ts });
      } else if (stack) {
        stack.length = 0;
      }
    } else {
      completed.push(event);
    }
  }
  return completed;
}
const originalFlags = await rpc('getVMTimelineFlags');
const traceEnabled = options.get('--trace') === 'true';
const traceStreams = (options.get('--trace-streams') ?? 'Dart,Embedder,GC').split(',');
const presentationEnabled = options.get('--presentation') === 'true';
const presented = new Map();
const presentationErrors = [];
const timelineEvents = new Map();
let samplingTimeline = false;
let timelineTask;
let latestTimeline;
let samplingPresentation = false;
let presentationTask;
let surfaceName;
let clockSync;
let previousNewestPresentation = 0;
const scrollX = Math.round(width / 2);
const scrollTop = Math.round(height * 500 / 2316);
const scrollBottom = Math.round(height * 1650 / 2316);
try {
  if (expectedLabel != null) await verifyExpectedScreen('before reset/recording');
  if (clockHelper) {
    const result = await run(options.get('--adb'), [
      '-s', options.get('--device'), 'shell', clockHelper,
    ], { timeout: 15000 });
    const markers = parseClockMarkers(result.stdout);
    if (markers.length !== 1) throw new Error('Clock helper must output exactly one BSTREAM_CLOCK marker');
    clockSync = {
      source: 'android-native-clock-helper',
      helperPath: clockHelper,
      bootToMonotonicSeconds: (markers[0].bootNs - markers[0].monotonicNs) / 1e9,
      uncertaintyMs: nativeClockUncertaintyMs,
    };
  }
  if (resetScroll) {
    const resetTop = Math.round(height * 800 / 3120);
    const resetBottom = Math.round(height * 2400 / 3120);
    const resetCommand = `for i in 1 2 3 4; do input swipe ${scrollX} ${resetTop} ${scrollX} ${resetBottom} 180; sleep 0.2; done; sleep 0.6`;
    await run(options.get('--adb'), ['-s', options.get('--device'), 'shell', resetCommand], { timeout: 15000 });
  }
if (presentationEnabled) {
  const layers = await run(options.get('--adb'), [
    '-s', options.get('--device'), 'shell', 'dumpsys SurfaceFlinger --list',
  ], { timeout: 15000 });
  const candidates = [...new Set([...layers.stdout.matchAll(/([^\r\n{}]*SurfaceView\[com\.bstream\.bstream_music\/[^\r\n{}]*?\(BLAST\)#\d+)/g)].map((match) => match[1].trim()))];
  if (candidates.length !== 1) throw new Error(`Need one unambiguous BStream Flutter BLAST surface, found ${candidates.length}; never substitute global display FPS.`);
  surfaceName = candidates[0];
  if (!clockHelper) {
    const before = await rpc('getVMTimelineMicros');
    const uptime = await run(options.get('--adb'), ['-s', options.get('--device'), 'shell', 'cat /proc/uptime'], { timeout: 15000 });
    const after = await rpc('getVMTimelineMicros');
    clockSync = {
      source: 'adb-proc-uptime-rpc-sync',
      bootToMonotonicSeconds: Number.parseFloat(uptime.stdout) - (before.timestamp + after.timestamp) / 2e6,
      // /proc/uptime is rounded to 10 ms, plus half the sync round trip.
      uncertaintyMs: (after.timestamp - before.timestamp) / 2000 + 10,
    };
  }
  const command = `dumpsys SurfaceFlinger --latency '${surfaceName.replaceAll("'", "'\\''")}'`;
  const poll = async () => {
    do {
      try {
        const output = await run(options.get('--adb'), ['-s', options.get('--device'), 'shell', command], { timeout: 5000 });
        const currentTimestamps = [];
        for (const line of output.stdout.split(/\r?\n/)) {
          const values = line.trim().split(/\s+/).map(Number);
          if (values.length !== 3 || !values.every(Number.isSafeInteger)) continue;
          const [requestedNs, presentedNs, readyNs] = values;
          if (requestedNs <= 0 || presentedNs <= 0 || readyNs <= 0) continue;
          currentTimestamps.push(presentedNs);
          presented.set(presentedNs, { requestedNs, presentedNs, readyNs });
        }
        if (previousNewestPresentation && currentTimestamps.length && !currentTimestamps.includes(previousNewestPresentation)) {
          presentationErrors.push('SurfaceFlinger ring buffer no longer overlaps the previous sample; pacing coverage is incomplete.');
        }
        if (currentTimestamps.length) previousNewestPresentation = Math.max(...currentTimestamps);
      } catch (error) {
        presentationErrors.push(String(error));
      }
      if (samplingPresentation) await delay(350);
    } while (samplingPresentation);
  };
  samplingPresentation = true;
  presentationTask = poll();
}
  await rpc('streamListen', { streamId: 'Extension' });
  await rpc('setVMTimelineFlags', { recordedStreams: traceEnabled ? traceStreams : [] });
  await rpc('clearVMTimeline');
  if (traceEnabled) {
    // The engine's ring buffer can overwrite a gesture's first expensive
    // layout before its final FrameTiming batch arrives. Drain it while
    // tracing; timing-only runs deliberately do not incur this overhead.
    samplingTimeline = true;
    timelineTask = (async () => {
      do {
        latestTimeline = await rpc('getVMTimeline');
        for (const event of completeTimelineEvents(latestTimeline.traceEvents ?? [])) {
          timelineEvents.set(JSON.stringify(event), event);
        }
        if (samplingTimeline) await delay(200);
      } while (samplingTimeline);
    })();
    // Attach a handler immediately; the awaited task below still propagates
    // failures through the outer finally and restores the original flags.
    timelineTask.catch(() => {});
  }
  await delay(300);
  const { timestamp: start } = await rpc('getVMTimelineMicros');
  // /proc/uptime uses the Android boot clock. Keep each injected gesture's
  // interval so a system FrameTimeline trace can exclude scripted idle gaps
  // without discarding genuine long frames as if they were idle.
  const readClock = clockHelper ? `'${clockHelper}'` : 'cat /proc/uptime';
  const up = `${readClock}; input swipe ${scrollX} ${scrollBottom} ${scrollX} ${scrollTop} 500; ${readClock}; sleep 0.1`;
  const down = `${readClock}; input swipe ${scrollX} ${scrollTop} ${scrollX} ${scrollBottom} 500; ${readClock}; sleep 0.1`;
  const cycleNumbers = Array.from({ length: cycles }, (_, i) => i + 1).join(' ');
  const gesture = mode === 'idle'
    ? `sleep ${idleSeconds}`
    : pattern === 'alternate'
      ? `for i in ${cycleNumbers}; do ${up}; ${down}; done`
      : `for i in ${cycleNumbers}; do ${up}; done; for i in ${cycleNumbers}; do ${down}; done`;
  const execution = await run(options.get('--adb'), ['-s', options.get('--device'), 'shell', gesture], { timeout: 60000 });
  const gestureWindows = [];
  if (clockHelper) {
    const markers = parseClockMarkers(execution.stdout);
    if (mode === 'scroll' && markers.length !== cycles * 4) {
      throw new Error(`Expected ${cycles * 4} native clock markers, received ${markers.length}`);
    }
    for (let i = 0; i + 1 < markers.length; i += 2) {
      const first = markers[i];
      const last = markers[i + 1];
      if (last.monotonicNs <= first.monotonicNs || last.bootNs <= first.bootNs) {
        throw new Error('Native clock markers must increase across each gesture');
      }
      gestureWindows.push({
        startBootSeconds: first.bootNs / 1e9,
        endBootSeconds: last.bootNs / 1e9,
        startMonotonicNs: first.monotonicNs,
        endMonotonicNs: last.monotonicNs,
      });
    }
  } else {
    const uptimeSamples = execution.stdout.trim().split(/\r?\n/)
      .map((line) => Number.parseFloat(line.split(' ')[0]))
      .filter(Number.isFinite);
    for (let i = 0; i + 1 < uptimeSamples.length; i += 2) {
      gestureWindows.push({ startBootSeconds: uptimeSamples[i], endBootSeconds: uptimeSamples[i + 1] });
    }
  }
  const { timestamp: end } = await rpc('getVMTimelineMicros');
  // FrameTiming is delivered in batches after raster finishes. For longer
  // tails, also leave at least one SF polling period beyond the requested tail.
  // The original measured start/end and active-input statistics stay unchanged.
  await delay(presentationEnabled ? Math.max(600, motionTailMs + 350) : 600);
  samplingPresentation = false;
  await presentationTask;
  samplingTimeline = false;
  await timelineTask;
  if (expectedLabel != null) await verifyExpectedScreen('after sampling');
  const timeline = {
    ...latestTimeline,
    timeOriginMicros: start,
    timeExtentMicros: end - start,
    traceEvents: [...timelineEvents.values()]
      .filter((event) => event.ts == null || (event.ts >= start && event.ts <= end))
      .sort((a, b) => (a.ts ?? 0) - (b.ts ?? 0)),
  };
  const sample = frames.filter((frame) => frame.startTime >= start && frame.startTime <= end);
  if (!sample.length && mode === 'scroll') throw new Error('No Flutter FrameTiming events received; check that the app is foregrounded and built in profile mode.');
  const budgetUs = 1e6 / hz;
  const summary = {
    label: options.get('--label') ?? 'scroll', mode, trackerCount,
    screen: { width, height },
    pattern, resetScroll,
    uiVerification: expectedLabel == null ? null : {
      expectedLabel, beforeSampling: true, afterSampling: true,
    },
    clock: clockSync == null
      ? { source: 'adb-proc-uptime', uncertaintyMs: null }
      : { source: clockSync.source, uncertaintyMs: clockSync.uncertaintyMs },
    seconds: (end - start) / 1e6, frames: sample.length, budgetMs: budgetUs / 1000,
    buildMs: distribution(sample.map((frame) => frame.build / 1000)),
    rasterMs: distribution(sample.map((frame) => frame.raster / 1000)),
    // FrameTiming reports wall duration, not sampled CPU time.
    longRasterFrames: longIntervalCounts(sample.map((frame) => frame.raster / 1000)),
    vsyncOverheadMs: distribution(sample.map((frame) => frame.vsyncOverhead / 1000)),
    elapsedMs: distribution(sample.map((frame) => frame.elapsed / 1000)),
    slowBuildFrames: sample.filter((frame) => frame.build > budgetUs).length,
    slowRasterFrames: sample.filter((frame) => frame.raster > budgetUs).length,
    slowPipelineFrames: sample.filter((frame) => frame.build > budgetUs || frame.raster > budgetUs).length,
    slowPipelinePercent: sample.length ? 100 * sample.filter((frame) => frame.build > budgetUs || frame.raster > budgetUs).length / sample.length : 0,
    frameIntervalMs: distribution(sample.slice(1).map((frame, i) => (frame.startTime - sample[i].startTime) / 1000)),
  };
  const presentationFrames = [...presented.values()]
    .filter((frame) => frame.requestedNs >= start * 1000 && frame.requestedNs <= end * 1000)
    .sort((a, b) => a.presentedNs - b.presentedNs);
  let presentationFramesWithTail;
  if (presentationEnabled) {
    const safeWindows = gestureWindows.map((window) => clockHelper ? {
      startNs: window.startMonotonicNs + nativeClockUncertaintyMs * 1e6,
      endNs: window.endMonotonicNs - nativeClockUncertaintyMs * 1e6,
    } : {
      startNs: (window.startBootSeconds - clockSync.bootToMonotonicSeconds + clockSync.uncertaintyMs / 1000) * 1e9,
      endNs: (window.endBootSeconds - clockSync.bootToMonotonicSeconds - clockSync.uncertaintyMs / 1000) * 1e9,
    });
    const activeIntervalsMs = presentationIntervalsMs(presentationFrames, safeWindows);
    if (!activeIntervalsMs.length && mode === 'scroll') throw new Error('No surface presentation intervals during input; native pacing measurement is unavailable.');
    summary.presentation = {
      surfaceName, frames: presentationFrames.length,
      motionTailMs,
      activeIntervals: activeIntervalsMs.length,
      intervalMs: distribution(activeIntervalsMs),
      ...longIntervalCounts(activeIntervalsMs),
      syncUncertaintyMs: clockSync.uncertaintyMs,
      reliableCoverage: presentationErrors.length === 0,
      errors: presentationErrors,
    };
    // Preserve the original uncertainty trims, including the leading edge.
    // Merge overlapping tails before selecting intervals across input gaps.
    const motionWindows = mergeTimeWindows(safeWindows.map((window) => ({
      startNs: window.startNs, endNs: window.endNs + motionTailMs * 1e6,
    })));
    const presentationEndNs = Math.max(end * 1000, ...motionWindows.map((window) => window.endNs));
    presentationFramesWithTail = [...presented.values()]
      .filter((frame) => frame.requestedNs >= start * 1000 && frame.requestedNs <= presentationEndNs)
      .sort((a, b) => a.presentedNs - b.presentedNs);
    const motionIntervalsMs = presentationIntervalsMs(presentationFramesWithTail, motionWindows);
    summary.presentationWithTail = {
      surfaceName, frames: presentationFramesWithTail.length,
      motionTailMs, windowCount: motionWindows.length,
      intervals: motionIntervalsMs.length,
      intervalMs: distribution(motionIntervalsMs),
      ...longIntervalCounts(motionIntervalsMs),
      syncUncertaintyMs: clockSync.uncertaintyMs,
      reliableCoverage: presentationErrors.length === 0,
      errors: presentationErrors,
    };
  }
  // Completed spans and begin/end pairs expose where build/raster time went.
  const spans = [];
  const stacks = new Map();
  for (const event of timeline.traceEvents ?? []) {
    if (event.ph === 'X') spans.push({ name: event.name, duration: event.dur, thread: event.tid });
    if (event.ph === 'B') {
      const stack = stacks.get(event.tid) ?? [];
      stack.push(event);
      stacks.set(event.tid, stack);
    }
    if (event.ph === 'E') {
      const begin = stacks.get(event.tid)?.pop();
      if (begin) spans.push({ name: begin.name, duration: event.ts - begin.ts, thread: event.tid });
    }
  }
  const grouped = new Map();
  for (const span of spans) {
    if (!(span.duration >= 0)) continue;
    const group = grouped.get(span.name) ?? [];
    group.push(span.duration / 1000);
    grouped.set(span.name, group);
  }
  summary.expensiveSpans = [...grouped].map(([name, durations]) => ({
    name, count: durations.length,
    totalMs: durations.reduce((sum, duration) => sum + duration, 0),
    ...distribution(durations),
  })).sort((a, b) => b.totalMs - a.totalMs).slice(0, 35);
  await mkdir(dirname(options.get('--out')), { recursive: true });
  await writeFile(options.get('--out'), JSON.stringify({ summary, gestureWindows, clockSync, presentationFrames, presentationFramesWithTail, frames: sample, timeline }, null, 2));
  console.log(JSON.stringify(summary, null, 2));
  if (presentationErrors.length) process.exitCode = 1;
} finally {
  samplingPresentation = false;
  samplingTimeline = false;
  try {
    await Promise.all([presentationTask, timelineTask]);
  } finally {
    try {
      await rpc('setVMTimelineFlags', { recordedStreams: originalFlags.recordedStreams });
    } finally {
      socket.close();
    }
  }
}
