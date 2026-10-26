// Multi-engine check of html-bundle page links (REQ-BUNDLE-3) with scripts disabled
// (REQ-BUNDLE-5): mounts the production HtmlBundlePreview in Chromium, WebKit and Firefox
// through playwright-core and clicks real links inside the sandboxed frame. WebKit is the
// engine that matters: it never runs host-registered listeners in a script-disabled frame
// (docs/investigations/html-bundle-navigation-diagnosis.md).
//
// RUN: node tests/e2e/html_bundle/engines.cjs [chromium,webkit,firefox]
// Needs playwright-core and the three browsers. On NixOS they are found in /nix/store
// (playwright-core, chromium, playwright-webkit, playwright-firefox); elsewhere set
// HB_PLAYWRIGHT_CORE, HB_CHROMIUM, HB_WEBKIT, HB_FIREFOX. Not part of npm test.
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const { zip } = require('./zip.cjs');

const REPO = path.join(__dirname, '../../..');
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==', 'base64');
const MANIFEST = ['heimdall-artifact.json', '{"format_version":1,"entrypoint":"index.html"}'];
const TALL = '<div style="height:3000px"></div>';

// Modeled on the reported fixture (art_18e20011e3795118): nested page, relative CSS and
// image, Home/Details/Back, plus tall pages so fragment scrolling is observable.
const V1 = zip([
  MANIFEST,
  ['index.html', `<!doctype html><html><head><title>Home</title><link rel="stylesheet" href="assets/style.css">
<script>parent.document.title='pwned'</script></head><body onload="parent.document.title='pwned-onload'">
<nav><a id="home" href="index.html">Home</a> <a id="details" href="docs/details.html">Details</a> <a id="jump" href="#s2">Jump</a>
<a id="xfrag" href="docs/details.html#end">Details end</a> <a id="forged" href="#hb-page=docs/details.html">Forged</a>
<a id="kbd" href="./docs/details.html">Keyboard</a> <a id="external" href="https://example.com/">External</a></nav>
<h1 id="title">Overview</h1>
<img id="chart" src="assets/chart.png" width="120" height="60" usemap="#m" alt="chart"><map name="m"><area id="area" shape="rect" coords="0,0,120,60" href="docs/details.html#end" alt="Details end"></map>
${TALL}<h2 id="s2">Section</h2>${TALL}</body></html>`],
  ['docs/details.html', `<!doctype html><html><head><title>Details</title><link rel="stylesheet" href="../assets/style.css"></head><body>
<nav><a id="back" href="../index.html">Back</a> <a id="up" href="/index.html#s2">Home section</a> <a id="me" href="#end">End</a></nav>
<h1 id="title">Details</h1>${TALL}<p id="end">End</p>${TALL}</body></html>`],
  ['other.html', '<!doctype html><html><body><h1 id="title">Other</h1><a id="home" href="index.html">Home</a></body></html>'],
  ['assets/style.css', 'body{color:rgb(0,0,255)} h1{text-transform:uppercase}'],
  ['assets/chart.png', PNG],
]);
// A later version of the same artifact: same paths, different content, no other.html.
const V2 = zip([
  MANIFEST,
  ['index.html', '<!doctype html><html><body><h1 id="title">Version two</h1><a id="details" href="docs/details.html">Details</a></body></html>'],
  ['docs/details.html', '<!doctype html><html><body><h1 id="title">V2 details</h1></body></html>'],
]);

function storePath(re, sub) {
  const hit = fs.readdirSync('/nix/store').filter((n) => re.test(n) && !n.endsWith('.drv')).sort().pop();
  return hit ? path.join('/nix/store', hit, sub) : '';
}
const resolve = (env, re, sub) => process.env[env] || (fs.existsSync('/nix/store') ? storePath(re, sub) : '');
const PLAYWRIGHT = resolve('HB_PLAYWRIGHT_CORE', /-playwright-core-\d[\d.]*$/, '');
const ENGINES = {
  chromium: resolve('HB_CHROMIUM', /-chromium-\d[\d.]*$/, 'bin/chromium'),
  webkit: resolve('HB_WEBKIT', /-playwright-webkit$/, 'pw_run.sh'),
  firefox: resolve('HB_FIREFOX', /-playwright-firefox$/, 'firefox/firefox'),
};

function build(outDir) {
  execFileSync(path.join(REPO, 'node_modules/.bin/esbuild'), [
    path.join(__dirname, 'engines_entry.tsx'), '--bundle', '--format=iife', '--jsx=automatic',
    `--outfile=${path.join(outDir, 'page.js')}`, `--alias:@ui=${path.join(REPO, 'src/ui/components/ui')}`,
    '--loader:.css=empty', '--loader:.svg=dataurl', '--define:process.env.NODE_ENV="production"', '--log-level=error',
  ], { stdio: 'inherit' });
}

const FRAME = '[data-debug-id="artifact-viewer-html-bundle-frame"]';
const SELECT = '[data-debug-id="artifact-viewer-html-bundle-page-select"]';

async function runEngine(pw, name, exe, url, served) {
  const r = { checks: {} };
  const check = (key, ok, detail) => { r.checks[key] = !!ok; if (!ok && detail !== undefined) r[`${key}_detail`] = detail; };
  const browser = await pw[name].launch({ executablePath: exe, headless: true });
  try {
    r.version = browser.version();
    const ctx = await browser.newContext({ viewport: { width: 1024, height: 900 } });
    const external = [];
    ctx.on('request', (rq) => {
      const u = rq.url();
      if (u.startsWith(url)) served.push(u.slice(url.length - 1));
      else if (!/^(blob|data|about):/.test(u)) external.push(u);
    });
    const page = await ctx.newPage();
    page.setDefaultTimeout(5000);
    const errors = [];
    page.on('pageerror', (e) => errors.push(String(e)));
    const fr = () => page.frameLocator(FRAME);
    const state = () => page.evaluate(([frameSel, selectSel]) => {
      const f = document.querySelector(frameSel);
      const d = f?.contentDocument;
      return {
        select: document.querySelector(selectSel)?.textContent?.trim(),
        title: d?.getElementById('title')?.textContent,
        url: d?.URL,
        scrollY: Math.round(f?.contentWindow?.scrollY ?? -1),
        frames: document.querySelectorAll(frameSel).length,
        sandbox: f?.getAttribute('sandbox'),
        blocked: !!document.querySelector('[data-debug-id="artifact-viewer-html-bundle-navigation-blocked"]'),
        hostTitle: document.title,
        color: d?.body ? getComputedStyle(d.body).color : '',
        image: d?.getElementById('chart')?.naturalWidth ?? -1,
        scripts: d ? d.querySelectorAll('script').length : -1,
      };
    }, [FRAME, SELECT]);
    // Wait until the viewer reaches `pred`, else return the last state seen.
    const until = async (pred, ms = 4000) => {
      const end = Date.now() + ms;
      let s = await state();
      while (!pred(s) && Date.now() < end) { await page.waitForTimeout(50); s = await state(); }
      return s;
    };
    const onPage = (title, extra = () => true) => (s) => s.title === title && extra(s);
    // A failed step is recorded and the run goes on, so one broken link does not hide the rest.
    const step = async (key, action, pred) => {
      try { await action(); } catch (err) { check(key, false, String(err?.message || err).split('\n')[0]); return state(); }
      const s = await until(pred);
      check(key, pred(s), s);
      return s;
    };

    await page.goto(url);
    await page.evaluate((b64) => window.__mount(b64), V1.toString('base64'));
    let s = await until(onPage('Overview', (x) => x.image === 1));
    check('entryRendered', s.title === 'Overview' && s.select === 'index.html (entry)', s);
    check('nestedCssAndImage', s.color === 'rgb(0, 0, 255)' && s.image === 1, s);
    check('scriptsDisabled', s.sandbox === 'allow-same-origin' && s.scripts === 0 && s.hostTitle === 'host', s);
    check('pollRunning', (await page.evaluate(() => window.__intervals())) >= 1);

    await step('detailsLink', () => fr().locator('#details').click(), onPage('Details', (x) => x.select === 'docs/details.html' && x.scrollY === 0));
    await step('backLink', () => fr().locator('#back').click(), onPage('Overview', (x) => x.select === 'index.html (entry)'));
    // The page left behind had hb-page in its hash; it must not pull the viewer back.
    await page.waitForTimeout(600);
    s = await state();
    check('stableAfterBack', s.title === 'Overview' && s.frames === 1, s);
    await step('detailsLinkAgain', () => fr().locator('#details').click(), onPage('Details'));
    await step('backLinkAgain', () => fr().locator('#back').click(), onPage('Overview'));

    await step('samePageFragment', () => fr().locator('#jump').click(), onPage('Overview', (x) => x.scrollY > 1000 && x.url === 'about:srcdoc#s2'));
    await step('samePageTop', () => fr().locator('#home').click(), onPage('Overview', (x) => x.scrollY === 0));
    await step('crossPageFragment', () => fr().locator('#xfrag').click(), onPage('Details', (x) => x.scrollY > 1000 && x.select === 'docs/details.html'));
    await step('crossPageFragmentToRoot', () => fr().locator('#up').click(), onPage('Overview', (x) => x.scrollY > 1000));
    await step('samePageTopAgain', () => fr().locator('#home').click(), onPage('Overview', (x) => x.scrollY === 0));

    // An authored "#hb-page=…" fragment is only a fragment.
    await fr().locator('#forged').click();
    await page.waitForTimeout(600);
    s = await state();
    check('reservedMarkerCollision', s.title === 'Overview' && s.select === 'index.html (entry)' && /#hb-page%3D/.test(s.url || ''), s);
    // Inert external link: no navigation, no request.
    await fr().locator('#external').click();
    await page.waitForTimeout(300);
    s = await state();
    check('externalLinkInert', s.title === 'Overview' && !s.blocked, s);

    await step('keyboardEnter', async () => { await fr().locator('#kbd').focus(); await page.keyboard.press('Enter'); }, onPage('Details'));
    await step('keyboardBack', async () => { await fr().locator('#back').focus(); await page.keyboard.press('Enter'); }, onPage('Overview'));

    await step('areaLink', async () => {
      const box = await fr().locator('#chart').boundingBox();
      await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
    }, onPage('Details', (x) => x.scrollY > 1000));

    await step('hostSelector', async () => {
      await page.locator(SELECT).click();
      await page.getByRole('option', { name: 'other.html' }).click();
    }, onPage('Other', (x) => x.select === 'other.html'));
    await step('linkAfterSelector', () => fr().locator('#home').click(), onPage('Overview', (x) => x.select === 'index.html (entry)'));

    // Lock drops the poll; unlocking re-arms it.
    await page.evaluate(() => window.__lock(true));
    check('pollClearedOnLock', (await page.evaluate(() => window.__intervals())) === 0);
    await page.evaluate(() => window.__lock(false));
    await until(onPage('Overview'));
    await step('linkAfterUnlock', () => fr().locator('#details').click(), onPage('Details'));

    // Version change with a route still pending in the old version's frame: the new
    // version opens on its entry and the stale route is never followed.
    await page.evaluate(([frameSel, b64]) => {
      document.querySelector(frameSel).contentWindow.location.hash = 'hb-page=other.html';
      window.__setBlob(b64);
    }, [FRAME, V2.toString('base64')]);
    s = await until(onPage('Version two'));
    await page.waitForTimeout(600);
    s = await state();
    check('staleVersionIgnored', s.title === 'Version two' && s.select === 'index.html (entry)', s);
    check('singlePollAfterVersionChange', (await page.evaluate(() => window.__intervals())) === 1);
    await step('linkInNewVersion', () => fr().locator('#details').click(), onPage('V2 details', (x) => x.select === 'docs/details.html'));

    await page.evaluate(() => window.__unmount());
    check('pollClearedOnUnmount', (await page.evaluate(() => window.__intervals())) === 0);

    s = await state();
    check('noBlockedBanner', !s.blocked);
    check('hostTitleUnchanged', s.hostTitle === 'host', s);
    check('noExternalRequests', external.length === 0, external);
    check('noPageErrors', errors.length === 0, errors);
  } finally {
    await browser.close();
  }
  return r;
}

(async () => {
  const wanted = (process.argv[2] || 'chromium,webkit,firefox').split(',');
  const missing = [!PLAYWRIGHT && 'HB_PLAYWRIGHT_CORE', ...wanted.filter((e) => !ENGINES[e] || !fs.existsSync(ENGINES[e])).map((e) => `HB_${e.toUpperCase()}`)].filter(Boolean);
  if (missing.length) { console.error(`Cannot find ${missing.join(', ')}; set them to the playwright-core module and browser executables.`); process.exit(2); }
  const pw = require(PLAYWRIGHT);
  const outDir = fs.mkdtempSync(path.join(os.homedir(), '.cache', 'hb-engines-'));
  build(outDir);
  // The app's Tailwind classes are not loaded here, so size the frame like the viewer does.
  const host = '<!doctype html><html><head><title>host</title><style>iframe{width:100%;height:600px}</style></head><body><div id="root"></div><script src="page.js"></script></body></html>';
  const server = http.createServer((q, res) => {
    if (q.url === '/page.js') { res.writeHead(200, { 'content-type': 'text/javascript' }); return res.end(fs.readFileSync(path.join(outDir, 'page.js'))); }
    if (q.url !== '/') { res.writeHead(404); return res.end(); }
    res.writeHead(200, { 'content-type': 'text/html' }); res.end(host);
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const url = `http://127.0.0.1:${server.address().port}/`;
  let failed = 0;
  const results = {};
  for (const name of wanted) {
    const served = [];
    try {
      results[name] = await runEngine(pw, name, ENGINES[name], url, served);
    } catch (err) {
      results[name] = { checks: { completed: false }, error: String(err?.message || err).split('\n').slice(0, 4).join(' | ') };
    }
    // Only the host page and its script come from the server; the bundle loads nothing.
    results[name].checks.onlyHostRequests = served.every((u) => u === '/' || u === '/page.js');
    const bad = Object.entries(results[name].checks).filter(([, ok]) => !ok).map(([k]) => k);
    failed += bad.length;
    console.log(`${name.padEnd(8)} ${results[name].version || ''}: ${bad.length ? `FAIL ${bad.join(', ')}` : `ALL PASS (${Object.keys(results[name].checks).length} checks)`}`);
  }
  if (failed) console.log(JSON.stringify(results, null, 1));
  server.close();
  fs.rmSync(outDir, { recursive: true, force: true });
  process.exit(failed ? 1 : 0);
})();
