// Exercises the actual transparent browser source, including live style
// changes, responsive layout, queue reconciliation, and paused animations.
// Uses Node's built-in CDP WebSocket client; no browser automation dependency.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const capture = process.argv.includes('--capture');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const windows = process.platform === 'win32';
const browsers = [
  process.env.BSTREAM_BROWSER,
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/usr/bin/chromium',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
];
const browserPath = browsers.find(candidate => candidate && existsSync(candidate));
assert.ok(browserPath, 'Install Chrome/Edge or set BSTREAM_BROWSER.');

let dartPath = 'dart';
if (windows) {
  const located = spawnSync('where.exe', ['dart'], { encoding: 'utf8', windowsHide: true });
  const flutterDart = located.stdout?.split(/\r?\n/).find(value => value.endsWith('dart.bat'));
  assert.ok(flutterDart, 'Dart must be on PATH.');
  dartPath = path.join(path.dirname(flutterDart), 'cache', 'dart-sdk', 'bin', 'dart.exe');
}

function ready(child, regex, label) {
  return new Promise((resolve, reject) => {
    let output = '';
    const timer = setTimeout(() => finish(new Error(`${label} did not start: ${output.slice(-2000)}`)), 60000);
    const data = chunk => {
      output += chunk.toString();
      const match = output.match(regex);
      if (match) finish(null, match[1]);
    };
    const exited = code => finish(new Error(`${label} exited (${code}): ${output.slice(-2000)}`));
    const failed = error => finish(error);
    function finish(error, value) {
      clearTimeout(timer);
      child.stdout?.off('data', data);
      child.stderr?.off('data', data);
      child.off('exit', exited);
      child.off('error', failed);
      child.stdout?.resume();
      child.stderr?.resume();
      if (error) reject(error); else resolve(value);
    }
    child.stdout?.on('data', data);
    child.stderr?.on('data', data);
    child.once('exit', exited);
    child.once('error', failed);
  });
}

class CDP {
  constructor(url) {
    this.socket = new WebSocket(url);
    this.id = 0;
    this.pending = new Map();
    this.exceptions = [];
    this.opened = new Promise((resolve, reject) => {
      this.socket.addEventListener('open', resolve, { once: true });
      this.socket.addEventListener('error', reject, { once: true });
    });
    this.socket.addEventListener('message', event => {
      const message = JSON.parse(event.data);
      if (message.method === 'Runtime.exceptionThrown') this.exceptions.push(message.params.exceptionDetails);
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) pending.reject(new Error(JSON.stringify(message.error)));
      else pending.resolve(message.result);
    });
  }
  async send(method, params = {}) {
    await this.opened;
    return new Promise((resolve, reject) => {
      const id = ++this.id;
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); }, 15000);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async evaluate(expression) {
    const result = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    assert.ok(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
    return result.result.value;
  }
}

const profilePrefix = path.join(tmpdir(), 'bstream-overlay-browser-');
const profile = await mkdtemp(profilePrefix);
let browser;
let server;
let cdp;

try {
  server = spawn(dartPath, ['run', 'tool/live_overlay_preview.dart', '--loopback', '--style=wave'], { cwd: root, windowsHide: true });
  const overlayUrl = await ready(server, /(http:\/\/127\.0\.0\.1:\d+\/overlay)/, 'Overlay fixture');
  browser = spawn(browserPath, [
    '--headless=new', '--disable-gpu', '--disable-dev-shm-usage', '--no-first-run',
    '--no-default-browser-check', '--disable-background-networking',
    '--remote-debugging-port=0', `--user-data-dir=${profile}`,
    ...(process.platform === 'linux' ? ['--no-sandbox'] : []), 'about:blank',
  ], { windowsHide: true });
  const browserUrl = await ready(browser, /(ws:\/\/127\.0\.0\.1:\d+\/devtools\/browser\/[^\s]+)/, 'Headless browser');
  const address = new URL(browserUrl);
  const targets = await (await fetch(`http://${address.host}/json/list`)).json();
  cdp = new CDP(targets.find(target => target.type === 'page').webSocketDebuggerUrl);
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');
  await cdp.send('Emulation.setDefaultBackgroundColorOverride', { color: { r: 0, g: 0, b: 0, a: 0 } });
  const viewport = width => cdp.send('Emulation.setDeviceMetricsOverride', { width, height: 760, deviceScaleFactor: 1, mobile: false });
  await viewport(1280);
  await cdp.send('Page.navigate', { url: overlayUrl });
  for (let attempt = 0; attempt < 100; attempt++) {
    if (await cdp.evaluate('Boolean(window.__bstreamPreviewRender && document.querySelectorAll(".track").length === 5)')) break;
    await delay(100);
  }
  await cdp.evaluate('window.__base = structuredClone(window.__bstreamPreviewState); Boolean(window.__base)');
  await delay(500);

  const render = patch => cdp.evaluate(`window.__bstreamPreviewRender({...window.__base, ...${JSON.stringify(patch)}}); true`);
  const settle = () => cdp.evaluate('Promise.allSettled(document.getAnimations().filter(animation => !animation.effect?.target?.classList?.contains("wave-bar")).map(animation => animation.finished)).then(() => true)');
  const measure = () => cdp.evaluate(`(() => {
    const card = document.querySelector('.current:not(.leaving)');
    const rect = selector => card.querySelector(selector).getBoundingClientRect().toJSON();
    return { style: document.getElementById('overlay').dataset.style,
      cover: rect('.artwork'), details: rect('.details'), times: rect('.time-row'),
      rail: rect('.progress'), elapsed: rect('.elapsed'), duration: rect('.duration'), wave: rect('.waveform'),
      bottom: Math.max(...[...document.querySelectorAll('.track:not(.leaving)')].map(node => node.getBoundingClientRect().bottom)),
      background: getComputedStyle(document.body).backgroundColor,
      scrollWidth: document.documentElement.scrollWidth, width: innerWidth,
      playing: card.classList.contains('is-playing'),
      barColor: getComputedStyle(card.querySelector('.wave-bar')).backgroundColor,
      animation: getComputedStyle(card.querySelector('.wave-bar')).animationPlayState,
      animationName: getComputedStyle(card.querySelector('.wave-bar')).animationName,
      parent: card.querySelector('.playback').parentElement.className };
  })()`);

  for (const width of [1280, 900, 560, 400, 320]) {
    await viewport(width);
    await settle();
    const layout = await measure();
    assert.equal(layout.style, 'wave');
    assert.equal(layout.background, 'rgba(0, 0, 0, 0)');
    assert.ok(Math.abs(layout.cover.width - layout.cover.height) < 1, `Non-square cover at ${width}`);
    assert.ok(layout.cover.right < layout.details.left, `Overlapping cover/title at ${width}`);
    assert.ok(Math.abs(layout.cover.top - layout.details.top) < 1 && Math.abs(layout.cover.bottom - layout.times.bottom) < 1, `Panel alignment at ${width}`);
    assert.ok(layout.elapsed.right <= layout.wave.left + 1 && layout.wave.right <= layout.duration.left + 1, `Overlapping times/wave at ${width}`);
    assert.ok(layout.bottom <= 760 && layout.scrollWidth <= width, `Overflow at ${width}`);
    assert.ok(Math.abs(layout.rail.left - layout.cover.left) < 1 && Math.abs(layout.rail.right - layout.details.right) < 1, `Rail alignment at ${width}`);
  }
  await viewport(1280);
  await render({ accent: { seed: '#FF3B3F', dark: '#C62828' } });
  assert.equal((await measure()).barColor, 'rgb(255, 59, 63)');
  await cdp.evaluate('window.__card = document.querySelector(".current"); true');
  await render({ positionMs: 162000, durationMs: 278000, progress: .58 });
  assert.equal(await cdp.evaluate('window.__card === document.querySelector(".current")'), true, 'Progress rebuilt the current card');
  assert.equal(await cdp.evaluate('document.querySelector(".elapsed").textContent'), '2:42');
  assert.equal(await cdp.evaluate('document.querySelector(".duration").textContent'), '4:38');
  assert.equal((await measure()).animation, 'running');
  await render({ items: await cdp.evaluate('window.__base.items.map((item, index) => index === 0 ? {...item, status: "paused"} : item)') });
  assert.equal((await measure()).animation, 'paused');
  await render({});
  await cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] });
  assert.equal((await measure()).animationName, 'none');
  await cdp.send('Emulation.setEmulatedMedia', { features: [] });
  await cdp.evaluate('Object.defineProperty(document, "hidden", {configurable: true, value: true}); document.dispatchEvent(new Event("visibilitychange")); true');
  assert.equal((await measure()).animation, 'paused');
  await cdp.evaluate('Object.defineProperty(document, "hidden", {configurable: true, value: false}); document.dispatchEvent(new Event("visibilitychange")); true');

  async function screenshot(name) {
    if (!capture) return;
    await settle();
    await mkdir(path.join(root, 'build'), { recursive: true });
    const result = await cdp.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false });
    await writeFile(path.join(root, 'build', name), Buffer.from(result.data, 'base64'));
  }
  await screenshot('live-widget-wave.png');
  await render({ style: 'classic' });
  await settle();
  const classic = await measure();
  assert.equal(classic.style, 'classic');
  assert.equal(classic.cover.width, 100);
  assert.equal(classic.parent, 'details');
  assert.equal(await cdp.evaluate('window.__card === document.querySelector(".current")'), true, 'Style switch replaced the card');
  await screenshot('live-widget-classic.png');
  await render({ style: '<script>', accent: { seed: 'url(invalid)', dark: 'invalid' } });
  assert.equal((await measure()).style, 'classic');
  assert.equal(await cdp.evaluate('getComputedStyle(document.documentElement).getPropertyValue("--accent").trim()'), '#f5f7f5');
  await render({ style: 'wave', items: await cdp.evaluate('window.__base.items.slice(1)') });
  await settle();
  assert.equal(await cdp.evaluate('document.querySelectorAll(".track:not(.leaving)").length'), 4);
  assert.equal(await cdp.evaluate('document.querySelectorAll(".playback").length'), 1);
  assert.equal((await measure()).animation, 'paused', 'A ready song should not animate');
  assert.deepEqual(cdp.exceptions, [], 'Browser reported a JavaScript exception');
  console.log('LIVE overlay browser smoke passed: both styles, 5 viewport sizes, transparency, accent, progress, pause, reduced motion, visibility, and queue transitions.');
} finally {
  if (cdp) {
    await cdp.send('Browser.close').catch(() => {});
    cdp.socket.close();
  }
  if (browser && browser.exitCode === null) {
    await delay(500);
    if (browser.exitCode === null) browser.kill();
  }
  if (server && server.exitCode === null) {
    server.stdin.end('\n');
    for (let count = 0; count < 50 && server.exitCode === null; count++) await delay(100);
    if (server.exitCode === null) server.kill();
  }
  assert.ok(path.resolve(profile).startsWith(path.resolve(profilePrefix)), 'Unsafe browser profile cleanup path');
  await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 300 });
}
