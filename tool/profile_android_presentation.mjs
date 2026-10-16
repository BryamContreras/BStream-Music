// Native-only pacing for release/profile APKs; no Dart VM service required.
// node tool/profile_android_presentation.mjs --adb PATH --device SERIAL \
//   --out build/diagnostics/release-scroll.json --pattern alternate \
//   --reset-scroll true --expect-label 'Búsqueda' --width 1440 --height 3120
// Tabs: --mode tabs --taps '[[120,2900],[360,2900],[600,2900]]'
// or --taps-file coordinates.json, repeated --cycles times. Use distinct
// --expect-label-before/--expect-label-after when the final screen differs.
// Requires android_profile_clock.c installed at --clock-helper (default below).
// Markers bracket input commands, not touchscreen delivery. SF cadence is not
// idle FPS or proof of the display refresh rate. Quiet tails can stop rendering.
// The firstPresentationAfterTapProxy is NOT new-tab/content-ready latency.
import { execFile } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { promisify } from 'node:util';

const run = promisify(execFile);
const options = new Map();
const known = new Set(['--adb', '--device', '--out', '--label', '--mode', '--cycles', '--width', '--height', '--pattern', '--reset-scroll', '--clock-helper', '--motion-tail-ms', '--expect-label', '--expect-label-before', '--expect-label-after', '--taps', '--taps-file', '--tap-wait-ms']);
for (let i = 2; i < process.argv.length; i += 2) {
  const [key, value] = process.argv.slice(i, i + 2);
  if (!known.has(key) || value == null) throw new Error(`Unknown option or missing value: ${key}`);
  options.set(key, value);
}
for (const key of ['--adb', '--device', '--out']) {
  if (!options.get(key)) throw new Error(`Missing ${key}`);
}
function numberOption(key, fallback, min, max, integer = false) {
  const raw = options.get(key) ?? String(fallback);
  const value = Number(raw);
  if (!raw.trim() || !Number.isFinite(value) || value < min || value > max || (integer && !Number.isInteger(value))) {
    throw new Error(`${key} must be ${integer ? 'an integer' : 'a number'} between ${min} and ${max}`);
  }
  return value;
}
const mode = options.get('--mode') ?? 'scroll';
const cycles = numberOption('--cycles', 4, 1, 20, true);
const width = numberOption('--width', 1080, 1, 10000, true);
const height = numberOption('--height', 2316, 1, 10000, true);
const motionTailMs = numberOption('--motion-tail-ms', 150, 0, 500);
const tapWaitMs = numberOption('--tap-wait-ms', 500, 100, 2000, true);
const pattern = options.get('--pattern') ?? 'sweep';
const resetScroll = options.get('--reset-scroll') === 'true';
const clockHelper = options.get('--clock-helper') ?? '/data/local/tmp/bstream_profile_clock';
const beforeLabel = options.get('--expect-label-before') ?? options.get('--expect-label');
const afterLabel = options.get('--expect-label-after') ?? options.get('--expect-label');
if (!['scroll', 'tabs'].includes(mode)) throw new Error('--mode must be scroll or tabs');
if (!['sweep', 'alternate'].includes(pattern)) throw new Error('--pattern must be sweep or alternate');
if (options.has('--reset-scroll') && !['true', 'false'].includes(options.get('--reset-scroll'))) throw new Error('--reset-scroll must be true or false');
if (mode === 'tabs' && resetScroll) throw new Error('--reset-scroll applies only to scroll mode');
if (!/^\/data\/local\/tmp\/[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(clockHelper)) throw new Error('--clock-helper must name an executable directly inside /data/local/tmp');
for (const key of ['--expect-label', '--expect-label-before', '--expect-label-after']) {
  const value = options.get(key);
  if (options.has(key) && (!value.length || value.length > 120 || value.includes('\0'))) throw new Error(`${key} must contain 1 to 120 characters and no NUL`);
}
let taps;
if (mode === 'tabs') {
  if (options.has('--taps') === options.has('--taps-file')) throw new Error('Tabs require exactly one of --taps or --taps-file');
  taps = JSON.parse(options.get('--taps') ?? await readFile(options.get('--taps-file'), 'utf8'));
  if (!Array.isArray(taps) || taps.length < 1 || taps.length > 12 || taps.some((p) => !Array.isArray(p) || p.length !== 2 || !p.every(Number.isInteger) || p[0] < 0 || p[0] >= width || p[1] < 0 || p[1] >= height)) {
    throw new Error('--taps must contain 1 to 12 [x,y] integer pairs inside the screen');
  }
} else if (options.has('--taps') || options.has('--taps-file')) throw new Error('--taps/--taps-file require --mode tabs');
const shell = (command, timeout = 15000) => run(options.get('--adb'), ['-s', options.get('--device'), 'shell', command], { timeout });
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const uncertaintyMs = 0.25;
function markers(output) {
  const result = [...output.matchAll(/^BSTREAM_CLOCK ([0-9]+) ([0-9]+)\s*$/gm)].map((m) => ({ bootNs: Number(m[1]), monotonicNs: Number(m[2]) }));
  for (let i = 0; i < result.length; i++) {
    const m = result[i], previous = result[i - 1];
    if (![m.bootNs, m.monotonicNs].every((v) => Number.isSafeInteger(v) && v > 0) || (previous && (m.bootNs <= previous.bootNs || m.monotonicNs <= previous.monotonicNs))) {
      throw new Error('Native clock markers must be positive, safe integers and strictly increasing');
    }
  }
  return result;
}
function escapeXml(value) {
  return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');
}
async function verifyScreen(label, stage) {
  if (label == null) return;
  const path = '/sdcard/bstream_presentation_ui.xml';
  try {
    const dump = await shell(`uiautomator dump ${path}`, 20000);
    const output = `${dump.stdout}\n${dump.stderr ?? ''}`;
    if (/\bERROR\b/i.test(output) || !/UI hier(?:archy|chary) dumped to:\s*\/sdcard\/bstream_presentation_ui\.xml(?:\s|$)/.test(output)) throw new Error(`No fresh successful UI dump: ${output.trim()}`);
    const { stdout } = await shell(`cat ${path}`);
    const decode = (v) => v.replace(/&(amp|lt|gt|quot|apos|#x[0-9a-fA-F]+|#[0-9]+);/g, (_, e) => e[0] === '#' ? String.fromCodePoint(Number.parseInt(e.slice(e[1] === 'x' ? 2 : 1), e[1] === 'x' ? 16 : 10)) : ({ amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" })[e]);
    if (!/<hierarchy(?:\s|>)/.test(stdout) || ![...stdout.matchAll(/(?:^|\s)content-desc="([^"]*)"/g)].some((m) => escapeXml(decode(m[1])) === escapeXml(label))) throw new Error(`Exact content-desc ${JSON.stringify(label)} absent`);
  } catch (error) {
    throw new Error(`Incomplete profiling run: screen verification ${stage} failed: ${error.message}`, { cause: error });
  }
}
function distribution(values) {
  if (!values.length) return null;
  const sorted = values.toSorted((a, b) => a - b);
  const q = (p) => sorted[Math.ceil(p * sorted.length) - 1];
  return { mean: values.reduce((a, b) => a + b, 0) / values.length, p50: q(0.5), p90: q(0.9), p95: q(0.95), p99: q(0.99), max: sorted.at(-1) };
}
function mergeWindows(windows) {
  const merged = [];
  for (const w of windows.toSorted((a, b) => a.startNs - b.startNs)) {
    if (w.endNs < w.startNs) continue;
    const previous = merged.at(-1);
    if (previous && w.startNs <= previous.endNs) previous.endNs = Math.max(previous.endNs, w.endNs);
    else merged.push({ ...w });
  }
  return merged;
}
function intervals(rows, windows) {
  const values = [];
  for (let i = 1; i < rows.length; i++) {
    const a = rows[i - 1], b = rows[i];
    // Requested timestamps select work; actual presentation measures its gap.
    // Keep late presents and all >50/100 ms gaps; never relabel them idle.
    if (b.requestedNs >= a.requestedNs && windows.some((w) => a.requestedNs >= w.startNs && b.requestedNs <= w.endNs)) values.push((b.presentedNs - a.presentedNs) / 1e6);
  }
  return values;
}
const tracker = Number((await shell('pidof process-tracker | wc -w')).stdout.trim());
if (!Number.isFinite(tracker) || tracker > 4) throw new Error(`Unreliable profiling conditions: ${tracker} process-tracker monitors; close Android Studio and duplicate monitors first.`);
await verifyScreen(beforeLabel, 'before reset/recording');
const preflight = markers((await shell(clockHelper)).stdout);
if (preflight.length !== 1) throw new Error('Clock helper must return exactly one BSTREAM_CLOCK marker');
if (resetScroll) await shell(`set -e; for i in 1 2 3 4; do input swipe ${Math.round(width / 2)} ${Math.round(height * 800 / 3120)} ${Math.round(width / 2)} ${Math.round(height * 2400 / 3120)} 180; sleep 0.2; done; sleep 0.6`);
const layerOutput = (await shell('dumpsys SurfaceFlinger --list')).stdout;
const candidates = [...new Set([...layerOutput.matchAll(/([^\r\n{}]*SurfaceView\[com\.bstream\.bstream_music\/[^\r\n{}]*?\(BLAST\)#\d+)/g)].map((m) => m[1].trim()))];
if (candidates.length !== 1) throw new Error(`Need one unambiguous BStream Flutter BLAST surface, found ${candidates.length}; never substitute global display FPS.`);
const surfaceName = candidates[0];
const latencyCommand = `dumpsys SurfaceFlinger --latency '${surfaceName.replaceAll("'", "'\\''")}'`;
const presented = new Map(), presentationErrors = [];
let previousNewest = 0, sampling = true, pollTask;
async function snapshot() {
  try {
    const output = await shell(latencyCommand, 5000);
    const current = [];
    for (const line of output.stdout.split(/\r?\n/)) {
      const values = line.trim().split(/\s+/).map(Number);
      if (values.length !== 3 || !values.every((v) => Number.isSafeInteger(v) && v > 0)) continue;
      const [requestedNs, presentedNs, readyNs] = values;
      current.push(presentedNs);
      presented.set(presentedNs, { requestedNs, presentedNs, readyNs });
    }
    if (previousNewest && !current.length) presentationErrors.push('SurfaceFlinger returned no valid rows after recording began; the app surface may have vanished and pacing coverage is incomplete.');
    if (previousNewest && current.length && !current.includes(previousNewest)) presentationErrors.push('SurfaceFlinger ring buffer no longer overlaps the previous sample; pacing coverage is incomplete.');
    if (current.length) previousNewest = Math.max(...current);
  } catch (error) { presentationErrors.push(String(error)); }
}
try {
  await snapshot(); // Finish discovery/history sampling before the first input.
  pollTask = (async () => { while (sampling) { await delay(350); if (sampling) await snapshot(); } })();
  const x = Math.round(width / 2), top = Math.round(height * 500 / 2316), bottom = Math.round(height * 1650 / 2316);
  const readClock = `'${clockHelper}'`;
  const action = (input, wait) => `${readClock}; ${input}; ${readClock}; sleep ${wait}`;
  const up = action(`input swipe ${x} ${bottom} ${x} ${top} 500`, 0.1);
  const down = action(`input swipe ${x} ${top} ${x} ${bottom} 500`, 0.1);
  const numbers = Array.from({ length: cycles }, (_, i) => i + 1).join(' ');
  const body = mode === 'tabs'
    ? `for i in ${numbers}; do ${taps.map(([tx, ty]) => action(`input tap ${tx} ${ty}`, tapWaitMs / 1000)).join('; ')}; done`
    : pattern === 'alternate' ? `for i in ${numbers}; do ${up}; ${down}; done` : `for i in ${numbers}; do ${up}; done; for i in ${numbers}; do ${down}; done`;
  const actionCount = cycles * (mode === 'tabs' ? taps.length : 2);
  const execution = await shell(`set -e; ${body}`, Math.max(60000, actionCount * (mode === 'tabs' ? tapWaitMs + 1000 : 1000) + 15000));
  const samples = markers(execution.stdout);
  if (samples.length !== actionCount * 2) throw new Error(`Expected ${actionCount * 2} native clock markers, received ${samples.length}`);
  const actionWindows = Array.from({ length: actionCount }, (_, i) => ({
    action: i + 1, type: mode === 'tabs' ? 'tap' : 'swipe',
    ...(mode === 'tabs' ? { cycle: Math.floor(i / taps.length) + 1, tapIndex: i % taps.length, x: taps[i % taps.length][0], y: taps[i % taps.length][1] } : {}),
    startBootSeconds: samples[i * 2].bootNs / 1e9, endBootSeconds: samples[i * 2 + 1].bootNs / 1e9,
    startMonotonicNs: samples[i * 2].monotonicNs, endMonotonicNs: samples[i * 2 + 1].monotonicNs,
  }));
  const safe = actionWindows.map((w) => ({ startNs: w.startMonotonicNs + uncertaintyMs * 1e6, endNs: w.endMonotonicNs - uncertaintyMs * 1e6 }));
  const motion = mergeWindows(safe.map((w) => ({ startNs: w.startNs, endNs: w.endNs + motionTailMs * 1e6 })));
  const observation = mode === 'tabs' ? actionWindows.map((w, i) => ({ startNs: w.startMonotonicNs + uncertaintyMs * 1e6, endNs: Math.min(w.endMonotonicNs + tapWaitMs * 1e6, actionWindows[i + 1]?.startMonotonicNs ?? Infinity) - uncertaintyMs * 1e6 })) : [];
  // Script waits after its final action too; this extra drain includes a fresh
  // final SF query after every requested tail/observation, outside the input.
  await delay(Math.max(350, motionTailMs + 350));
  sampling = false;
  await pollTask;
  await snapshot();
  await verifyScreen(afterLabel, 'after sampling');
  const startNs = actionWindows[0].startMonotonicNs, endNs = actionWindows.at(-1).endMonotonicNs;
  const capturedEndNs = Math.max(endNs, ...motion.map((w) => w.endNs), ...observation.map((w) => w.endNs));
  const allRows = [...presented.values()].sort((a, b) => a.presentedNs - b.presentedNs);
  const presentationFrames = allRows.filter((f) => f.requestedNs >= startNs && f.requestedNs <= endNs);
  const presentationFramesWithTail = allRows.filter((f) => f.requestedNs >= startNs && f.requestedNs <= capturedEndNs);
  const summarize = (rows, windows) => {
    const values = intervals(rows, windows);
    const frameCount = rows.filter((f) => windows.some((w) => f.requestedNs >= w.startNs && f.requestedNs <= w.endNs)).length;
    return { surfaceName, frames: frameCount, intervals: values.length, intervalMs: distribution(values), ...Object.fromEntries([16, 25, 50, 100].map((n) => [`over${n}ms`, values.filter((v) => v > n).length])), syncUncertaintyMs: uncertaintyMs, reliableCoverage: presentationErrors.length === 0, errors: presentationErrors };
  };
  const active = summarize(presentationFrames, safe), withTail = summarize(presentationFramesWithTail, motion);
  if (mode === 'scroll' && !active.intervals) throw new Error('No app presentation intervals during scroll input; native pacing is unavailable.');
  const transitions = mode === 'tabs' ? actionWindows.map((w, i) => {
    const window = observation[i];
    // This may be an in-flight/background frame, not a frame containing the
    // destination tab. The command's pre-marker also includes input startup.
    const first = allRows.find((f) => f.presentedNs >= window.startNs && f.presentedNs <= window.endNs);
    return { ...w, observationStartNs: window.startNs, observationEndNs: window.endNs,
      firstPresentationAfterTapProxy: first == null ? null : {
        latencyMs: (first.presentedNs - w.startMonotonicNs) / 1e6,
        anchor: 'native CLOCK_MONOTONIC marker immediately before input tap',
        requestedNs: first.requestedNs, presentedNs: first.presentedNs,
        requestedBeforeTapMarker: first.requestedNs < w.startMonotonicNs,
      }, presentation: summarize(presentationFramesWithTail, [window]) };
  }) : undefined;
  if (mode === 'tabs' && !transitions.some((t) => t.firstPresentationAfterTapProxy != null)) throw new Error('No app frame presented during tab observation windows.');
  const clockSync = { source: 'android-native-clock-helper', helperPath: clockHelper, bootToMonotonicSeconds: (preflight[0].bootNs - preflight[0].monotonicNs) / 1e9, uncertaintyMs };
  const summary = {
    label: options.get('--label') ?? `${mode}-native`, mode, nativeOnly: true, trackerCount: tracker,
    screen: { width, height }, cycles, pattern, resetScroll, clock: clockSync,
    uiVerification: { before: beforeLabel == null ? null : { expectedLabel: beforeLabel, passed: true }, after: afterLabel == null ? null : { expectedLabel: afterLabel, passed: true } },
    seconds: (endNs - startNs) / 1e9, secondsWithTail: (capturedEndNs - startNs) / 1e9,
    presentation: { ...active, activeIntervals: active.intervals },
    presentationWithTail: { ...withTail, motionTailMs, windowCount: motion.length },
    ...(mode === 'tabs' ? {
      tapWaitMs, taps, presentationDuringTabObservations: summarize(presentationFramesWithTail, mergeWindows(observation)),
      firstPresentationAfterTapProxy: { latencyMs: distribution(transitions.flatMap((t) => t.firstPresentationAfterTapProxy == null ? [] : [t.firstPresentationAfterTapProxy.latencyMs])), missing: transitions.filter((t) => t.firstPresentationAfterTapProxy == null).length, limitation: 'First actual app presentation after the pre-input marker; may be in-flight or unrelated. Includes input-command startup. NOT first destination-tab frame, interaction-ready, or content-ready latency.' },
    } : {}),
    limitations: ['Input markers bracket shell commands, not touchscreen delivery.', 'Native pacing and first-presentation proxies do not measure Dart build/raster CPU or content readiness.', 'Quiet observation/tail periods can intentionally render fewer frames; do not interpret them as a continuous FPS target.'],
  };
  await mkdir(dirname(options.get('--out')), { recursive: true });
  await writeFile(options.get('--out'), JSON.stringify({ summary, actionWindows, gestureWindows: mode === 'scroll' ? actionWindows : undefined, clockSync, presentationFrames, presentationFramesWithTail, motionWindows: motion, tabObservationWindows: mode === 'tabs' ? observation : undefined, transitions }, null, 2));
  console.log(JSON.stringify(summary, null, 2));
  if (presentationErrors.length) process.exitCode = 1;
} finally {
  sampling = false;
  await pollTask;
}
