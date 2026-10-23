// Optional local browser evidence. Supply a local puppeteer-core module and Chrome
// executable via PUPPETEER_MODULE / CHROME_BIN when they are not on the usual path.
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
const { default: puppeteer } = await import(process.env.PUPPETEER_MODULE || 'puppeteer-core');
const base = process.argv[2] || 'http://127.0.0.1:5178/';
const out = path.resolve(process.argv[3] || 'docs/evidence/multi-question');
await mkdir(out, { recursive: true });
const browser = await puppeteer.launch({ browser: process.env.BROWSER || 'chrome', executablePath: process.env.CHROME_BIN, headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
const page = await browser.newPage();
page.setDefaultTimeout(12000);
const errors = [];
const apiRequests = [];
const results = [];
page.on('pageerror', (error) => errors.push(error.message));
await page.setRequestInterception(true);
page.on('request', (request) => {
  if (new URL(request.url()).pathname.includes('/api/')) { apiRequests.push(request.url()); void request.abort(); }
  else void request.continue();
});
const id = (value) => `[data-debug-id="${value}"]`;
const field = (value) => id(`mq-demo-questions-source-${value}`);
const goto = async (suffix = '') => {
  await page.goto(`${base}${suffix}`, { waitUntil: 'networkidle0' });
  await page.waitForSelector(field(suffix ? 'answered' : 'submit'));
};
const screenshot = async (name) => page.screenshot({ path: path.join(out, `${name}.png`), fullPage: true });
const record = (name, detail = {}) => results.push({ name, passed: true, ...detail });
try {
  await page.setViewport({ width: 1280, height: 1100, deviceScaleFactor: 1 });
  await goto();
  await screenshot('desktop');
  await page.focus(field('question-target-option-staging'));
  await page.keyboard.press('ArrowRight');
  assert.equal(await page.$eval(field('question-target-option-production'), (el) => el.checked), true);
  await page.focus(field('question-checks-option-smoke')); await page.keyboard.press(' ');
  await page.focus(field('question-checks-option-integration')); await page.keyboard.press(' ');
  assert.equal(await page.$$eval('input[type=checkbox]:checked', (els) => els.length), 2);
  await page.focus(field('question-report-custom')); await page.keyboard.type('Release notes and any failed checks.');
  assert.match(await page.$eval(id('mq-demo-deliveries'), (el) => el.textContent), /0$/);
  const semantics = await page.$$eval('form input,form textarea,form button', (els) => els.map((el) => ({ debugId: el.dataset.debugId, label: el.tagName === 'BUTTON' ? Number(Boolean(el.textContent?.trim())) : el.labels?.length || 0 })));
  assert.ok(semantics.every((el) => el.debugId && el.label > 0));
  await page.keyboard.press('Tab');
  assert.equal(await page.evaluate(() => document.activeElement?.dataset.debugId), 'mq-demo-questions-source-submit');
  record('desktop keyboard: native radio arrows, multi-select space, custom text, labeled inputs, Tab to submit, selection never sends', { controls: semantics.length });
  await screenshot('desktop');
  await page.click(id('mq-demo-fail'));
  await page.click(field('submit'));
  await page.waitForSelector(field('error'));
  assert.equal(await page.$eval(field('question-report-custom'), (el) => el.value), 'Release notes and any failed checks.');
  await screenshot('retry');
  await page.click(field('submit'));
  await page.waitForSelector(field('answered'));
  assert.match(await page.$eval(id('mq-demo-deliveries'), (el) => el.textContent), /1$/);
  assert.equal(await page.$('form input,form textarea,form button'), null);
  await screenshot('answered');
  record('retry preserves draft and submits once; answered questions remain readable');
  await goto('?state=answered');
  assert.equal(await page.$('form input,form textarea,form button'), null);
  record('reloaded backend answered-state fixture shows read-only questions');
  for (const direction of ['user', 'agent']) {
    await goto(); await page.click(id(`mq-demo-new-${direction}`));
    await page.waitForFunction(() => document.querySelectorAll('form input,form textarea,form button').length === 0);
    assert.match(await page.$eval('main', (el) => el.textContent), /Where should the release go/);
    record(`new ${direction} message retires controls and preserves original content`);
  }
  await screenshot('stale');
  await goto(); await page.click(id('mq-demo-lock'));
  await page.waitForSelector(field('locked'));
  assert.equal(await page.$('form input,form textarea,form button'), null);
  await screenshot('locked');
  await page.click(id('mq-demo-lock')); await page.waitForSelector(field('submit'));
  record('vault lock hides encrypted labels/controls; unlock restores authenticated questions');
  await page.setViewport({ width: 390, height: 844, deviceScaleFactor: 1 });
  await goto();
  await page.click(field('question-target-option-staging'));
  await page.click(field('question-checks-option-smoke'));
  await page.click(field('question-checks-option-integration'));
  await page.focus(field('question-report-custom')); await page.keyboard.type('Only failed checks, please.');
  const layout = await page.evaluate(() => ({ width: innerWidth, scrollWidth: document.documentElement.scrollWidth,
    heights: [...document.querySelectorAll('form label[data-debug-id],form textarea,form button')].map((el) => el.getBoundingClientRect().height) }));
  assert.ok(layout.scrollWidth <= layout.width, 'no mobile horizontal overflow');
  assert.ok(layout.heights.every((height) => height >= 44), 'mobile choice labels, text fields and submit have at least 44px targets');
  await screenshot('mobile');
  await page.click(field('submit')); await page.waitForSelector(field('answered'));
  assert.match(await page.$eval(id('mq-demo-deliveries'), (el) => el.textContent), /1$/);
  record('390px mobile viewport: selections, custom text, explicit submit, no overflow and 44px targets (desktop browser input)', layout);
  assert.deepEqual(apiRequests, [], 'local fixture must never call production APIs');
  assert.deepEqual(errors, [], 'no browser errors');
  await writeFile(path.join(out, 'results.json'), `${JSON.stringify({ browser: await browser.version(), fixture: 'production ChatMessageList/MultiQuestionForm; ephemeral vault key and mocked delivery', results, apiRequests, errors }, null, 2)}\n`);
  console.log(JSON.stringify({ passed: results.length, screenshots: out, apiRequests, errors }));
} finally { await browser.close(); }
