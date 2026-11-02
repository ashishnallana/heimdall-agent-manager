// Run with PLAYWRIGHT_MODULE pointing to a separately installed playwright module.
// Starts an isolated Vite server; exercises real React settings against fixture APIs.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { createServer } from 'vite';

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = fileURLToPath(new URL('../../', import.meta.url));
const evidence = process.env.PROVIDER_LAYOUT_EVIDENCE || '/tmp/provider-layout-evidence';
await fs.mkdir(evidence, { recursive: true });
const server = await createServer({ root, server: { host: '127.0.0.1', port: 0, strictPort: false } });
await server.listen();
const port = server.httpServer.address().port;
const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
const failures = [];
const results = [];
try {
  for (const width of [1440, 768, 390]) {
    const page = await browser.newPage({ viewport: { width, height: 1000 } });
    page.on('pageerror', (e) => failures.push(e.message));
    // No production API/network traffic is allowed in this test.
    await page.route('**/*', (route) => route.request().url().startsWith(`http://127.0.0.1:${port}/`)
      ? route.continue() : route.abort());
    const q = (id) => page.locator(`[data-debug-id="${id}"]:visible`);
    await page.goto(`http://127.0.0.1:${port}/tests/fixtures/provider-layout.html#/settings/providers`);
    await q('providers-bridge-overview').waitFor();
    assert.equal(await page.locator('[data-debug-id="providers-panel"]').count(), 1, 'settings must mount one provider content tree');
    if (process.env.PROVIDER_FONT_DIR) {
      const fontFiles = [['Source Serif 4', 'source-serif-4.ttf'], ['IBM Plex Sans', 'ibm-plex-sans.ttf'], ['IBM Plex Mono', 'ibm-plex-mono.ttf']];
      const faces = await Promise.all(fontFiles.map(async ([family, name]) => `@font-face { font-family: "${family}"; src: url(data:font/ttf;base64,${(await fs.readFile(path.join(process.env.PROVIDER_FONT_DIR, name))).toString('base64')}) format('truetype'); font-weight: 100 900; }`));
      await page.addStyleTag({ content: faces.join('\n') });
      await page.evaluate(async () => { await Promise.all(['Source Serif 4', 'IBM Plex Sans', 'IBM Plex Mono'].map((family) => document.fonts.load(`14px "${family}"`))); });
    }
    const checkHeading = async (title, description, breadcrumb = '') => {
      const shell = q('settings-desktop-content');
      await page.waitForFunction((title) => document.querySelector('[data-debug-id="settings-desktop-content"] h1')?.textContent.trim() === title, title);
      assert.equal(await shell.locator('h1:visible').count(), 1, 'Settings owns one visible page heading');
      assert.equal(await q('providers-panel').locator('h1').count(), 0, 'provider content has no duplicate page heading');
      assert.ok((await shell.locator('h1').locator('..').textContent()).includes(description));
      if (breadcrumb) assert.ok((await shell.locator('h1').locator('..').textContent()).includes(breadcrumb));
    };
    const checkLayout = async (name) => {
      const measurement = await page.evaluate(() => {
        const containers = [...document.querySelectorAll('[data-debug-id="settings-desktop-content"], [data-debug-id="profile-editor"], [data-debug-id="providers-panel"]')]
          .filter((e) => e.getBoundingClientRect().width > 0);
        return { viewport: window.innerWidth, document: document.documentElement.scrollWidth,
          overflow: containers.filter((e) => e.scrollWidth > e.clientWidth + 1).map((e) => e.getAttribute('data-debug-id')) };
      });
      assert.ok(measurement.document <= measurement.viewport, JSON.stringify(measurement));
      assert.deepEqual(measurement.overflow, [], name);
      await page.evaluate(() => {
        const content = document.querySelector('[data-debug-id="settings-desktop-content"] > div:last-child');
        if (content) content.scrollTop = 0;
      });
      await page.screenshot({ path: path.join(evidence, `${width}-${name}.png`), fullPage: true });
      results.push({ width, state: name, ...measurement });
    };
    await checkHeading('Providers', 'Choose a bridge');
    await checkLayout('overview');
    const cardWidths = await q('providers-bridge-overview').evaluate((grid) => [...grid.children].map((card) => [card.getBoundingClientRect().width, grid.getBoundingClientRect().width]));
    assert.ok(cardWidths.every(([card, grid]) => Math.abs(card - grid) < 2), 'bridge cards span content width');
    await q('providers-bridge-bridge_test').focus();
    await page.keyboard.press('Enter');
    await q('profile-select-claude').waitFor();
    await checkHeading('Riverwood', 'Provider profiles and runtime settings on this bridge.', 'Settings / Providers');
    await checkLayout('bridge-list');
    await q('profile-select-claude').click();
    await q('profile-editor').waitFor();
    assert.equal(await page.evaluate(() => document.activeElement.tagName), 'H1', 'entering editor moves focus to its heading');
    await checkHeading('Claude Code', 'Provider profile and runtime settings on Riverwood.', 'Riverwood / claude');
    assert.equal(await q('profiles-list').count(), 0);
    const widths = await page.evaluate(() => ['profile-editor', 'provider-profiles'].map((id) => document.querySelector(`[data-debug-id="${id}"]`).getBoundingClientRect().width));
    assert.ok(Math.abs(widths[0] - widths[1]) < 2, `editor must use all content width: ${widths}`);
    await q('profile-config-dir-mode').selectOption('custom');
    await q('profile-save').click();
    await page.getByRole('alert').filter({ hasText: 'Enter a custom config directory' }).first().waitFor();
    await q('profile-config-config_dir').fill('/private/claude');
    const enabled = q('profile-enabled');
    assert.equal(await enabled.evaluate((el) => el.tagName), 'BUTTON');
    const previousEnabled = await enabled.getAttribute('aria-pressed');
    await enabled.focus();
    await page.keyboard.press('Space');
    assert.notEqual(await enabled.getAttribute('aria-pressed'), previousEnabled);
    assert.ok((await q('profile-enablement').textContent()).includes(previousEnabled === 'true' ? 'Disabled' : 'Enabled'));
    assert.ok((await q('profile-enablement').textContent()).includes('Pending save'));
    await checkLayout('availability-pending-save');
    await enabled.click();
    assert.equal(await enabled.textContent(), previousEnabled === 'true' ? 'Disable profile' : 'Enable profile');
    await q('provider-extension-action-claude').waitFor();
    const alignment = await page.evaluate(() => {
      const accent = document.querySelector('[data-debug-id="profile-accent"]');
      const label = accent.closest('label');
      const action = document.querySelector('[data-debug-id="provider-extension-action-claude"]');
      return { accentHeight: accent.getBoundingClientRect().height, labelHeight: label.getBoundingClientRect().height,
        actionPadding: getComputedStyle(action).paddingLeft };
    });
    assert.equal(alignment.accentHeight, 40);
    assert.ok(alignment.labelHeight <= 42, 'accent stays aligned with label');
    assert.equal(alignment.actionPadding, '0px', 'editor extension action has no provider-row indentation');
    await checkLayout('claude-editor');
    await q('provider-extension-install-btn-claude').scrollIntoViewIfNeeded();
    await page.screenshot({ path: path.join(evidence, width + '-extension-action.png'), fullPage: true });
    await q('profile-save').click();
    await q('profile-save').waitFor({ state: 'visible' });
    await page.waitForFunction(() => { const save = document.querySelector('[data-debug-id="profile-save"]'); return save && !save.disabled; });
    assert.equal(await q('profile-config-config_dir').inputValue(), '/private/claude');

    // The same mounted editor must survive desktop/mobile resize.
    await q('profile-label').fill('Unsaved draft');
    await checkHeading('Unsaved draft', 'Provider profile and runtime settings on Riverwood.');
    await page.setViewportSize({ width: width === 390 ? 1440 : 390, height: 1000 });
    assert.equal(await q('profile-label').inputValue(), 'Unsaved draft');
    await page.setViewportSize({ width, height: 1000 });
    await q('profile-back-to-list').click();
    assert.equal(await page.evaluate(() => document.activeElement.tagName), 'H1', 'returning to list restores heading focus');
    await checkHeading('Riverwood', 'Provider profiles and runtime settings on this bridge.');
    await q('profile-select-claude').click();
    await q('profile-delete-reset').waitFor();
    assert.equal(await q('profile-delete-reset').textContent(), 'Reset overrides');
    await q('profile-delete-reset').click();
    await q('profile-delete-confirm').click();
    await q('profiles-list').waitFor();
    assert.ok(await q('profile-select-claude').count(), 'reset keeps the default profile');
    assert.ok(await page.evaluate(() => window.providerLayoutRequests.some((r) => r.op === 'reset')));
    await q('profile-select-codex').click();
    await q('profile-config-home_path').waitFor();
    assert.ok(await q('profile-config-shadow_home_path').count());
    await checkLayout('codex-editor');
    await q('profile-cancel').click();
    await q('profile-select-antigravity').click();
    await q('profile-auth-method').waitFor();
    assert.equal(await q('profile-arg-add').count(), 0);
    assert.equal(await q('profile-custom-models').count(), 0);
    assert.ok(await q('profile-config-gcp_project').count());
    await checkLayout('antigravity-editor');
    await q('profile-cancel').click();

    await q('profile-add').click();
    await checkHeading('Add provider', 'Provider profile and runtime settings on Riverwood.');
    const checkStep = async (step) => {
      const steps = q('profile-wizard-step').locator('li');
      assert.equal(await steps.count(), 3);
      assert.equal(await q('profile-wizard-step').locator('[aria-current="step"]').count(), 1);
      assert.equal(await steps.nth(step).getAttribute('aria-current'), 'step');
      assert.ok((await steps.nth(step).textContent()).includes('Current step'));
      if (step) assert.ok((await steps.nth(step - 1).textContent()).includes('Completed'));
      if (step < 2) assert.ok((await steps.nth(step + 1).textContent()).includes('Upcoming'));
      assert.equal(await q('profile-back').isDisabled(), step === 0);
      await checkLayout('wizard-' + step);
    };
    await checkStep(0);
    await q('profile-driver').selectOption('claude');
    await q('profile-next').click();
    await checkStep(1);
    await q('profile-label').fill('Work account');
    const id = await q('profile-id').inputValue();
    await q('profile-next').click();
    await checkStep(2);
    await q('profile-back').click();
    await checkStep(1);
    assert.equal(await q('profile-label').inputValue(), 'Work account');
    await q('profile-next').click();
    await q('profile-env-add').click();
    await q('profile-env-name-0').fill('WORK_TOKEN');
    await q('profile-env-value-0').fill('fixture-replacement-secret');
    await q('profile-save').click();
    await q('profile-delete-reset').waitFor();
    assert.equal(await q('profile-env-value-0').inputValue(), '');
    assert.match(await q('profile-env-value-0').getAttribute('placeholder'), /Stored secret/);
    await q('profile-delete-reset').click();
    await q('profile-delete-confirm').click();
    await page.getByRole('alert').filter({ hasText: 'This profile is in use' }).waitFor();
    await checkLayout('delete-in-use');
    await q('profile-delete-confirm').click();
    await q('profiles-list').waitFor();
    assert.equal(await q('profile-select-' + id).count(), 0);
    await q('providers-all-bridges').click();
    await q('providers-bridge-bridge_offline').click();
    await q('profile-locked').waitFor();
    assert.equal(await q('profile-add').isDisabled(), true);
    await checkHeading('Laptop', 'Provider profiles and runtime settings on this bridge.');
    await checkLayout('offline');
    await q('providers-all-bridges').click();
    await q('providers-bridge-bridge_locked').click();
    await q('profile-locked').waitFor();
    assert.equal(await q('profiles-refresh').isDisabled(), true);
    await checkHeading('Locked', 'Provider profiles and runtime settings on this bridge.');
    await checkLayout('locked');
    await page.close();
  }
  assert.deepEqual(failures, [], 'browser exceptions');
  await fs.writeFile(path.join(evidence, 'results.json'), JSON.stringify({ results, failures }, null, 2));
  console.log(`PASS: ${results.length} responsive states; real mounted navigation, conditional forms, sealed save, secret redaction, deletion guard and resize persistence.`);
} finally {
  await browser.close();
  await server.close();
}
