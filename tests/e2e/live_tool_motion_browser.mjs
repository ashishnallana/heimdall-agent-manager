// Mounts production components/CSS with isolated synthetic stream frames.
// PUPPETEER_MODULE and LIVE_TOOL_BROWSER select existing local browser tooling;
// no browser package or production credentials are installed by this runner.
// Run against the managed static server serving LIVE_TOOL_FIXTURE_DIR.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { build } from 'vite';

const [baseUrl, evidenceDir] = process.argv.slice(2);
assert.ok(baseUrl && evidenceDir && process.env.PUPPETEER_MODULE && process.env.LIVE_TOOL_BROWSER,
  'Usage: PUPPETEER_MODULE=/path/to/module.js LIVE_TOOL_BROWSER=/path/to/chromium node tests/e2e/live_tool_motion_browser.mjs URL EVIDENCE_DIR');
await build({ configFile: path.resolve('vite.config.js'), root: path.resolve('tests/fixtures/live-tool-motion'),
  logLevel: 'warn', build: { outDir: process.env.LIVE_TOOL_FIXTURE_DIR || path.resolve(evidenceDir, '../dist'), emptyOutDir: true } });
const { default: puppeteer } = await import(pathToFileURL(process.env.PUPPETEER_MODULE).href);
const browser = await puppeteer.launch({ executablePath: process.env.LIVE_TOOL_BROWSER, headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'] });
const page = await browser.newPage();
const errors = [], requests = [], scenarios = [];
page.on('pageerror', (error) => errors.push(error.message));
page.on('request', (request) => { if (new URL(request.url()).pathname.startsWith('/api/')) requests.push(request.url()); });
await fs.mkdir(evidenceDir, { recursive: true });
const settle = () => page.evaluate(() => new Promise((resolve) => setTimeout(resolve, 280)));
const metric = () => page.evaluate(() => {
  const scroll = document.querySelector('[data-debug-id="fixture-scroll"]');
  return { top: scroll.scrollTop, height: scroll.scrollHeight, distance: scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight };
});
async function sample(name, operations, { bottom = false, stable = false } = {}) {
  const frames = await page.evaluate(async (operations) => {
    const f = window.motionFixture, scroll = document.querySelector('[data-debug-id="fixture-scroll"]');
    const messages = [...document.querySelectorAll('.msg')];
    const marker = messages.find((el) => el.getBoundingClientRect().top >= scroll.getBoundingClientRect().top) || messages.at(-1);
    const markerY = marker?.getBoundingClientRect().top;
    f.scrollWrites = [];
    const frames = [];
    for (let i = 0; i < 24; i++) {
      for (const op of operations.filter((op) => op.at === i)) {
        if (op.kind === 'calls') f.setCalls(op.ids, op.status);
        if (op.kind === 'unavailable') f.unavailable();
        if (op.kind === 'reset') f.reset();
        if (op.kind === 'prepend') f.prepend();
        if (op.kind === 'append') f.append(op.own);
        if (op.kind === 'interrupt') {
          scroll.dispatchEvent(new WheelEvent('wheel', { deltaY: -200, bubbles: true }));
          scroll.scrollTop -= 200;
        }
      }
      // Read after this frame's ResizeObserver delivery, which runs after rAF
      // but before paint. A rAF-only read would inspect the first-overflow frame
      // before the bounded observer bootstrap has had a chance to run.
      await new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)));
      frames.push({ i, at: performance.now(), top: scroll.scrollTop, height: scroll.scrollHeight,
        distance: scroll.scrollHeight - scroll.scrollTop - scroll.clientHeight,
        tools: document.querySelector('[data-debug-id="live-tool-activity"]')?.getBoundingClientRect().height || 0,
        markerDelta: marker ? marker.getBoundingClientRect().top - markerY : 0,
        moving: document.querySelectorAll('[data-tool-motion="true"]').length,
        exitingActions: document.querySelectorAll('[data-tool-phase="exiting"] button').length,
        statuses: [...document.querySelectorAll('[data-tool-key] [role="img"]')].map((el) => ({
          label: el.getAttribute('aria-label'), color: getComputedStyle(el).backgroundColor })),
        rows: document.querySelectorAll('[data-tool-key]').length, writes: f.scrollWrites.length });
    }
    return frames;
  }, operations);
  scenarios.push({ name, frames });
  const final = operations.filter((op) => ['calls', 'unavailable', 'reset'].includes(op.kind)).at(-1);
  if (final) assert.equal(frames.at(-1).rows, final.kind === 'calls' ? final.ids.length : 0,
    `${name}: expected stream rows actually rendered`);
  assert.ok(frames.every((frame) => frame.exitingActions === 0), `${name}: exits never retain shell actions`);
  if (bottom) assert.ok(frames.every((f) => Math.abs(f.distance) <= 1), `${name}: native bottom anchor stays within 1px`);
  if (stable) assert.ok(frames.every((f) => Math.abs(f.markerDelta) <= 1), `${name}: visible message remains within 1px`);
  assert.ok(frames.at(-1).writes <= 2, `${name}: no per-frame JavaScript scroll writes`);
  console.log(`PASS ${name}: max bottom distance ${Math.max(...frames.map((f) => Math.abs(f.distance)))}px; max marker delta ${Math.max(...frames.map((f) => Math.abs(f.markerDelta)))}px; JS writes ${frames.at(-1).writes}`);
  return frames;
}
try {
  await page.setViewport({ width: 1100, height: 800 });
  await page.goto(baseUrl);
  await page.waitForSelector('[data-debug-id="fixture-scroll"]');
  await settle();
  const baseline = await metric();
  const entry = await sample('bottom 0 to 1', [{ at: 0, kind: 'calls', ids: [1] }], { bottom: true });
  assert.ok(new Set(entry.map((f) => f.tools)).size > 5, 'entry interpolates layout over multiple frames');
  await sample('bottom 1 to many', [{ at: 0, kind: 'calls', ids: [1, 2, 3, 4] }], { bottom: true });
  await page.screenshot({ path: path.join(evidenceDir, 'desktop-active.png') });
  const failed = await sample('individual completion', [{ at: 0, kind: 'calls', ids: [2, 3, 4], status: 'failed' }], { bottom: true });
  assert.ok(failed.some((frame) => frame.statuses.some((status) => status.label === 'Failed' && status.color === 'rgb(239, 68, 68)')));
  const exit = await sample('final completion many to 0', [{ at: 0, kind: 'calls', ids: [], status: 'completed' }], { bottom: true });
  assert.equal(exit.at(-1).rows, 0, 'last row removed with persistent completed batch');
  assert.ok(exit.some((frame) => frame.statuses.some((status) => status.label === 'Succeeded' && status.color === 'rgb(34, 197, 94)')));
  assert.equal((await metric()).height, baseline.height, 'no residual tail gap');
  await sample('rapid exit and reentry', [{ at: 0, kind: 'calls', ids: [1] }, { at: 2, kind: 'calls', ids: [] },
    { at: 4, kind: 'calls', ids: [1, 2] }, { at: 7, kind: 'calls', ids: [2] }], { bottom: true });
  await sample('unavailable collapse', [{ at: 0, kind: 'unavailable' }], { bottom: true });
  await sample('reconnect baseline', [{ at: 0, kind: 'calls', ids: [3] }], { bottom: true });
  await sample('generation reset', [{ at: 0, kind: 'reset' }], { bottom: true });

  await page.evaluate(() => { const s = document.querySelector('[data-debug-id="fixture-scroll"]'); s.scrollTop = 1000; });
  await settle();
  await sample('history entry stable', [{ at: 0, kind: 'calls', ids: [1, 2, 3] }], { stable: true });
  await sample('history exit stable', [{ at: 0, kind: 'calls', ids: [] }], { stable: true });
  await sample('history prepend stable', [{ at: 0, kind: 'prepend' }], { stable: true });
  await sample('inbound append in history stable', [{ at: 0, kind: 'append', own: false }], { stable: true });
  await page.evaluate(() => window.motionFixture.append(true));
  await page.waitForFunction(() => {
    const s = document.querySelector('[data-debug-id="fixture-scroll"]'); return s.scrollHeight - s.scrollTop - s.clientHeight <= 1;
  });
  await sample('own send restored follow', [{ at: 0, kind: 'calls', ids: [5] }], { bottom: true });
  await sample('manual interruption', [{ at: 0, kind: 'calls', ids: [5, 6, 7, 8] }, { at: 3, kind: 'interrupt' }]);
  assert.ok((await metric()).distance > 150, 'upward scrolling cancels follow');
  await page.click('[data-debug-id="fixture-jump-latest-btn"]');
  await page.waitForFunction(() => { const s = document.querySelector('[data-debug-id="fixture-scroll"]'); return s.scrollHeight - s.scrollTop - s.clientHeight <= 1; });

  await page.setViewport({ width: 390, height: 700 });
  await page.evaluate(() => window.motionFixture.setInset(140));
  await settle();
  await sample('narrow inset exit', [{ at: 0, kind: 'calls', ids: [] }], { bottom: true });
  await sample('narrow inset entry', [{ at: 0, kind: 'calls', ids: [1, 2, 3] }], { bottom: true });
  await page.screenshot({ path: path.join(evidenceDir, 'narrow-active.png') });
  await page.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }]);
  await sample('dynamic reduced motion exit', [{ at: 0, kind: 'calls', ids: [] }], { bottom: true });
  await sample('reduced motion entry', [{ at: 0, kind: 'calls', ids: [9] }], { bottom: true });
  await page.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'no-preference' }]);
  await sample('reduced motion off with visible call', [], { bottom: true });
  await page.screenshot({ path: path.join(evidenceDir, 'narrow-reduced-toggle.png') });
  await page.evaluate(() => { window.motionFixture.setCalls([]); window.motionFixture.setMessageCount(2); });
  await settle();
  await sample('short thread grows beyond viewport', [{ at: 0, kind: 'calls', ids: Array.from({ length: 24 }, (_, i) => i) }], { bottom: true });
  await sample('short thread collapses', [{ at: 0, kind: 'calls', ids: [] }], { bottom: true });
  assert.deepEqual(errors, [], 'no browser errors');
  assert.deepEqual(requests, [], 'fixture makes no production API requests');
  await fs.writeFile(path.join(evidenceDir, 'evidence.json'), JSON.stringify({ status: 'pass', browser: await browser.version(),
    baseUrl, source: 'production-components-synthetic-stream', scenarios, errors, requests }, null, 2));
  console.log(`PASS ${scenarios.length} browser scenarios; evidence ${evidenceDir}`);
} catch (error) {
  await fs.writeFile(path.join(evidenceDir, 'failure.json'), JSON.stringify({ error: error.message, scenarios, errors }, null, 2));
  await page.screenshot({ path: path.join(evidenceDir, 'failure.png') });
  throw error;
} finally { await browser.close(); }
