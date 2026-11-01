// Real React/Settings UI; fixture APIs and Electron manager are entirely in memory.
// PLAYWRIGHT_MODULE=/path/to/playwright node tests/e2e/bridges_layout_browser_check.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { createServer } from 'vite';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = fileURLToPath(new URL('../../', import.meta.url));
const evidence = process.env.BRIDGES_LAYOUT_EVIDENCE || '/tmp/bridges-layout-evidence';
await fs.mkdir(evidence, { recursive: true });
const server = await createServer({ root, server: { host: '127.0.0.1', port: 0 } });
await server.listen();
const origin = 'http://127.0.0.1:' + server.httpServer.address().port;
const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
const failures = [];
const results = [];
try {
  for (const width of (process.env.BRIDGES_WIDTHS || '1440,1024,768,390,320').split(',').map(Number)) {
    for (const scenario of ['browser', 'installed', 'absent', 'unknown', 'error']) {
      const page = await browser.newPage({ viewport: { width, height: 1050 } });
      page.setDefaultTimeout(10000);
      page.on('pageerror', (e) => failures.push({ width, scenario, error: e.message }));
      await page.route('**/*', (route) => route.request().url().startsWith(origin + '/') ? route.continue() : route.abort());
      const q = (id) => page.locator('[data-debug-id="' + id + '"]:visible');
      await page.goto(origin + '/tests/fixtures/bridges-layout.html?scenario=' + scenario + '#/settings/bridges');
      await q('settings-bridge-card-brg_local').waitFor();
      if (scenario !== 'browser') await page.waitForFunction(() => !document.querySelector('[data-debug-id="settings-this-machine-status"]')?.textContent.includes('Checking'));
      if (process.env.BRIDGES_FONT_DIR) {
        const files = [['Source Serif 4', 'source-serif-4.ttf'], ['IBM Plex Sans', 'ibm-plex-sans.ttf'], ['IBM Plex Mono', 'ibm-plex-mono.ttf']];
        const faces = await Promise.all(files.map(async ([family, file]) => '@font-face { font-family: "' + family + '"; src: url(data:font/ttf;base64,' + (await fs.readFile(path.join(process.env.BRIDGES_FONT_DIR, file))).toString('base64') + ') format("truetype"); font-weight:100 900; }'));
        await page.addStyleTag({ content: faces.join('\n') });
        await page.evaluate(async () => Promise.all(['Source Serif 4', 'IBM Plex Sans', 'IBM Plex Mono'].map((f) => document.fonts.load('14px "' + f + '"'))));
      }
      const check = async (state) => {
        // Navigation may collapse a tall flow while the modal body is scrolled.
        // Capture each state from the top rather than measuring clipped controls.
        await page.evaluate(() => {
          for (const element of document.querySelectorAll('*')) {
            if (element.scrollTop) element.scrollTop = 0;
          }
        });
        const m = await page.evaluate(() => {
          const visible = (el) => el.getBoundingClientRect().width > 0 && el.getBoundingClientRect().height > 0;
          const containers = [...document.querySelectorAll('[data-debug-id="settings-desktop-content"], [data-debug-id="settings-bridges-panel"], [data-debug-id="settings-this-machine-card"], [data-debug-id="settings-local-bridge-flow"]')].filter(visible);
          const dialogs = [...document.querySelectorAll('[aria-modal="true"]')].filter(visible);
          const activeLayer = dialogs.at(-1) || document;
          const buttons = [...activeLayer.querySelectorAll('button')].filter(visible).map((e) => ({ id: e.getAttribute('data-debug-id') || e.textContent, r: e.getBoundingClientRect() }));
          const overlaps = [];
          for (let i = 0; i < buttons.length; i++) for (let j = i + 1; j < buttons.length; j++) {
            const a = buttons[i], b = buttons[j];
            if (Math.min(a.r.right, b.r.right) - Math.max(a.r.left, b.r.left) > 2 && Math.min(a.r.bottom, b.r.bottom) - Math.max(a.r.top, b.r.top) > 2) overlaps.push([a.id, b.id]);
          }
          return { width: innerWidth, document: document.documentElement.scrollWidth, overflow: containers.filter((e) => e.scrollWidth > e.clientWidth + 1).map((e) => e.getAttribute('data-debug-id')), overlaps };
        });
        await page.screenshot({ path: path.join(evidence, width + '-' + scenario + '-' + state + '.png'), fullPage: true });
        assert.ok(m.document <= width, JSON.stringify({ state, ...m }));
        assert.deepEqual(m.overflow, [], state);
        assert.deepEqual(m.overlaps, [], state);
        results.push({ width, scenario, state, ...m });
      };
      assert.equal(await page.locator('h1:visible').count(), 1, 'one Settings heading');
      assert.equal(await q('settings-bridge-local-badge').count(), scenario === 'installed' ? 1 : 0);
      if (scenario === 'browser') assert.equal(await q('settings-this-machine-card').count(), 0);
      if (['unknown', 'error'].includes(scenario)) {
        assert.equal(await q('settings-this-machine-setup-btn').count(), 0, 'unknown is never absence');
        assert.equal(await q('settings-this-machine-update-btn').count(), 0);
      }
      await check('overview');
      if (scenario === 'browser') {
        const toggle = q('settings-global-telemetry-toggle');
        await toggle.focus(); await page.keyboard.press('Space');
        await page.waitForFunction(() => localStorage.getItem('heimdall:preference:telemetry.default_enabled') === 'false'
          && document.querySelector('[data-debug-id="settings-global-telemetry-toggle"]')?.getAttribute('aria-checked') === 'false');
        assert.equal(await toggle.getAttribute('aria-checked'), 'false');
        for (const id of ['brg_remote', 'brg_offline']) {
          await q('settings-bridge-card-' + id).focus(); await page.keyboard.press('Enter');
          await q('settings-bridge-row-' + id).waitFor();
          assert.equal(await page.locator('h1:visible').count(), 1);
          assert.equal(await page.evaluate(() => document.activeElement.tagName), 'H1', 'detail heading receives keyboard focus');
          assert.equal(await page.getByLabel('Default provider', { exact: true }).isDisabled(), true);
          assert.equal(await page.getByLabel('Default model', { exact: true }).isDisabled(), true);
          assert.equal(await q('settings-bridge-update-btn-' + id).isDisabled(), id === 'brg_offline');
          await check(id + '-detail');
          if (id === 'brg_remote') {
            await q('settings-bridge-update-btn-' + id).click();
            await q('settings-bridge-update-modal').waitFor();
            await check('remote-update-review');
            await q('settings-bridge-update-force-option').check();
            await q('settings-bridge-update-extensions').uncheck();
            await q('settings-bridge-update-confirm').click();
            await q('settings-bridge-update-modal').waitFor({ state: 'hidden' });
            const request = await page.evaluate(() => window.bridgesFixture.requests.find((r) => r.url.endsWith('/brg_remote/update')));
            assert.deepEqual(request.body, { target_version: '0.3.32', force: true, update_extensions: false, drain_timeout_seconds: 60 });
            assert.deepEqual(await page.evaluate(() => window.bridgesFixture.runs), []);
          }
          await q('settings-bridges-back').click();
        }
      }
      if (scenario === 'installed') {
        await q('settings-this-machine-update-btn').click();
        assert.deepEqual(await page.evaluate(() => window.bridgesFixture.runs[0]), { kind: 'update', target: { hub: origin, profile: 'personal' }, options: { inAppApproval: true } });
        await page.evaluate(() => window.bridgesFixture.emit({ type: 'output', message: 'Downloading verified release' }));
        await check('local-updating');
        await page.evaluate(() => window.bridgesFixture.emit({ type: 'error', step: 'download', message: 'Download failed', rolledBack: true }));
        await q('settings-bridge-wizard-retry').click();
        assert.deepEqual(await page.evaluate(() => window.bridgesFixture.runs[1]), await page.evaluate(() => window.bridgesFixture.runs[0]));
      }
      if (scenario === 'absent') {
        await q('settings-this-machine-setup-btn').click();
        await q('setup-install-btn').waitFor();
        await check('shared-install');
        await q('setup-install-btn').click();
        await page.evaluate(() => window.bridgesFixture.emit({ type: 'progress', step: 'download', state: 'ok', message: 'Downloaded' }));
        await check('shared-install-progress');
        const firstRun = await page.evaluate(() => window.bridgesFixture.runs[0]);
        await q('settings-local-flow-close').click();
        await q('settings-this-machine-resume-btn').waitFor();
        assert.equal(await q('settings-this-machine-resume-btn').isEnabled(), true);
        await check('setup-collapsed');
        await q('settings-this-machine-resume-btn').click();
        await q('setup-install-progress').waitFor();
        await q('setup-install-cancel-btn').waitFor();
        assert.deepEqual(await page.evaluate(() => window.bridgesFixture.runs), [firstRun]);
        await check('setup-resumed');
        await page.evaluate(() => window.bridgesFixture.host('wizard'));
        await page.locator('[data-debug-id="setup-install-progress"]').waitFor();
        assert.equal(await page.locator('[data-debug-id="setup-selected-profile"]').textContent(), 'Profile: Default (unnamed)');
        assert.equal(await page.evaluate(() => window.bridgesFixture.runs.length), 1, 'host switch resumes without starting another operation');
        await page.evaluate(() => window.bridgesFixture.host('settings'));
        await q('setup-install-progress').waitFor();
        await page.evaluate(() => window.bridgesFixture.emit({ type: 'pairing', code: 'ABCD-EFGH-JKLM-NP' }));
        if (await q('setup-install-identity-btn').count()) await q('setup-install-identity-btn').click();
        await q('setup-identity-waiting').waitFor();
        await page.waitForFunction(() => window.bridgesFixture.requests.some((r) => r.url.endsWith('/device/pair-salts')));
        const pendingRequests = await page.evaluate(() => window.bridgesFixture.requests.filter((r) => r.url.endsWith('/device/pair-salts')).length);
        await q('settings-local-flow-close').click();
        await q('settings-this-machine-resume-btn').click();
        await q('setup-identity-waiting').waitFor();
        assert.equal(await page.evaluate(() => window.bridgesFixture.requests.filter((r) => r.url.endsWith('/device/pair-salts')).length), pendingRequests, 'pending lookup survives closing without duplication');
        await check('identity-pending-resumed');
        await page.evaluate(() => window.bridgesFixture.finishPairLookup());
        await q('setup-identity-lookup-error').waitFor();
        const identityError = await q('setup-identity-lookup-error').textContent();
        const requestsBeforeResume = await page.evaluate(() => window.bridgesFixture.requests.length);
        await q('settings-local-flow-close').click();
        await q('settings-this-machine-resume-btn').click();
        await q('setup-identity-lookup-error').waitFor();
        assert.equal(await q('setup-identity-lookup-error').textContent(), identityError, 'identity step and lookup state survive closing');
        assert.equal(await page.evaluate(() => window.bridgesFixture.requests.length), requestsBeforeResume, 'resuming identity does not restart lookup');
        assert.deepEqual(await page.evaluate(() => window.bridgesFixture.runs), [firstRun], 'identity resume keeps exact operation, target and options');
        await check('identity-resumed');
        await q('setup-identity-back-btn').click();
        await q('setup-install-cancel-btn').click();
        await q('setup-install-retry-btn').waitFor();
        await check('shared-install-cancelled');
        await q('settings-local-flow-close').click();
        await q('settings-this-machine-resume-btn').click();
        await q('setup-install-retry-btn').click();
        assert.deepEqual(await page.evaluate(() => window.bridgesFixture.runs), [firstRun, firstRun], 'cancelled setup retry retains its original target and options');
        assert.equal(await page.evaluate(() => Object.keys(localStorage).some((k) => k.includes('setup-seen'))), false);
      }
      await page.close();
    }
  }
  assert.deepEqual(failures, []);
  await fs.writeFile(path.join(evidence, 'browser.json'), JSON.stringify({ results, failures }, null, 2));
  console.log('PASS ' + results.length + ' responsive states; identity, shared-host resume, local retry/cancel, global telemetry and remote request gates');
} finally {
  await browser.close(); await server.close();
}
