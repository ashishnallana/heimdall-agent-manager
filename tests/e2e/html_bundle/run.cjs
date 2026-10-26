// Electron (Chromium) check of html-bundle rendering and isolation (REQ-BUNDLE-3/5).
// RUN: electron tests/e2e/html_bundle/run.cjs   (Nix: env -u LD_LIBRARY_PATH <electron>/bin/electron --ozone-platform=wayland ...)
const { app, BrowserWindow } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const zlib = require('zlib');
const { execFileSync } = require('child_process');

const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==', 'base64');

function crc32(buf) {
  let c, crc = 0xffffffff;
  for (const b of buf) { c = (crc ^ b) & 0xff; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; crc = (crc >>> 8) ^ c; }
  return (crc ^ 0xffffffff) >>> 0;
}
function zip(files) {
  const parts = []; const central = []; let offset = 0;
  for (const [name, content] of files) {
    const data = Buffer.from(content); const deflated = zlib.deflateRawSync(data); const n = Buffer.from(name);
    const h = Buffer.alloc(30); h.writeUInt32LE(0x04034b50, 0); h.writeUInt16LE(20, 4); h.writeUInt16LE(0x0800, 6); h.writeUInt16LE(8, 8);
    h.writeUInt32LE(crc32(data), 14); h.writeUInt32LE(deflated.length, 18); h.writeUInt32LE(data.length, 22); h.writeUInt16LE(n.length, 26);
    parts.push(h, n, deflated);
    const c = Buffer.alloc(46); c.writeUInt32LE(0x02014b50, 0); c.writeUInt16LE(0x0314, 4); c.writeUInt16LE(20, 6); c.writeUInt16LE(0x0800, 8); c.writeUInt16LE(8, 10);
    c.writeUInt32LE(crc32(data), 16); c.writeUInt32LE(deflated.length, 20); c.writeUInt32LE(data.length, 24); c.writeUInt16LE(n.length, 28);
    c.writeUInt32LE((0o100644 << 16) >>> 0, 38); c.writeUInt32LE(offset, 42);
    central.push(c, n); offset += 30 + n.length + deflated.length;
  }
  const cd = Buffer.concat(central); const e = Buffer.alloc(22);
  e.writeUInt32LE(0x06054b50, 0); e.writeUInt16LE(files.length, 8); e.writeUInt16LE(files.length, 10); e.writeUInt32LE(cd.length, 12); e.writeUInt32LE(offset, 16);
  return Buffer.concat([...parts, cd, e]);
}

const files = [
  ['heimdall-artifact.json', '{"format_version":1,"entrypoint":"index.html"}'],
  ['index.html', `<!doctype html><html><head><title>Home</title><link rel="stylesheet" href="css/site.css"><script>window.parent.document.title='pwned';window.__pwned=true</script></head>
<body onload="window.parent.document.title='pwned-onload'"><h1>Home</h1>
<img id="logo" src="img/logo.png" srcset="img/logo.png 1x, /img/logo.png 2x"><img id="rootimg" src="/img/logo.png">
<img id="remote" src="https://example.com/track.png"><div id="bg"></div>
<img src="missing/none.png" onerror="window.parent.document.title='pwned-onerror'">
<a id="jslink" href="javascript:window.parent.document.title='pwned-js'">js</a>
<a id="external" href="https://example.com/">external</a>
<form action="https://example.com/post" method="post"><input name="q" value="1"><button>go</button></form>
<a id="next" href="docs/two.html#sec">next</a> <a id="totop" href="#bottom">bottom</a>
<div style="height:3000px"></div><p id="bottom">bottom</p></body></html>`],
  ['css/site.css', `@import "base.css"; body{color:rgb(0,0,255)} #bg{width:4px;height:4px;background-image:url(../img/logo.png)} @font-face{font-family:BundleFont;src:url("/fonts/f.woff2") format("woff2")} h1{font-family:BundleFont}`],
  ['css/base.css', `h1{text-transform:uppercase}`],
  ['img/logo.png', PNG],
  ['fonts/f.woff2', Buffer.alloc(0)],
  ['docs/two.html', `<!doctype html><html><head><link rel="stylesheet" href="../css/site.css"></head><body><a id="back" href="/index.html">home</a><div style="height:3000px"></div><h2 id="sec">Section</h2></body></html>`],
];
// A real font is needed for fonts.status === 'loaded'; reuse any system woff2/ttf if present.
const fontCandidates = (() => { try { return execFileSync('fc-list', ['--format', '%{file}\n'], { encoding: 'utf8' }).split('\n').filter((f) => /\.(ttf|otf)$/i.test(f)); } catch { return []; } })();
if (fontCandidates[0]) { files[5] = ['fonts/f.woff2', fs.readFileSync(fontCandidates[0])]; files[2][1] = files[2][1].replace('format("woff2")', ''); }

app.whenReady().then(async () => {
  const outDir = fs.mkdtempSync(path.join(os.homedir(), '.cache', 'hb-e2e-'));
  const esbuild = path.join(__dirname, '../../../node_modules/.bin/esbuild');
  execFileSync(esbuild, [path.join(__dirname, 'page_entry.ts'), '--bundle', '--format=iife', `--outfile=${path.join(outDir, 'page.js')}`], { stdio: 'inherit' });
  fs.writeFileSync(path.join(outDir, 'host.html'), '<!doctype html><html><head><title>host</title></head><body><script src="page.js"></script></body></html>');
  const win = new BrowserWindow({ show: false, width: 1000, height: 800, webPreferences: { contextIsolation: true } });
  const network = [];
  win.webContents.session.webRequest.onBeforeRequest((details, cb) => { if (/^https?:/.test(details.url)) network.push(details.url); cb({}); });
  await win.loadFile(path.join(outDir, 'host.html'));
  let failed = 1;
  try {
    const result = await win.webContents.executeJavaScript(`window.__runBundleChecks(${JSON.stringify(zip(files).toString('base64'))})`, true);
    result.networkRequests = network;
    const booleans = Object.entries(result).filter(([, v]) => typeof v === 'boolean');
    const bad = booleans.filter(([, v]) => !v).map(([k]) => k);
    if (network.length) bad.push('networkRequests');
    if (result.objectUrlsAfterDispose !== 0) bad.push('objectUrlsAfterDispose');
    console.log(JSON.stringify(result, null, 2));
    console.log(bad.length ? `FAIL: ${bad.join(', ')}` : `ALL PASS (${booleans.length} checks)`);
    failed = bad.length ? 1 : 0;
  } catch (err) { console.log('ERROR', err); }
  fs.rmSync(outDir, { recursive: true, force: true });
  app.exit(failed);
});
