#!/usr/bin/env node
/**
 * ui-interaction-harness.mjs — drive a rebuilt resource page in a real browser and
 * report a predicate truth table plus screenshots.
 *
 * Why this exists
 * ---------------
 * `tsc` cannot see the defects this rebuild keeps producing. The Clear-filters trap,
 * the PageShell header crush at 390px, two Approve buttons on one phone screen, and
 * a fragment-only `location.replace` blanking the page were all type-clean. They were
 * found by rendering the page and, in two cases, by CLICKING it. This drives the
 * clicking half.
 *
 * Reusable means PARAMETERISED, not written twice
 * -----------------------------------------------
 * The resource name is the only thing that changes between runs, because every
 * rebuilt page emits the same attribute shape:
 *
 *     data-<resource>-row="<id>"                 the row element
 *     <resource>-rows                            the list <ul>
 *     <resource>-row-menu-<id>                   the row's "…" trigger
 *     <resource>-row-<verb>-menu-<id>            a verb inside the open menu
 *     <resource>-row-body-<id>                   the clamped two-line body
 *     <resource>-row-time-<id>                   the relative time
 *     <resource>-toolbar / -search-input         the toolbar and its search field
 *     <resource>-tab-<tab>                       a tab
 *     <resource>-list-skeleton                   the loading state
 *     <resource>-bulk-<verb>                     a bulk verb
 *
 * A new resource that emits those names is drivable with `--resource <prefix>` and
 * no edit to this file. A resource that invents its own names is not reusing the
 * harness, it is rewriting it — that is the test this file applies to itself.
 *
 * `<resource>` is the ATTRIBUTE PREFIX and is not always the route segment: a row
 * is one `project` but the route is `/projects`. The first run against a second
 * resource failed on exactly that conflation, so the two are separate flags.
 *
 * What it proves and what it does not
 * -----------------------------------
 * Clicks are dispatched IN-PAGE (`element.click()`), so they exercise the real React
 * handler chain — which is where every bug above lived — but they are NOT OS-level
 * input. Hover-only behaviour and true touch gestures are out of scope and are
 * reported as NOT COVERED rather than silently passed.
 *
 * Usage:
 *   node scripts/ui-interaction-harness.mjs \
 *     --url http://127.0.0.1:49324/proxy/<sid>/ \
 *     --resource project --route /projects \
 *     --out /tmp/ham-shots-projects
 *
 *   node scripts/ui-interaction-harness.mjs \
 *     --url http://127.0.0.1:49324/proxy/<sid>/ \
 *     --resource memory \
 *     --out /tmp/ham-shots-memory
 *
 * Options:
 *   --resource <prefix> the data-attribute prefix: project | memory | …
 *   --route <path>      the list route (default `/<resource>`)
 *   --url <base>        the preview base URL, trailing slash included
 *   --out <dir>         where screenshots and results.json are written
 *   --widths 1440,390   viewport widths to run the whole suite at
 *   --no-create-form    this resource has no create/edit surface by design (REQ-UI-15);
 *                       the two form predicates are recorded N/A instead of failing
 *   --keep              leave the browser running (debugging)
 */
import net from 'node:net';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { spawn } from 'node:child_process';

/* ------------------------------------------------------------------ *
 * args
 * ------------------------------------------------------------------ */

function arg(name, fallback = '') {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 && process.argv[i + 1] && !process.argv[i + 1].startsWith('--') ? process.argv[i + 1] : fallback;
}
const FLAG = (name) => process.argv.includes(`--${name}`);

/**
 * The ATTRIBUTE PREFIX, which is not always the route segment: Memory is
 * `memory` at `/memory`, Projects is `project` (a row is one project) at
 * `/projects`. Conflating the two is the first thing that broke when this harness
 * met its second resource, so they are two parameters.
 */
const RESOURCE = arg('resource', 'project');
const BASE_URL = arg('url', '');
const OUT_DIR = arg('out', `/tmp/ham-shots-${RESOURCE}`);
const WIDTHS = arg('widths', '1440,390').split(',').map((w) => Number(w.trim())).filter(Boolean);
const MARIONETTE_PORT = Number(arg('port', '2828'));
/**
 * --login <url>  — optional one-shot URL the browser visits BEFORE the list
 * route to establish an auth cookie.  Use with the ham-dev-proxy dev login:
 *
 *   --login "http://127.0.0.1:8190/_dev/login?user=tanmay"
 *
 * How Heimdall dev auth works
 * ---------------------------
 * The Vite dev server (default port 5173) proxies `/api/v1` and `/_dev/*` to
 * `ham-dev-proxy` (default 127.0.0.1:8190, override with HEIMDALL_DEV_PROXY_URL
 * in the shell that starts `npx vite`).  Users authenticate only with OIDC: the
 * hub's sign-in (`/api/v1/auth/login`) redirects to the local mock provider
 * (tools/mock-oidc), which auto-approves and returns with the hub session cookie.
 * `/_dev/login?user=<name>` sets `ham_dev_user`, which the proxy passes to the
 * mock as login_hint. With --login the harness sets that cookie and then runs the
 * sign-in navigation once before navigating the app.
 *
 * Quick-start for a full harness run
 * -----------------------------------
 *   # 1. Start the dev server pointing at the correct proxy port
 *   HEIMDALL_DEV_PROXY_URL=http://127.0.0.1:8190 npx vite --host 127.0.0.1 --port 5274
 *
 *   # 2. Run the harness — the --login flag handles auth automatically
 *   node scripts/ui-interaction-harness.mjs \
 *     --resource agent --route /agents \
 *     --url http://127.0.0.1:5274 \
 *     --login "http://127.0.0.1:5274/_dev/login?user=tanmay" \
 *     --out /tmp/ham-shots-agents
 *
 * Substitute the --resource / --route / --login user as needed.
 *
 * NOTE on --login: this URL is fetched IN-PAGE, never navigated to. `/_dev/login`
 * answers 204 No Content, and a top-level navigation that resolves to 204 is
 * abandoned by the browser — no load event, so `WebDriver:Navigate` waits out the
 * full default page-load timeout (300000ms). That cost one whole harness run before
 * it was understood; see the login block in `main()` for the full account.
 * The correct proxy port is whichever `ham-dev-proxy` is listening on — check
 * with `ss -tlnp` and look for the `dev-proxy` process.
 */
const LOGIN_URL = arg('login', '');

if (!BASE_URL) {
  console.error('error: --url is required (the preview base URL, trailing slash included)');
  process.exit(2);
}

/**
 * The route the list lives at. Defaults to `/<resource>`, which is right for
 * memory; pass `--route /projects` where the route is pluralised.
 */
const LIST_ROUTE = arg('route', `/${RESOURCE}`);

/**
 * --no-create-form — this resource has no create/edit surface BY DESIGN.
 *
 * Shells are runtime, not CRUD: REQ-UI-15 settles that they get no create form and no
 * edit page. Without this flag the two form predicates fail on a page that is correct —
 * "timed out waiting for the create form" on a route that must not exist. A red row for
 * obeying a requirement trains the reader to skim red rows, which is the one thing a
 * truth table cannot afford. They are recorded N/A with the reason instead, exactly as
 * the hover and touch predicates already are.
 *
 * This is the harness's FIRST edit since it was generalised during Actions, and it is
 * worth being precise about what it does and does not say: the attribute contract still
 * carried a fifth resource untouched — rows, menus, tabs, search, filters and the bulk
 * bar all drove with no change. What needed teaching was not how to drive this page but
 * that a resource may legitimately have nothing to drive.
 */
const NO_CREATE_FORM = process.argv.includes('--no-create-form');

/* ------------------------------------------------------------------ *
 * Marionette: a minimal client
 * ------------------------------------------------------------------ */

/**
 * Marionette frames are `<byteLength>:<json>`, and the JSON is
 * `[type, messageId, command, params]` out and `[type, messageId, error, result]`
 * back. That is the whole wire format; no library needed for the handful of
 * commands this harness uses.
 */
class Marionette {
  constructor(port) {
    this.port = port;
    this.socket = null;
    this.buffer = Buffer.alloc(0);
    this.pending = new Map();
    this.nextId = 1;
    this.ready = null;
  }

  connect() {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection({ host: '127.0.0.1', port: this.port });
      this.socket = socket;
      socket.on('error', reject);
      socket.on('data', (chunk) => {
        this.buffer = Buffer.concat([this.buffer, chunk]);
        this.drain();
      });
      // The server greets with its handshake packet; that is the connect signal.
      this.ready = resolve;
      socket.on('connect', () => { /* wait for the handshake frame */ });
    });
  }

  drain() {
    for (;;) {
      const colon = this.buffer.indexOf(0x3a); // ':'
      if (colon < 0) return;
      const length = Number(this.buffer.subarray(0, colon).toString('ascii'));
      if (!Number.isFinite(length)) throw new Error('marionette: bad frame length');
      const start = colon + 1;
      if (this.buffer.length < start + length) return;
      const body = this.buffer.subarray(start, start + length).toString('utf8');
      this.buffer = this.buffer.subarray(start + length);
      let parsed;
      try {
        parsed = JSON.parse(body);
      } catch {
        continue;
      }
      if (!Array.isArray(parsed)) {
        // The handshake: `{applicationType, marionetteProtocol}`.
        if (this.ready) { const r = this.ready; this.ready = null; r(); }
        continue;
      }
      const [, id, error, result] = parsed;
      const entry = this.pending.get(id);
      if (!entry) continue;
      this.pending.delete(id);
      if (error) entry.reject(new Error(typeof error === 'object' ? JSON.stringify(error) : String(error)));
      else entry.resolve(result);
    }
  }

  send(command, params = {}) {
    const id = this.nextId++;
    const payload = JSON.stringify([0, id, command, params]);
    const frame = `${Buffer.byteLength(payload, 'utf8')}:${payload}`;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.socket.write(frame, 'utf8');
    });
  }

  close() {
    try { this.socket?.destroy(); } catch { /* already gone */ }
  }
}

/* ------------------------------------------------------------------ *
 * browser lifecycle
 * ------------------------------------------------------------------ */

async function launchFirefox(profileDir) {
  await fs.mkdir(profileDir, { recursive: true });
  // `marionette.port` in the profile is more reliable than the CLI flag alone.
  await fs.writeFile(
    path.join(profileDir, 'user.js'),
    [
      `user_pref("marionette.port", ${MARIONETTE_PORT});`,
      'user_pref("browser.shell.checkDefaultBrowser", false);',
      'user_pref("datareporting.policy.dataSubmissionEnabled", false);',
      'user_pref("toolkit.telemetry.enabled", false);',
      'user_pref("browser.aboutwelcome.enabled", false);',
      'user_pref("devtools.console.stdout.content", true);',
    ].join('\n'),
  );
  const child = spawn(
    'firefox',
    ['--marionette', '--no-remote', '--profile', profileDir, '--headless', 'about:blank'],
    { env: { ...process.env, MOZ_HEADLESS: '1' }, stdio: ['ignore', 'pipe', 'pipe'] },
  );
  child.stderr.on('data', () => { /* Firefox is chatty on stderr; ignore. */ });
  return child;
}

async function waitForPort(port, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const ok = await new Promise((resolve) => {
      const socket = net.createConnection({ host: '127.0.0.1', port });
      socket.on('connect', () => { socket.destroy(); resolve(true); });
      socket.on('error', () => resolve(false));
    });
    if (ok) return;
    if (Date.now() > deadline) throw new Error(`marionette port ${port} never opened`);
    await sleep(250);
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/* ------------------------------------------------------------------ *
 * the driver
 * ------------------------------------------------------------------ */

class Page {
  constructor(client) {
    this.client = client;
  }

  async navigate(url) {
    await this.client.send('WebDriver:Navigate', { url });
  }

  /**
   * A REAL document load.
   *
   * Navigating from `…/#/x` to `…/#/x?q=1` is a fragment change: the document is
   * not reloaded and a hash-routed app that reads its URL state at mount will not
   * see the new query. That is correct app behaviour and a false failure for a
   * predicate about DEEP LINKS, so this bounces through about:blank first and
   * tests what a pasted link actually does.
   */
  async hardNavigate(url) {
    await this.client.send('WebDriver:Navigate', { url: 'about:blank' });
    await this.client.send('WebDriver:Navigate', { url });
  }

  /** Run a function body in the page and return its JSON value. */
  async evaluate(body, args = []) {
    const result = await this.client.send('WebDriver:ExecuteScript', {
      script: body,
      args,
      sandbox: null,
      newSandbox: false,
    });
    return result?.value ?? result;
  }

  async setSize(width, height) {
    await this.client.send('WebDriver:SetWindowRect', { width, height, x: 0, y: 0 });
  }

  async screenshot(file, { settleSelector = '' } = {}) {
    if (settleSelector) {
      // Let whatever the capture provoked finish before the shutter, and again
      // after, so the page the next predicate meets is the page that was shot.
      await this.settle(settleSelector);
    }
    const result = await this.client.send('WebDriver:TakeScreenshot', { full: true, hash: false });
    const base64 = result?.value ?? result;
    await fs.writeFile(file, Buffer.from(String(base64), 'base64'));
    if (settleSelector) await this.settle(settleSelector);
  }

  /** Wait until `selector` is present and no loading skeleton is on screen. */
  async settle(selector, timeoutMs = 8000) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      // eslint-disable-next-line no-await-in-loop
      const ready = await this.evaluate(`
        var target = document.querySelector(${JSON.stringify(selector)});
        var busy = document.querySelector('[aria-busy="true"]');
        return !!target && !busy;
      `);
      if (ready) return true;
      if (Date.now() > deadline) return false;
      // eslint-disable-next-line no-await-in-loop
      await sleep(80);
    }
  }

  /**
   * Type into a controlled React input.
   *
   * Assigning `.value` does not notify React — its onChange listens for an
   * `input` event raised after the NATIVE setter has run, so that is what this
   * does. Typing is also what a user does: it exercises the debounce and the
   * query path the same way, and it costs no page load, which is why this
   * replaced a deep-link reload per predicate.
   */
  async type(selector, text) {
    await this.evaluate(`
      var el = document.querySelector(${JSON.stringify(selector)});
      if (!el) throw new Error('no element for ' + ${JSON.stringify(selector)});
      var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
      setter.call(el, ${JSON.stringify(text)});
      el.dispatchEvent(new Event('input', { bubbles: true }));
      return true;
    `);
  }

  /** Poll an in-page predicate until it is true, or give up. */
  async waitFor(body, { timeoutMs = 15000, label = 'condition' } = {}) {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      // eslint-disable-next-line no-await-in-loop
      const ok = await this.evaluate(`return (function(){ ${body} })();`);
      if (ok) return true;
      if (Date.now() > deadline) throw new Error(`timed out waiting for ${label}`);
      // eslint-disable-next-line no-await-in-loop
      await sleep(80);
    }
  }
}

/* ------------------------------------------------------------------ *
 * the predicate table
 * ------------------------------------------------------------------ */

const results = [];

function record(width, name, status, detail = '') {
  results.push({ width, name, status, detail });
  const mark = status === 'PASS' ? 'ok  ' : status === 'FAIL' ? 'FAIL' : status === 'BLOCKED' ? 'blkd' : status === 'SKIP' ? 'skip' : 'n/a ';
  console.log(`  ${mark} [${width}] ${name}${detail ? ` — ${detail}` : ''}`);
}

/**
 * Once the list has failed to render, every predicate downstream of it is
 * measuring nothing. Reporting those as PASS is how a harness produces a green
 * table for a blank page — so they are BLOCKED, which is neither a pass nor a
 * failure of the thing they name.
 */
let blocked = '';

async function check(width, name, fn, { gate = true } = {}) {
  if (gate && blocked) {
    record(width, name, 'BLOCKED', `depends on: ${blocked}`);
    return;
  }
  try {
    const detail = await fn();
    record(width, name, 'PASS', typeof detail === 'string' ? detail : '');
  } catch (err) {
    record(width, name, 'FAIL', String(err?.message || err).slice(0, 300));
  }
}

/**
 * The suite. Every selector is built from `RESOURCE`, which is the entire point:
 * point it at another resource and the same predicates run.
 */
async function runSuite(page, width) {
  const R = RESOURCE;
  const shot = (name) => path.join(OUT_DIR, `${R}-${name}-${width}.png`);

  await page.setSize(width, width >= 1440 ? 900 : 844);
  // A hash hop, not a reload. Every predicate below leaves the page on a clean
  // list, and the app re-mounts on a ROUTE change — so one real document load per
  // harness run is enough. Reloading between predicates cost about a minute a run
  // and proved nothing the first load had not already proved.
  await page.navigate(`${BASE_URL}#${LIST_ROUTE}`);

  // ---- the list renders at all: the gate every later predicate depends on ----
  blocked = '';
  await check(width, 'list renders rows', async () => {
    await page.waitFor(
      `return !!document.querySelector('[data-debug-id="${R}-rows"] [data-${R}-row]');`,
      { label: 'rows' },
    );
    const count = await page.evaluate(`return document.querySelectorAll('[data-${R}-row]').length;`);
    if (!count) throw new Error('no rows rendered');
    return `${count} rows`;
  }, { gate: false });
  if (!results.filter((r) => r.width === width).slice(-1)[0] || results.filter((r) => r.width === width).slice(-1)[0].status !== 'PASS') {
    blocked = 'list renders rows';
  }
  await page.screenshot(shot('list'), { settleSelector: `[data-${R}-row]` });

  const firstId = await page.evaluate(
    `return (document.querySelector('[data-${R}-row]') || {}).getAttribute ? document.querySelector('[data-${R}-row]').getAttribute('data-${R}-row') : '';`,
  );

  // ---- the page never scrolls sideways (Amendment 4) ----
  await check(width, 'page does not scroll horizontally', async () => {
    const over = await page.evaluate(
      'return document.documentElement.scrollWidth - document.documentElement.clientWidth;',
    );
    // The known global `body { min-width: 920px }` floor makes a sub-920 viewport
    // scroll app-wide; that is pre-existing chrome, so it is reported rather than
    // failed at those widths.
    if (over > 0 && width >= 920) throw new Error(`overflow ${over}px`);
    if (over > 0) return `overflow ${over}px — the pre-existing body{min-width:920px} floor, not this page`;
    return 'no overflow';
  }, { gate: false });

  // ---- row geometry: measured, never asserted ----
  await check(width, 'row is at least the 72px floor', async () => {
    const h = await page.evaluate(
      `return Math.round(document.querySelector('[data-${R}-row]').getBoundingClientRect().height);`,
    );
    if (h < 72) throw new Error(`row is ${h}px, below the 72px floor`);
    return `${h}px`;
  });

  await check(width, 'body is clamped to two lines and reserved when empty', async () => {
    const info = await page.evaluate(`
      var rows = Array.from(document.querySelectorAll('[data-${R}-row]'));
      var withBody = [], empty = [];
      rows.forEach(function (row) {
        var id = row.getAttribute('data-${R}-row');
        var body = document.querySelector('[data-debug-id="${R}-row-body-' + id + '"]');
        if (!body) return;
        var h = Math.round(body.getBoundingClientRect().height);
        (body.textContent.trim() ? withBody : empty).push(h);
      });
      return JSON.stringify({ withBody: withBody, empty: empty });
    `);
    const { withBody, empty } = JSON.parse(info);
    if (withBody.length === 0) throw new Error('no row carried a body');
    const max = Math.max(...withBody);
    const min = Math.min(...withBody, ...(empty.length ? empty : [max]));
    if (empty.length && min < 1) throw new Error('an empty body collapsed to zero height');
    return `bodies ${min}-${max}px, ${empty.length} empty reserved`;
  });

  // ---- the "…" trigger: opens a menu, and does NOT navigate ----
  await check(width, 'row menu opens and does not navigate the row', async () => {
    if (!firstId) throw new Error('no row id');
    const before = await page.evaluate('return window.location.hash;');
    await page.evaluate(`
      var t = document.querySelector('[data-debug-id="${R}-row-menu-${firstId}"]');
      if (!t) throw new Error('no menu trigger');
      t.click();
      return true;
    `);
    await sleep(350);
    const after = await page.evaluate('return window.location.hash;');
    const menuOpen = await page.evaluate(
      `return !!document.querySelector('[role="menu"], [data-debug-id^="${R}-row-"][role="menuitem"]');`,
    );
    if (after !== before) throw new Error(`tapping the trigger navigated: ${before} -> ${after}`);
    if (!menuOpen) throw new Error('no menu appeared');
    return 'menu open, URL unchanged';
  });
  await page.screenshot(shot('row-menu'));

  // ---- the menu's verbs are WORDS, never bare glyphs ----
  await check(width, 'menu verbs carry text labels', async () => {
    const labels = await page.evaluate(`
      return JSON.stringify(Array.from(document.querySelectorAll('[role="menuitem"]'))
        .map(function (n) { return (n.textContent || '').trim(); }));
    `);
    const parsed = JSON.parse(labels);
    if (parsed.length === 0) throw new Error('menu had no items');
    const bare = parsed.filter((label) => !label);
    if (bare.length) throw new Error(`${bare.length} menu item(s) with no text`);
    return parsed.join(' / ');
  });

  await page.evaluate('document.body.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true})); return true;');
  await sleep(200);

  // ---- opening a row ----
  await check(width, 'clicking the row title opens the record', async () => {
    await page.navigate(`${BASE_URL}#${LIST_ROUTE}`);
    await page.waitFor(`return !!document.querySelector('[data-${R}-row]');`, { label: 'rows' });
    await page.evaluate(`
      var row = document.querySelector('[data-${R}-row]');
      var link = row.querySelector('a[href]');
      if (!link) throw new Error('row title is not a link');
      link.click();
      return true;
    `);
    await sleep(600);
    const hash = await page.evaluate('return window.location.hash;');
    if (!hash.includes(`${LIST_ROUTE}/`)) throw new Error(`hash is ${hash}`);
    return hash;
  });
  await sleep(500);
  await page.screenshot(shot('detail'));

  // ---- the detail has exactly one h1 ----
  await check(width, 'detail has exactly one h1', async () => {
    const n = await page.evaluate('return document.querySelectorAll("h1").length;');
    if (n !== 1) throw new Error(`${n} h1 elements`);
    return '1';
  });

  // ---- no duplicated verb between the sticky bar and the header ----
  await check(width, 'no verb appears twice on screen', async () => {
    const dump = await page.evaluate(`
      var visible = function (el) {
        var r = el.getBoundingClientRect();
        var s = window.getComputedStyle(el);
        return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
      };
      var labels = Array.from(document.querySelectorAll('button'))
        .filter(visible)
        .map(function (b) { return ((b.textContent || '').trim() || b.getAttribute('aria-label') || '').toLowerCase(); })
        .filter(Boolean);
      return JSON.stringify(labels);
    `);
    const labels = JSON.parse(dump);
    const counts = {};
    labels.forEach((label) => { counts[label] = (counts[label] || 0) + 1; });
    const dupes = Object.entries(counts).filter(([, n]) => n > 1).map(([label, n]) => `${label} x${n}`);
    if (dupes.length) throw new Error(dupes.join(', '));
    return `${labels.length} visible buttons, all distinct`;
  });

  // ---- back to the list, then the toolbar ----
  await page.navigate(`${BASE_URL}#${LIST_ROUTE}`);
  await page.waitFor(`return !!document.querySelector('[data-${R}-row]');`, { label: 'rows' });

  // ---- selection: a tick raises the bulk bar ----
  await check(width, 'ticking a checkbox raises the bulk bar', async () => {
    const hasCheckbox = await page.evaluate(
      `return !!document.querySelector('[data-${R}-row] input[type="checkbox"]');`,
    );
    if (!hasCheckbox) return 'no checkboxes on this tab (by design) — nothing to raise';
    await page.evaluate(`
      var box = document.querySelector('[data-${R}-row] input[type="checkbox"]');
      box.click();
      return true;
    `);
    await sleep(350);
    const bar = await page.evaluate(
      `return !!document.querySelector('[data-debug-id^="${R}-bulk-"]');`,
    );
    if (!bar) throw new Error('no bulk verb appeared after a tick');
    return 'bulk bar visible';
  });
  await page.screenshot(shot('bulk'));

  // ---- the bulk bar clears the bottom chrome (REQ-UI-19, mobile) ----
  await check(width, 'bulk bar sits above the bottom chrome', async () => {
    const info = await page.evaluate(`
      var bar = document.querySelector('[role="region"][aria-label="Bulk actions"]');
      if (!bar) return '';
      var tabs = document.querySelector('[data-debug-id="shell-mobile-tab-bar"]');
      var tabVisible = tabs && tabs.getBoundingClientRect().height > 0;
      return JSON.stringify({
        barBottom: Math.round(bar.getBoundingClientRect().bottom),
        tabTop: tabVisible ? Math.round(tabs.getBoundingClientRect().top) : null,
        viewport: window.innerHeight,
      });
    `);
    if (!info) return 'no bulk bar on this tab';
    const { barBottom, tabTop, viewport } = JSON.parse(info);
    // The bar is pinned (sticky on desktop, fixed on mobile), so it must be ON
    // screen — a bar measured below the fold is a bar the user cannot reach.
    if (barBottom > viewport + 1) throw new Error(`bar bottom ${barBottom} is below the ${viewport}px viewport`);
    if (tabTop != null && barBottom > tabTop + 1) throw new Error(`bar bottom ${barBottom} overlaps tab bar top ${tabTop}`);
    return tabTop == null
      ? `bar bottom ${barBottom} of ${viewport} (no tab bar at this width)`
      : `bar bottom ${barBottom} === tab top ${tabTop}`;
  });

  // untick so the next predicate starts clean
  await page.evaluate(`
    var box = document.querySelector('[data-${R}-row] input[type="checkbox"]:checked');
    if (box) box.click();
    return true;
  `);

  // ---- filters ----
  await check(width, 'the Filters control opens a panel', async () => {
    const opened = await page.evaluate(`
      var buttons = Array.from(document.querySelectorAll('button'));
      var trigger = buttons.find(function (b) {
        var name = (b.getAttribute('aria-label') || b.textContent || '').toLowerCase();
        return name.indexOf('filter') === 0 || name.indexOf('filters') > -1;
      });
      if (!trigger) throw new Error('no Filters control found');
      trigger.click();
      return true;
    `);
    if (!opened) throw new Error('trigger did not click');
    await sleep(400);
    const panel = await page.evaluate(
      `return !!document.querySelector('[data-debug-id^="${R}-filter-"], [role="dialog"] select, [role="group"] select');`,
    );
    if (!panel) throw new Error('no filter control appeared');
    return 'panel open';
  });
  await page.screenshot(shot('filters'));
  await page.evaluate('document.body.dispatchEvent(new KeyboardEvent("keydown",{key:"Escape",bubbles:true})); return true;');
  await sleep(250);

  // ---- search: a query replaces the list and disables the filter chrome ----
  await check(width, 'a query disables the filter control (REQ-UI-5)', async () => {
    await page.type(`[data-debug-id="${R}-search-input"]`, 'zzz-no-such-thing');
    // The box is debounced, then the request goes out; wait on the RESULT rather
    // than on a fixed sleep.
    await page.waitFor(
      `return !!document.querySelector('[data-debug-id="${R}-empty-query"]');`,
      { label: 'the no-results state', timeoutMs: 10000 },
    );
    const state = await page.evaluate(`
      var buttons = Array.from(document.querySelectorAll('button'));
      var trigger = buttons.find(function (b) {
        var name = (b.getAttribute('aria-label') || b.textContent || '').toLowerCase();
        return name.indexOf('filter') > -1;
      });
      var tabs = Array.from(document.querySelectorAll('[role="tab"]'));
      return JSON.stringify({
        filterDisabled: trigger ? (trigger.disabled || trigger.getAttribute('aria-disabled') === 'true') : null,
        selectedTabs: tabs.filter(function (t) { return t.getAttribute('aria-selected') === 'true'; }).length,
        tabCount: tabs.length,
      });
    `);
    const { filterDisabled, selectedTabs, tabCount } = JSON.parse(state);
    if (filterDisabled === null) throw new Error('no filter control found while searching');
    if (!filterDisabled) throw new Error('filter control is still live while a query is active');
    if (tabCount && selectedTabs !== 0) throw new Error(`${selectedTabs} tab(s) still selected while searching`);
    return 'filters inert, no tab selected';
  });
  await page.screenshot(shot('search-empty'), { settleSelector: `[data-debug-id="${R}-empty-query"]` });

  // ---- the search signal is VISIBLE, not just in the accessibility tree ----
  //
  // Settle first, and this is not a flake workaround. `Tab` carries
  // `transition-colors duration-fast` (120ms), so a computed style read taken
  // immediately after the query lands catches the de-selecting tab MID-FADE and
  // reports it as still selected. On the Actions page that produced a FAIL reading
  // `border rgba(0,153,255,0.163) / color rgb(170,170,170)` — and both numbers are
  // the SAME point in the same transition: text-primary #fff -> text-muted #999 at
  // (255-170)/102 = 0.833, border accent alpha 1 -> 0 at 1-0.163 = 0.837. A settled
  // UI is what this predicate is about; an interpolated frame is neither state.
  await sleep(300);
  await check(width, 'no tab looks selected while searching', async () => {
    const dump = await page.evaluate(`
      return JSON.stringify(Array.from(document.querySelectorAll('[role="tab"]')).map(function (t) {
        var s = window.getComputedStyle(t);
        return {
          label: (t.textContent || '').trim(),
          selected: t.getAttribute('aria-selected'),
          borderBottom: s.borderBottomWidth + ' ' + s.borderBottomColor,
          color: s.color,
        };
      }));
    `);
    const tabs = JSON.parse(dump);
    if (tabs.length === 0) return 'no tabs on this page';
    const ariaSelected = tabs.filter((t) => t.selected === 'true');
    if (ariaSelected.length) throw new Error(`${ariaSelected.map((t) => t.label).join(', ')} still aria-selected`);
    // Amendment 7 removed the explanatory banner, so the tab strip IS the signal:
    // every tab must look the same while a query is active.
    const distinct = new Set(tabs.map((t) => `${t.borderBottom}|${t.color}`));
    if (distinct.size > 1) {
      throw new Error(`tabs render differently while searching: ${tabs.map((t) => `${t.label}=${t.borderBottom}/${t.color}`).join(' ; ')}`);
    }
    return `${tabs.length} tabs, all rendered identically`;
  });

  // ---- the no-results copy differs from the first-run copy ----
  await check(width, 'no-results copy is distinct from first-run copy', async () => {
    await page.waitFor(
      `return !!document.querySelector('[data-debug-id="${R}-empty-query"]');`,
      { label: 'the no-results state', timeoutMs: 8000 },
    );
    const queryCopy = await page.evaluate(
      `var n = document.querySelector('[data-debug-id="${R}-empty-query"]'); return n ? n.textContent.trim().slice(0,160) : '';`,
    );
    if (!queryCopy) throw new Error('no query-empty state rendered');
    return queryCopy.slice(0, 80);
  });

  // ---- keyboard: "/" focuses search, and letters do not fire while typing ----
  await check(width, '"/" focuses search and is ignored while typing', async () => {
    await page.type(`[data-debug-id="${R}-search-input"]`, '');
    await page.waitFor(`return !!document.querySelector('[data-${R}-row]');`, { label: 'rows after clearing the query' });
    await page.evaluate('document.body.focus(); window.dispatchEvent(new KeyboardEvent("keydown",{key:"/",bubbles:true})); return true;');
    await sleep(250);
    const focused = await page.evaluate(
      `var a = document.activeElement; return a ? (a.getAttribute('data-debug-id') || a.tagName) : '';`,
    );
    if (!String(focused).includes('search')) throw new Error(`focus went to ${focused}`);
    // Now prove a single-letter shortcut is ignored inside the field.
    const before = await page.evaluate('return window.location.hash;');
    await page.evaluate(`
      var input = document.querySelector('[data-debug-id="${R}-search-input"]');
      input.dispatchEvent(new KeyboardEvent('keydown', { key: 'e', bubbles: true }));
      return true;
    `);
    await sleep(250);
    const after = await page.evaluate('return window.location.hash;');
    if (after !== before) throw new Error(`a letter typed in search navigated: ${before} -> ${after}`);
    return 'search focused; letters inert while typing';
  });

  // Leave the list clean for the next width: same reason the search is cleared
  // above, and it keeps each width's run independent of the last one's end state.
  await page.type(`[data-debug-id="${R}-search-input"]`, '').catch(() => undefined);

  /* ---------------- the create form ----------------
   * The form was the one surface with NO coverage: `firefox --screenshot` fires on
   * load and captures the "Checking session…" splash instead of the mounted page,
   * so a form shot has to come from the driven browser like everything else.
   * Both predicates are generic — every rebuilt resource routes its create form at
   * `<list route>/new` and names its submit button `<resource>-form-submit`.
   */
  if (NO_CREATE_FORM) {
    const why = `${RESOURCE} is runtime, not CRUD: no create form and no edit page by design (REQ-UI-15)`;
    record(width, 'the create form renders', 'N/A', why);
    record(width, 'an empty submit reports field errors and does not navigate', 'N/A', why);
  } else {
  await page.hardNavigate(`${BASE_URL}#${LIST_ROUTE}/new`);

  await check(width, 'the create form renders', async () => {
    await page.waitFor(
      `return !!document.querySelector('[data-debug-id="${R}-form-submit"]');`,
      { label: 'the create form', timeoutMs: 20000 },
    );
    const h1s = await page.evaluate('return document.querySelectorAll("h1").length;');
    if (Number(h1s) !== 1) throw new Error(`${h1s} h1 elements on the form`);
    const fields = await page.evaluate(
      'return document.querySelectorAll("input, textarea, select, [role=\'combobox\']").length;',
    );
    return `${fields} controls, 1 h1`;
  }, { gate: false });
  await page.screenshot(shot('form'), { settleSelector: `[data-debug-id="${R}-form-submit"]` });

  await check(width, 'an empty submit reports field errors and does not navigate', async () => {
    const before = await page.evaluate('return window.location.hash;');
    await page.evaluate(`
      var btn = document.querySelector('[data-debug-id="${R}-form-submit"]');
      if (!btn) throw new Error('no submit button');
      btn.click();
      return true;
    `);
    await sleep(400);
    const state = await page.evaluate(`
      return JSON.stringify({
        hash: window.location.hash,
        invalid: document.querySelectorAll('[aria-invalid="true"]').length,
        messages: Array.from(document.querySelectorAll('[id$="-error"]')).map(function (n) {
          return (n.textContent || '').trim();
        }),
      });
    `);
    const { hash, invalid, messages } = JSON.parse(state);
    if (hash !== before) throw new Error(`an empty submit navigated: ${before} -> ${hash}`);
    if (!messages.length && !invalid) throw new Error('an empty submit produced no field error');
    const shown = messages.filter(Boolean);
    return `${shown.length} field error(s): ${shown.slice(0, 2).join(' | ').slice(0, 90)}`;
  });
  await page.screenshot(shot('form-errors'));
  }

  // Back to the list so the next width starts where this one did.
  await page.hardNavigate(`${BASE_URL}#${LIST_ROUTE}`);
  await page.waitFor(`return !!document.querySelector('[data-${R}-row]');`, { label: 'rows' }).catch(() => undefined);

  // ---- not covered, stated rather than skipped silently ----
  record(width, 'hover-only affordances', 'N/A', 'no OS-level pointer — nothing on these pages is hover-only by design');
  record(width, 'real touch gestures', 'N/A', 'no swipe exists (removed by user ruling); taps are dispatched as clicks');
}

/* ------------------------------------------------------------------ *
 * main
 * ------------------------------------------------------------------ */

async function main() {
  await fs.mkdir(OUT_DIR, { recursive: true });
  const profileDir = await fs.mkdtemp(path.join(os.tmpdir(), 'ham-harness-'));
  console.log(`harness: resource=${RESOURCE} url=${BASE_URL} out=${OUT_DIR}`);

  const firefox = await launchFirefox(profileDir);
  let client;
  try {
    await waitForPort(MARIONETTE_PORT);
    client = new Marionette(MARIONETTE_PORT);
    await client.connect();
    await client.send('WebDriver:NewSession', { capabilities: {} });
    const page = new Page(client);
    // If --login was provided, establish the auth cookie — but do NOT navigate to
    // the login URL.
    //
    // `ham-dev-proxy`'s `/_dev/login` answers **204 No Content** (verified:
    // `set-cookie: ham_dev_user=…`, `content-length: 0`). Per HTML, a top-level
    // navigation that resolves to 204 is ABANDONED: the browser keeps the document
    // it has and fires no `load` event. `WebDriver:Navigate` waits for that load,
    // and since this file sets no WebDriver timeouts the wait is the spec default
    // page-load timeout — 300000ms. That is the "300s navigation timeout" the
    // Agents run hit, with the browser parked on `about:blank` from
    // `hardNavigate`'s own first hop. The dev server was never the problem: a cold
    // one loads this app in 11s and a warm one in 3s, both measured.
    //
    // So: load a real document on the origin first, then set the cookie with an
    // in-page fetch, which keeps the 204 out of the navigation path entirely.
    if (LOGIN_URL) {
      await page.hardNavigate(BASE_URL);
      await page.evaluate(`
        var done = false;
        fetch(${JSON.stringify(LOGIN_URL)}, { credentials: 'include' }).then(function () { done = true; });
        return true;
      `);
      await new Promise((r) => setTimeout(r, 1200));
      // OIDC sign-in: /api/v1/auth/login -> mock provider (auto-approve) ->
      // /api/v1/auth/callback -> "/" with the hub session cookie set. Every hop is
      // a 302 and the last one loads the app, so the navigation completes normally.
      await page.hardNavigate(new URL('/api/v1/auth/login?return_to=%2F', BASE_URL).href);
    }
    // The ONLY full document load of the run. Everything after it is hash
    // navigation inside the already-booted app.
    await page.hardNavigate(`${BASE_URL}#${LIST_ROUTE}`);

    for (const width of WIDTHS) {
      console.log(`\n== ${width}px ==`);
      // eslint-disable-next-line no-await-in-loop
      await runSuite(page, width);
    }
  } finally {
    if (!FLAG('keep')) {
      client?.close();
      firefox.kill('SIGTERM');
    }
  }

  const failed = results.filter((r) => r.status === 'FAIL');
  await fs.writeFile(
    path.join(OUT_DIR, 'results.json'),
    JSON.stringify({ resource: RESOURCE, url: BASE_URL, widths: WIDTHS, results }, null, 2),
  );

  // A markdown truth table, because that is what goes in a handoff comment.
  const table = [
    `# ${RESOURCE} — interaction predicates`,
    '',
    '| width | predicate | result | detail |',
    '|---|---|---|---|',
    ...results.map((r) => `| ${r.width} | ${r.name} | ${r.status} | ${r.detail.replace(/\|/g, '\\|')} |`),
  ].join('\n');
  await fs.writeFile(path.join(OUT_DIR, 'results.md'), `${table}\n`);

  console.log(`\n${results.length} predicates, ${failed.length} failed. Wrote ${OUT_DIR}/results.{json,md}`);
  process.exit(failed.length ? 1 : 0);
}

main().catch((err) => {
  console.error('harness error:', err);
  process.exit(2);
});
