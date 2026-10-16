// Collect Flutter profile FrameTiming while another process/user drives the UI.
// This is NOT a monitor refresh/FPS or native DWM presentation measurement.
// Usage: node tool/profile_windows_frames.mjs --uri http://127.0.0.1:PORT/TOKEN=/
//   --seconds 15 --hz 60 --out build/diagnostics/windows-frames.json
// Optional --windows-file JSON contains [{startQpcMs,endQpcMs,label}] (preferred)
// or [{startUnixMs,endUnixMs,label}]. QPC milliseconds must use Windows
// Stopwatch.GetTimestamp()*1000/Stopwatch.Frequency, matching Node hrtime. These
// must bracket continuous motion only: do not include idle pauses in FPS.
// --tab-markers true additionally records Dart timeline markers from BStream.
// Start interacting after BSTREAM_PROFILE_READY is printed. Node 22+ required.
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const delay = (ms) => new Promise((done) => setTimeout(done, ms));

export function distribution(values) {
  if (!values.length) return null;
  if (!values.every(Number.isFinite)) throw new Error('Non-finite timing value');
  const sorted = values.toSorted((a, b) => a - b);
  const percentile = (p) => sorted[Math.ceil(p * sorted.length) - 1];
  return {
    count: sorted.length,
    mean: values.reduce((sum, value) => sum + value, 0) / values.length,
    p50: percentile(0.5), p90: percentile(0.9), p95: percentile(0.95),
    p99: percentile(0.99), max: sorted.at(-1),
  };
}

export function validateWindows(windows, startTime, endTime, clock = 'unix') {
  if (!Array.isArray(windows)) throw new Error('Windows file must contain an array');
  const startKey = clock === 'qpc' ? 'startQpcMs' : 'startUnixMs';
  const endKey = clock === 'qpc' ? 'endQpcMs' : 'endUnixMs';
  const sorted = windows.map((window) => {
    if (!window || !Number.isFinite(window[startKey]) || !Number.isFinite(window[endKey]) ||
        window[endKey] <= window[startKey] || window[startKey] < startTime || window[endKey] > endTime) {
      throw new Error('Motion windows must be finite, increasing, and inside the measured capture');
    }
    if (window.label != null && (typeof window.label !== 'string' || window.label.length > 200)) {
      throw new Error('Window label must be a string of at most 200 characters');
    }
    return { ...window };
  }).toSorted((a, b) => a[startKey] - b[startKey]);
  for (let i = 1; i < sorted.length; i++) {
    if (sorted[i][startKey] < sorted[i - 1][endKey]) throw new Error('Motion windows must not overlap');
  }
  return sorted;
}

export function summarizeFrames(frames, hz, continuousMotion = false) {
  const budgetUs = 1e6 / hz;
  const sorted = frames.toSorted((a, b) => a.startTime - b.startTime);
  const intervals = sorted.slice(1).map((frame, i) => (frame.startTime - sorted[i].startTime) / 1000);
  const intervalStats = distribution(intervals);
  const vsyncStarts = sorted.map((frame) => frame.startTime - frame.vsyncOverhead).sort((a, b) => a - b);
  const vsyncIntervals = vsyncStarts.slice(1).map((time, i) => (time - vsyncStarts[i]) / 1000);
  const vsyncIntervalStats = distribution(vsyncIntervals);
  return {
    frames: sorted.length, budgetMs: budgetUs / 1000,
    buildMs: distribution(sorted.map((frame) => frame.build / 1000)),
    rasterMs: distribution(sorted.map((frame) => frame.raster / 1000)),
    vsyncOverheadMs: distribution(sorted.map((frame) => frame.vsyncOverhead / 1000)),
    elapsedMs: distribution(sorted.map((frame) => frame.elapsed / 1000)),
    slowBuildFrames: sorted.filter((frame) => frame.build > budgetUs).length,
    slowRasterFrames: sorted.filter((frame) => frame.raster > budgetUs).length,
    slowPipelineFrames: sorted.filter((frame) => frame.build > budgetUs || frame.raster > budgetUs).length,
    buildStartIntervalMs: intervalStats,
    vsyncStartIntervalMs: vsyncIntervalStats,
    // Even with known motion windows this is framework cadence, NOT screen FPS.
    frameworkCadenceFps: continuousMotion && intervalStats?.mean > 0 ? 1000 / intervalStats.mean : null,
    vsyncStartCadenceFps: continuousMotion && vsyncIntervalStats?.mean > 0 ? 1000 / vsyncIntervalStats.mean : null,
    continuousMotion,
  };
}

export function tabLatencies(events) {
  const requests = new Map();
  const matches = [];
  for (const event of events.toSorted((a, b) => a.ts - b.ts)) {
    if (event.name === 'BStream.tab.request') requests.set(event.args?.requestId, event);
    if (event.name !== 'BStream.tab.firstBuildComplete') continue;
    const request = requests.get(event.args?.requestId);
    if (!request || request.args?.to !== event.args?.to || event.ts < request.ts) continue;
    matches.push({
      requestId: request.args.requestId, from: request.args.from, to: request.args.to,
      stillSelected: event.args.stillSelected, requestMicros: request.ts,
      firstBuildCompleteMicros: event.ts, handlerToFirstBuildMs: (event.ts - request.ts) / 1000,
    });
    requests.delete(event.args.requestId);
  }
  return {
    matches, missingCompletions: [...requests.values()].map((event) => event.args),
    handlerToFirstBuildMs: distribution(matches.filter((match) => match.stillSelected).map((match) => match.handlerToFirstBuildMs)),
    caveat: 'Handler to first completed framework build; not native presentation or all network content ready.',
  };
}

export function parseOptions(argv) {
  const allowed = new Set(['--uri', '--seconds', '--hz', '--out', '--label', '--windows-file', '--tab-markers']);
  const options = new Map();
  for (let i = 0; i < argv.length; i += 2) {
    if (!allowed.has(argv[i]) || argv[i + 1] == null || options.has(argv[i])) throw new Error(`Invalid option: ${argv[i]}`);
    options.set(argv[i], argv[i + 1]);
  }
  if (!options.get('--uri') || !options.get('--out')) throw new Error('--uri and --out are required');
  const seconds = Number(options.get('--seconds') ?? 15);
  const hz = Number(options.get('--hz') ?? 60);
  if (!Number.isFinite(seconds) || seconds < 1 || seconds > 120) throw new Error('--seconds must be between 1 and 120');
  if (!Number.isFinite(hz) || hz < 10 || hz > 1000) throw new Error('--hz must be between 10 and 1000');
  if (options.has('--tab-markers') && !['true', 'false'].includes(options.get('--tab-markers'))) throw new Error('--tab-markers must be true or false');
  const uri = new URL(options.get('--uri'));
  if (!['http:', 'https:', 'ws:', 'wss:'].includes(uri.protocol)) throw new Error('Unsupported VM service URI');
  uri.protocol = ['http:', 'ws:'].includes(uri.protocol) ? 'ws:' : 'wss:';
  uri.pathname = `${uri.pathname.replace(/\/$/, '').replace(/\/ws$/, '')}/ws`;
  return { uri, seconds, hz, out: options.get('--out'), label: options.get('--label') ?? 'windows-profile', windowsFile: options.get('--windows-file'), tabMarkers: options.get('--tab-markers') === 'true' };
}

async function capture(options) {
  const socket = new WebSocket(options.uri);
  const pending = new Map();
  const frames = [];
  let nextId = 0;
  let originalFlags;
  let polling = false;
  let pollTask;
  const events = new Map();
  socket.addEventListener('message', ({ data }) => {
    const message = JSON.parse(data);
    if (message.id != null) {
      const callback = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) callback?.reject(new Error(JSON.stringify(message.error)));
      else callback?.resolve(message.result);
    }
    const event = message.params?.event;
    if (event?.extensionKind === 'Flutter.Frame') {
      const frame = event.extensionData;
      if (['startTime', 'build', 'raster', 'vsyncOverhead', 'elapsed'].every((key) => Number.isFinite(frame?.[key]) && frame[key] >= 0)) frames.push(frame);
    }
  });
  socket.addEventListener('close', () => {
    for (const callback of pending.values()) callback.reject(new Error('VM service disconnected'));
    pending.clear();
  });
  await new Promise((done, fail) => {
    const timeout = setTimeout(() => { socket.close(); fail(new Error('VM service connection timed out')); }, 10000);
    socket.addEventListener('open', () => { clearTimeout(timeout); done(); }, { once: true });
    socket.addEventListener('error', () => { clearTimeout(timeout); fail(new Error('Cannot connect to VM service')); }, { once: true });
  });
  function rpc(method, params = {}) {
    const id = ++nextId;
    return new Promise((done, fail) => {
      const timeout = setTimeout(() => { pending.delete(id); fail(new Error(`Timed out: ${method}`)); }, 10000);
      pending.set(id, {
        resolve: (value) => { clearTimeout(timeout); done(value); },
        reject: (error) => { clearTimeout(timeout); fail(error); },
      });
      socket.send(JSON.stringify({ jsonrpc: '2.0', id, method, params }));
    });
  }
  async function clockAnchor() {
    const beforeUnixMs = Date.now();
    const beforeQpcMs = Number(process.hrtime.bigint()) / 1e6;
    const { timestamp: vmMicros } = await rpc('getVMTimelineMicros');
    const afterUnixMs = Date.now();
    const afterQpcMs = Number(process.hrtime.bigint()) / 1e6;
    return {
      vmMicros, unixMs: (beforeUnixMs + afterUnixMs) / 2, qpcMs: (beforeQpcMs + afterQpcMs) / 2,
      uncertaintyMs: (afterQpcMs - beforeQpcMs) / 2 + 0.001,
    };
  }
  try {
    const vm = await rpc('getVM');
    originalFlags = await rpc('getVMTimelineFlags');
    await rpc('streamListen', { streamId: 'Extension' });
    await rpc('setVMTimelineFlags', { recordedStreams: options.tabMarkers ? ['Dart'] : [] });
    if (options.tabMarkers) {
      polling = true;
      pollTask = (async () => {
        do {
          const result = await rpc('getVMTimeline');
          for (const event of result.traceEvents ?? []) {
            if (event.name?.startsWith('BStream.tab.')) events.set(JSON.stringify(event), event);
          }
          if (polling) await delay(250);
        } while (polling);
      })();
      pollTask.catch(() => {});
    }
    await delay(250);
    const start = await clockAnchor();
    console.log(`BSTREAM_PROFILE_READY ${JSON.stringify({ label: options.label, startUnixMs: start.unixMs, startQpcMs: start.qpcMs, seconds: options.seconds })}`);
    await delay(options.seconds * 1000);
    const end = await clockAnchor();
    await delay(700); // FrameTiming arrives in batches after raster completion.
    polling = false;
    await pollTask;
    const clockDriftMs = (end.unixMs - start.unixMs) - (end.qpcMs - start.qpcMs);
    const vmQpcDriftMs = (end.vmMicros - start.vmMicros) / 1000 - (end.qpcMs - start.qpcMs);
    const clockUncertaintyMs = Math.max(start.uncertaintyMs, end.uncertaintyMs) + Math.abs(vmQpcDriftMs);
    const sample = frames.filter((frame) => {
      const vsyncStart = frame.startTime - frame.vsyncOverhead;
      return vsyncStart >= start.vmMicros && vsyncStart <= end.vmMicros;
    });
    if (!sample.length) throw new Error(`No Flutter FrameTiming inside measured window; received ${frames.length} raw events. Use a foreground profile build and interact during capture. VM range ${start.vmMicros}..${end.vmMicros}; raw frame range ${frames[0]?.startTime ?? 'none'}..${frames.at(-1)?.startTime ?? 'none'}`);
    const requestedWindows = options.windowsFile ? JSON.parse(await readFile(options.windowsFile, 'utf8')) : [];
    const windowClock = requestedWindows[0]?.startQpcMs != null ? 'qpc' : 'unix';
    const clockKey = windowClock === 'qpc' ? 'qpcMs' : 'unixMs';
    const startKey = windowClock === 'qpc' ? 'startQpcMs' : 'startUnixMs';
    const endKey = windowClock === 'qpc' ? 'endQpcMs' : 'endUnixMs';
    const windows = validateWindows(requestedWindows, start[clockKey], end[clockKey], windowClock);
    const samplesByWindow = windows.map((window) => {
      // Trim uncertain edges rather than attributing pre-input frames to motion.
      const edgeUncertaintyMs = clockUncertaintyMs + (windowClock === 'unix' ? 1 + Math.abs(clockDriftMs) : 0);
      const startMicros = start.vmMicros + (window[startKey] - start[clockKey] + edgeUncertaintyMs) * 1000;
      const endMicros = start.vmMicros + (window[endKey] - start[clockKey] - edgeUncertaintyMs) * 1000;
      if (endMicros <= startMicros) throw new Error('Motion window is shorter than host/VM clock uncertainty');
      return { ...window, startMicros, endMicros, ...summarizeFrames(sample.filter((frame) => {
        const vsyncStart = frame.startTime - frame.vsyncOverhead;
        return vsyncStart >= startMicros && vsyncStart <= endMicros;
      }), options.hz, true) };
    });
    const tabEvents = [...events.values()].filter((event) => event.ts >= start.vmMicros && event.ts <= end.vmMicros);
    const summary = {
      label: options.label, platform: 'windows', vmPid: vm.pid, vmVersion: vm.version,
      seconds: (end.vmMicros - start.vmMicros) / 1e6,
      nativePresentationMeasured: false,
      caveat: 'FrameTiming is framework/render-thread wall time, not GPU busy time or native display presentation. Build-start cadence is not screen FPS. Idle gaps remain in whole-capture intervals; interpret cadence only in externally verified continuous-motion windows.',
      windowClock, clockUncertaintyMs, clockDriftMs, vmQpcDriftMs, ...summarizeFrames(sample, options.hz),
      windows: samplesByWindow, tabLatency: options.tabMarkers ? tabLatencies(tabEvents) : null,
    };
    if (windows.length && windowClock === 'unix' && Math.abs(clockDriftMs) > 5) throw new Error('Host wall-clock changed during capture; window alignment is unreliable');
    await mkdir(dirname(options.out), { recursive: true });
    await writeFile(options.out, JSON.stringify({ summary, clockAnchors: { start, end }, frames: sample, tabEvents }, null, 2));
    console.log(JSON.stringify(summary, null, 2));
  } finally {
    polling = false;
    try {
      await pollTask?.catch(() => {});
      if (originalFlags && socket.readyState === WebSocket.OPEN) await rpc('setVMTimelineFlags', { recordedStreams: originalFlags.recordedStreams });
    } finally { socket.close(); }
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  capture(parseOptions(process.argv.slice(2))).catch((error) => { console.error(error.message); process.exitCode = 1; });
}
