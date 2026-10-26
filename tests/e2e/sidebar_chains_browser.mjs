// Real shell + CSS, synthetic read-only API. No Hub credentials or production data.
// Usage: PUPPETEER_MODULE=/path/to/puppeteer-core/lib/esm/puppeteer/puppeteer-core.js
// SIDEBAR_BROWSER=/path/to/chromium node tests/e2e/sidebar_chains_browser.mjs EVIDENCE_DIR
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { createServer } from 'vite';

const evidenceDir = path.resolve(process.argv[2] || '/home/tanmay/.cache/heimdall-tests/sidebar-browser');
await fs.mkdir(evidenceDir, { recursive: true });
assert.ok(process.env.PUPPETEER_MODULE && process.env.SIDEBAR_BROWSER, 'supply existing browser tooling');
const server = await createServer({
  configFile: path.resolve('vite.config.js'),
  cacheDir: path.join(evidenceDir, 'vite-cache'),
  plugins: [{
    name: 'sidebar-fixture-bypass-auth', enforce: 'pre',
    transform(source, id) {
      if (id.endsWith('/src/ui/components/shell/AppShell.tsx')) {
        assert.ok(source.includes('return <AuthGate />;'), 'fixture bypass targets only the auth wrapper');
        return source.replace('return <AuthGate />;',
          'return <AuthenticatedShell user={{ user_id: "sidebar-fixture", display_name: "Sidebar Reviewer" }} />;');
      }
    },
  }],
  optimizeDeps: { noDiscovery: true, include: ['react', 'react-dom/client', 'react-redux', '@reduxjs/toolkit'] },
  server: { host: '127.0.0.1', port: 0, open: false },
  logLevel: 'warn',
});
await server.listen();
const address = server.httpServer.address();
const baseUrl = `http://127.0.0.1:${address.port}/tests/fixtures/sidebar-chains/#/home`;
const { default: puppeteer } = await import(pathToFileURL(process.env.PUPPETEER_MODULE).href);
const browser = await puppeteer.launch({ executablePath: process.env.SIDEBAR_BROWSER, headless: true, timeout: 30000, browser: process.env.SIDEBAR_BROWSER_KIND || 'chrome',
  args: ['--no-sandbox', '--disable-dev-shm-usage'] });
const errors = [], scenarios = [];
let total = 63;
const data = () => Array.from({ length: total }, (_, i) => ({
  chain_id: `sidebar-${String(i).padStart(3, '0')}`, title: `Task chain ${i} with a long title that must truncate`,
  status: i === 61 ? 'completed' : 'active', project_id: ['p1', 'p2', ''][i % 3],
  project_name: ['Alpha', 'Beta', ''][i % 3], coordinator_agent_instance_id: `coord-${i}`,
  updated_at: new Date(Date.UTC(2026, 9, 26) - i * 60000).toISOString(),
}));
async function scenario(width, height, { fill = false } = {}) {
  const page = await browser.newPage();
  const requests = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.setViewport({ width, height });
  await page.setRequestInterception(true);
  page.on('request', async request => {
    const url = new URL(request.url());
    if (!url.pathname.startsWith('/api/')) return request.continue();
    requests.push(url.pathname + url.search);
    let body = { data: [] };
    if (url.pathname.endsWith('/task-chains') && url.searchParams.get('flat') === '1') {
      const start = Number(url.searchParams.get('cursor') || 0), limit = 20;
      const rows = data().slice(start, start + limit);
      body = { data: rows, page: { limit, next_cursor: start + limit < total ? String(start + limit) : null, has_more: start + limit < total } };
    } else if (url.pathname.endsWith('/attention/summary')) body = { data: { counts: { total: 0 } } };
    else if (url.pathname.includes('/experimental')) body = { data: { actions: false } };
    else if (url.pathname.endsWith('/task-chains')) body = { data: [{
      project_id: 'quiet-project', project_name: 'Quiet project', chains: [{
        chain_id: 'quiet-chain', title: 'Previously reachable quiet title', status: 'active',
        project_id: 'quiet-project', updated_at: '2025-01-01T00:00:00Z', coordinator_agent_instance_id: 'quiet-coordinator',
      }], has_more: false, next_cursor: '', chain_total: 1,
    }] };
    await request.respond({ status: 200, contentType: 'application/json', body: JSON.stringify(body) });
  });
  const sel = id => `[data-debug-id="${id}"]`;
  try {
    await page.goto(baseUrl);
    await page.waitForSelector(sel('sidebar-chain-row-sidebar-000'));
    if (width < 768) await page.click(sel('shell-sidebar-collapse-toggle'));
    await page.waitForSelector(sel('shell-left-sidebar-expanded'));
    // The palette must retain previews from less-active projects even before
    // the sidebar's global cursor has reached those projects.
    await page.$eval(sel('shell-sidebar-search-button'), el => el.click());
    await page.waitForSelector(sel('command-palette-input'));
    await page.type(sel('command-palette-input'), 'Previously reachable quiet title');
    await page.waitForFunction(() => document.querySelector('[data-debug-id="command-palette"]')?.textContent.includes('Previously reachable quiet title'));
    await page.keyboard.press('Escape');
    if (width < 768) await page.click(sel('shell-sidebar-collapse-toggle'));
    const first = await page.evaluate(() => {
      const rect = id => { const r = document.querySelector(`[data-debug-id="${id}"]`).getBoundingClientRect(); return { top: r.top, bottom: r.bottom, height: r.height, width: r.width }; };
      const nav = document.querySelector('[data-debug-id="shell-primary-nav"]');
      const chains = document.querySelector('[data-debug-id="sidebar-task-chains"]');
      const scroll = document.querySelector('[data-debug-id="shell-sidebar-scroll"]');
      return { cluster: rect('shell-top-left-cluster'), footer: rect('shell-sidebar-account'), nav: nav.getBoundingClientRect().top,
        sharedRoot: scroll.contains(nav) && scroll.contains(chains),
        belowIssues: document.querySelector('[data-debug-id="shell-nav-issues"]').getBoundingClientRect().bottom <= chains.getBoundingClientRect().top,
        homeList: Boolean(document.querySelector('[data-debug-id="home-chain-search"]')),
        scroll: { top: scroll.scrollTop, height: scroll.clientHeight, total: scroll.scrollHeight }, bodyWidth: document.body.scrollWidth };
    });
    assert.ok(first.sharedRoot && first.belowIssues);
    assert.equal(first.homeList, false);
    assert.ok(first.footer.bottom <= height + 1 && first.footer.height > 0, 'account stays in viewport');
    assert.ok(first.bodyWidth <= width, 'no horizontal document overflow');
    await page.screenshot({ path: path.join(evidenceDir, `${width}x${height}-initial.png`) });
    const listRequests = () => requests.filter(url => url.startsWith('/api/v1/task-chains?'));
    if (fill) {
      await page.waitForFunction(() => document.querySelectorAll('[data-debug-id^="sidebar-chain-row-"]').length > 20);
      assert.ok(listRequests().length > 1, 'initial observer fills a tall viewport without scrolling');
    }
    for (let i = 0; i < 12; i++) {
      const count = await page.$$eval('[data-debug-id^="sidebar-chain-row-"]', rows => rows.length);
      if (count === total) break;
      await page.evaluate(() => { const el = document.querySelector('[data-debug-id="shell-sidebar-scroll"]'); el.scrollTop = el.scrollHeight; });
      await new Promise(resolve => setTimeout(resolve, 180));
    }
    await page.waitForFunction(n => document.querySelectorAll('[data-debug-id^="sidebar-chain-row-"]').length === n, {}, total);
    const after = await page.evaluate(() => {
      const rect = id => { const r = document.querySelector(`[data-debug-id="${id}"]`).getBoundingClientRect(); return { top: r.top, bottom: r.bottom, height: r.height, width: r.width }; };
      return { cluster: rect('shell-top-left-cluster'), footer: rect('shell-sidebar-account'),
        nav: document.querySelector('[data-debug-id="shell-primary-nav"]').getBoundingClientRect().top,
        rows: [...document.querySelectorAll('[data-debug-id^="sidebar-chain-row-"]')].map(el => el.dataset.debugId),
        scrollTop: document.querySelector('[data-debug-id="shell-sidebar-scroll"]').scrollTop };
    });
    assert.equal(after.rows.length, new Set(after.rows).size);
    assert.deepEqual(after.cluster, first.cluster, 'branding/toggle anchored');
    assert.deepEqual(after.footer, first.footer, 'account anchored');
    assert.ok(after.nav < first.nav, 'links and chains scroll together');
    assert.deepEqual(listRequests().map(url => new URL(url, baseUrl).searchParams.get('cursor')), [null, '20', '40', '60']);
    await page.evaluate(() => { const el = document.querySelector('[data-debug-id="shell-sidebar-scroll"]'); el.scrollTop = el.scrollHeight; });
    await new Promise(resolve => setTimeout(resolve, 50));
    await page.screenshot({ path: path.join(evidenceDir, `${width}x${height}-scrolled.png`) });
    const n = listRequests().length;
    const previewRequests = () => requests.filter(url => url === '/api/v1/task-chains');
    assert.equal(previewRequests().length, 1, 'one initial preview snapshot preserves palette reach');
    await page.evaluate(() => {
      window.sidebarFixture.event({ type: 'resource_changed', resource: 'task_chain', resource_id: 'sidebar-000', change: 'updated' });
      window.dispatchEvent(new Event('focus'));
      window.dispatchEvent(new Event('online'));
      const scroll = document.querySelector('[data-debug-id="shell-sidebar-scroll"]');
      scroll.scrollTop = 0; scroll.scrollTop = scroll.scrollHeight;
    });
    await new Promise(resolve => setTimeout(resolve, 350));
    assert.equal(listRequests().length, n, 'no background refresh after task/status/focus/reconnect or exhaustion');
    assert.equal(previewRequests().length, 1, 'preview snapshot also ignores background refresh triggers');
    await page.click(sel('shell-sidebar-collapse-toggle'));
    await new Promise(resolve => setTimeout(resolve, 240));
    const hidden = await page.$eval(sel('shell-left-sidebar-hidden'), el => ({ width: el.getBoundingClientRect().width, hidden: getComputedStyle(el).visibility }));
    assert.equal(hidden.hidden, 'hidden');
    if (width >= 768) assert.equal(hidden.width, 0);
    await page.click(sel('shell-sidebar-collapse-toggle'));
    await new Promise(resolve => setTimeout(resolve, 240));
    assert.equal(listRequests().length, n, 'reopening preserves pages');
    // R2: wordmark follows effective sidebar visibility on a conversation route.
    await page.evaluate(() => { location.hash = '#/conversations/chain:sidebar-000'; });
    if (width < 768) {
      await page.waitForSelector(sel('shell-left-sidebar-hidden'));
      await page.click(sel('shell-sidebar-collapse-toggle'));
    }
    await page.waitForFunction(() => Boolean(document.querySelector('[data-debug-id="shell-brand"]')));
    await page.click(sel('shell-sidebar-collapse-toggle'));
    await page.waitForFunction(() => !document.querySelector('[data-debug-id="shell-brand"]'));
    await page.click(sel('shell-sidebar-collapse-toggle'));
    await page.waitForFunction(() => Boolean(document.querySelector('[data-debug-id="shell-brand"]')));
    if (width < 768) {
      await page.$eval(sel('sidebar-chain-row-sidebar-061'), el => el.click());
      await page.waitForSelector(sel('shell-left-sidebar-hidden'));
      assert.equal(await page.evaluate(() => location.hash), '#/conversations/chain:sidebar-061');
    }
    scenarios.push({ width, height, first, after, listRequests: listRequests(), hidden });
    console.log(`PASS ${width}x${height}: 63 unique chains, 4 pages, shared scroller, anchored chrome, collapse/R2`);
  } finally { await page.close(); }
}
try {
  await scenario(1440, 900);
  await scenario(390, 700);
  await scenario(1200, 1800, { fill: true });
  assert.deepEqual(errors, [], 'no browser errors');
  await fs.rm(path.join(evidenceDir, 'failure.json'), { force: true });
  await fs.writeFile(path.join(evidenceDir, 'evidence.json'), JSON.stringify({ status: 'pass', browser: await browser.version(), source: 'actual AuthenticatedShell and styles; synthetic API; auth/vault provisioning bypassed', scenarios, errors }, null, 2));
} catch (error) {
  await fs.writeFile(path.join(evidenceDir, 'failure.json'), JSON.stringify({ error: error.message, scenarios, errors }, null, 2));
  throw error;
} finally { await browser.close(); await server.close(); }
