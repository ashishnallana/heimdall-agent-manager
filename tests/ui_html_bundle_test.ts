// REQ-BUNDLE-2/3/4/5: in-memory html-bundle reading, validation and reference resolution.
// Page compilation is checked here against jsdom and end to end in Electron by
// tests/e2e/html_bundle/run.cjs.
//
// RUN: node --test tests/ui_html_bundle_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deflateRawSync } from 'node:zlib';
import { JSDOM } from 'jsdom';
import {
  HtmlBundleError,
  HtmlBundleRenderer,
  crc32,
  readHtmlBundle,
  resolveBundleRef,
  validateMemberPath,
} from '../src/ui/utils/htmlBundle.ts';

type Entry = { name: string; data: Uint8Array | string; method?: number; flags?: number; declared?: number; crc?: number; madeBy?: number; external?: number; raw?: boolean };

const enc = (s: string) => new TextEncoder().encode(s);

/** Minimal ZIP writer with full control over hostile fields. */
export function zip(entries: Entry[]): Uint8Array {
  const chunks: number[] = [];
  const u16 = (v: number) => chunks.push(v & 0xff, (v >>> 8) & 0xff);
  const u32 = (v: number) => chunks.push(v & 0xff, (v >>> 8) & 0xff, (v >>> 16) & 0xff, (v >>> 24) & 0xff);
  const bytes = (b: Uint8Array) => { for (const x of b) chunks.push(x); };
  const prepared = entries.map((e) => {
    const plain = typeof e.data === 'string' ? enc(e.data) : e.data;
    const method = e.method ?? 0;
    const stored = method === 8 && !e.raw ? new Uint8Array(deflateRawSync(plain)) : plain;
    return { e, plain, stored, method, name: enc(e.name), size: e.declared ?? plain.length, crc: e.crc ?? crc32(plain), offset: 0 };
  });
  for (const p of prepared) {
    p.offset = chunks.length;
    u32(0x04034b50); u16(20); u16(p.e.flags ?? 0x0800); u16(p.method); u16(0); u16(0x21); u32(p.crc); u32(p.stored.length); u32(p.size); u16(p.name.length); u16(0);
    bytes(p.name); bytes(p.stored);
  }
  const cd = chunks.length;
  for (const p of prepared) {
    u32(0x02014b50); u16(p.e.madeBy ?? 0x0314); u16(20); u16(p.e.flags ?? 0x0800); u16(p.method); u16(0); u16(0x21); u32(p.crc); u32(p.stored.length); u32(p.size);
    u16(p.name.length); u16(0); u16(0); u16(0); u16(0); u32(p.e.external ?? (0o100644 << 16) >>> 0); u32(p.offset);
    bytes(p.name);
  }
  const cdSize = chunks.length - cd;
  u32(0x06054b50); u16(0); u16(0); u16(prepared.length); u16(prepared.length); u32(cdSize); u32(cd); u16(0);
  return Uint8Array.from(chunks);
}

const MANIFEST = { name: 'heimdall-artifact.json', data: '{"format_version":1,"entrypoint":"index.html"}' };

async function rejects(entries: Entry[] | Uint8Array, code: string, pattern: RegExp) {
  const data = entries instanceof Uint8Array ? entries : zip(entries);
  await assert.rejects(readHtmlBundle(data), (err: unknown) => {
    assert.ok(err instanceof HtmlBundleError, String(err));
    assert.equal(err.code, code, err.message);
    assert.match(err.message, pattern);
    return true;
  });
}

test('reads a valid bundle with stored and deflated members, byte-exact', async () => {
  const png = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0xff, 0xfe]);
  const bundle = await readHtmlBundle(zip([
    MANIFEST,
    { name: 'index.html', data: '<a href="docs/two.html">two</a>', method: 8 },
    { name: 'docs/', data: '' },
    { name: 'docs/two.html', data: '<h1 id="s">two</h1>' },
    { name: 'img/a.png', data: png, method: 8 },
  ]));
  assert.equal(bundle.entry, 'index.html');
  assert.deepEqual(bundle.pages, ['docs/two.html', 'index.html']);
  assert.deepEqual([...bundle.files.get('img/a.png')!], [...png]);
  assert.ok(!bundle.files.has('heimdall-artifact.json'));
});

test('manifest and entry errors are distinguishable', async () => {
  await rejects([{ name: 'index.html', data: 'x' }], 'malformed', /no heimdall-artifact\.json/);
  await rejects([{ ...MANIFEST, data: '{"format_version":1,"entrypoint":"gone.html"}' }, { name: 'index.html', data: 'x' }], 'missing_entry', /missing from the bundle/);
  await rejects([{ ...MANIFEST, data: '{"format_version":1,"entrypoint":"Index.html"}' }, { name: 'index.html', data: 'x' }], 'missing_entry', /case-sensitive/);
  await rejects([{ ...MANIFEST, data: '{"format_version":1,"entrypoint":"style.css"}' }, { name: 'style.css', data: 'x' }], 'missing_entry', /not an HTML page/);
  await rejects([{ ...MANIFEST, data: '{"format_version":2,"entrypoint":"index.html"}' }, { name: 'index.html', data: 'x' }], 'malformed', /format_version must be 1/);
  await rejects([{ ...MANIFEST, data: '{"format_version":1,"entrypoint":"index.html","x":1}' }, { name: 'index.html', data: 'x' }], 'malformed', /unsupported field/);
  await rejects([{ ...MANIFEST, data: 'not json' }, { name: 'index.html', data: 'x' }], 'malformed', /not valid JSON/);
});

test('rejects unsafe archives', async () => {
  const ok = [MANIFEST, { name: 'index.html', data: 'x' }];
  await rejects([...ok, { name: '../evil.html', data: 'x' }], 'unsafe', /path traversal/);
  await rejects([...ok, { name: '/etc/passwd', data: 'x' }], 'unsafe', /absolute member path/);
  await rejects([...ok, { name: 'a\\b.css', data: 'x' }], 'unsafe', /backslash/);
  await rejects([...ok, { name: 'C:/x.css', data: 'x' }], 'unsafe', /drive-qualified/);
  await rejects([...ok, { name: 'index.html', data: 'y' }], 'unsafe', /Duplicate member path/);
  await rejects([...ok, { name: 'a', data: 'x' }, { name: 'a/b.css', data: 'y' }], 'unsafe', /both a file and a directory/);
  await rejects([...ok, { name: 'inner.zip', data: 'x' }], 'unsafe', /nested archive/);
  await rejects([...ok, { name: 'inner.bin', data: 'PK\x03\x04data' }], 'unsafe', /nested archive/);
  await rejects([...ok, { name: 's.css', data: 'x', flags: 0x0801 }], 'unsafe', /encrypted/);
  await rejects([...ok, { name: 's.css', data: 'x', method: 12, raw: true }], 'unsafe', /compression method 12/);
  await rejects([...ok, { name: 'l.css', data: '/etc/passwd', madeBy: 0x0314, external: (0o120777 << 16) >>> 0 }], 'unsafe', /symbolic link/);
  await rejects([...ok, { name: 'caf\u00e9.css', data: 'x', flags: 0 }], 'unsafe', /not ASCII/);
});

test('enforces declared and actual size limits', async () => {
  const ok = [MANIFEST, { name: 'index.html', data: 'x' }];
  // 1 MiB of zeros deflates to ~1 KiB; declaring 1000 bytes must not let it expand.
  await rejects([...ok, { name: 'bomb.txt', data: new Uint8Array(1024 * 1024), method: 8, declared: 1000 }], 'too_large', /expands beyond its declared size/);
  await rejects([...ok, { name: 'big.txt', data: 'x', method: 8, declared: 10 * 1024 * 1024 + 1 }], 'too_large', /per-member limit/);
  const many = Array.from({ length: 6 }, (_, i) => ({ name: `f${i}.bin`, data: 'x', method: 8, declared: 10 * 1024 * 1024 }));
  await rejects([...ok, ...many], 'too_large', /expands past 50 MiB/);
  await rejects([...ok, ...Array.from({ length: 1000 }, (_, i) => ({ name: `p${i}.css`, data: 'x' }))], 'too_large', /entries; the limit is 1000/);
  await rejects(new Uint8Array(10 * 1024 * 1024 + 1), 'too_large', /limit is 10 MiB/);
  await rejects([...ok, { name: 's.css', data: 'abc', crc: 0x12345678 }], 'malformed', /CRC-32/);
  await rejects([...ok, { name: 'c.txt', data: Uint8Array.from([0xff, 0xff, 0xff]), method: 8, raw: true, declared: 10 }], 'malformed', /could not be inflated/);
  await rejects(enc('<html>not a zip</html>'), 'malformed', /Not a ZIP archive/);
});

test('resolves references relative to the referring file and the bundle root', () => {
  assert.deepEqual(resolveBundleRef('img/a.png', 'docs/page.html'), { kind: 'local', path: 'docs/img/a.png', fragment: '' });
  assert.deepEqual(resolveBundleRef('../css/x.css?v=2#top', 'docs/page.html'), { kind: 'local', path: 'css/x.css', fragment: 'top' });
  assert.deepEqual(resolveBundleRef('/img/a%20b.png', 'docs/deep/page.html'), { kind: 'local', path: 'img/a b.png', fragment: '' });
  assert.deepEqual(resolveBundleRef('#sec', 'docs/page.html'), { kind: 'fragment', fragment: 'sec' });
  assert.deepEqual(resolveBundleRef('../../x.png', 'docs/page.html'), { kind: 'invalid' });
  for (const ext of ['https://example.com/x.png', '//cdn.example.com/x.css', 'mailto:a@b.c', 'javascript:alert(1)', ' JaVaScRiPt:alert(1)', 'java\tscript:alert(1)']) {
    assert.equal(resolveBundleRef(ext, 'index.html').kind, 'external', ext);
  }
  assert.equal(resolveBundleRef('data:image/png;base64,AAAA', 'index.html').kind, 'data');
  assert.equal(validateMemberPath('a/./b'), 'path traversal in member path');
  assert.equal(validateMemberPath('ok/Path.HTML'), '');
});

test('renderer releases every object URL on dispose', async () => {
  const bundle = await readHtmlBundle(zip([MANIFEST, { name: 'index.html', data: 'x' }, { name: 'a.png', data: 'p' }, { name: 'f.woff2', data: 'f' }]));
  const created: string[] = [];
  const revoked: string[] = [];
  const renderer = new HtmlBundleRenderer(bundle, {
    createObjectURL: () => { const url = `blob:test/${created.length}`; created.push(url); return url; },
    revokeObjectURL: (url) => { revoked.push(url); },
  });
  const missing = new Set<string>();
  const css = renderer.compileCss('@font-face{src:url(f.woff2)} body{background:url("a.png")} i{background:url(https://evil.example/x.png)} b{background:url(nope.png)}', 'index.html', missing);
  assert.match(css, /url\("blob:test\/0"\)/);
  assert.match(css, /url\("blob:test\/1"\)/);
  assert.ok(!css.includes('evil.example'));
  assert.deepEqual([...missing].sort(), ['https://evil.example/x.png', 'nope.png']);
  assert.equal(renderer.objectUrlCount, 2);
  renderer.dispose();
  assert.deepEqual(revoked.sort(), created.sort());
  assert.equal(renderer.objectUrlCount, 0);
});

test('compilePage strips SVG SMIL animation that could retarget a link at runtime', async () => {
  const page = `<!doctype html><html><head></head><body>
<svg><a id="set" href="#top"><set attributeName="href" to="https://evil.example/set"/><text>set</text></a>
<a id="anim"><animate attributeName="xlink:href" values="https://evil.example/anim"/><animateMotion dur="1s"/><animateTransform attributeName="transform"/><animateColor/><discard/><text>anim</text></a>
<a id="ok" href="#top"><text>ok</text></a></svg><p id="top">top</p></body></html>`;
  const bundle = await readHtmlBundle(zip([MANIFEST, { name: 'index.html', data: page }]));
  const parseHtml = (html: string) => new JSDOM(html).window.document;
  const renderer = new HtmlBundleRenderer(bundle, { parseHtml, createObjectURL: () => 'blob:test/0', revokeObjectURL: () => {} });
  const { html } = renderer.compilePage('index.html');
  const doc = parseHtml(html);
  for (const name of ['set', 'animate', 'animateMotion', 'animateTransform', 'animateColor', 'discard']) {
    assert.equal(doc.getElementsByTagName(name).length, 0, name);
  }
  assert.ok(!html.includes('evil.example'), html);
  assert.equal(doc.getElementById('set')?.getAttribute('href'), 'about:srcdoc#top');
  assert.equal(doc.getElementById('ok')?.getAttribute('href'), 'about:srcdoc#top');
  assert.ok(doc.querySelector('meta[http-equiv="Content-Security-Policy"]'));
});

function jsdomRenderer(bundle: Awaited<ReturnType<typeof readHtmlBundle>>, parseHtml = (html: string) => new JSDOM(html).window.document) {
  let n = 0;
  return new HtmlBundleRenderer(bundle, { parseHtml, createObjectURL: () => `blob:test/${n++}`, revokeObjectURL: () => {} });
}

/** What the sandboxed iframe sees: compiled text reparsed. */
function assertNoBreakout(html: string) {
  const doc = new JSDOM(html).window.document;
  // The hostile text may survive as inert CSS text; it must not reach any element or attribute.
  for (const el of Array.from(doc.querySelectorAll('*'))) {
    for (const attr of Array.from(el.attributes)) assert.ok(!attr.value.includes('evil.example'), `${el.localName} ${attr.name}=${attr.value}`);
  }
  assert.equal(doc.querySelectorAll('meta[http-equiv]').length, 1, html);
  for (const a of Array.from(doc.querySelectorAll('a[href]'))) assert.match(a.getAttribute('href') || '', /^about:srcdoc#/);
  for (const style of Array.from(doc.querySelectorAll('style'))) assert.ok(!(style.textContent || '').includes('</'), style.textContent || '');
  return doc;
}

const BREAKOUT = '</style><a id="inj" href="https://evil.example/click">x</a><meta http-equiv="refresh" content="0;url=https://evil.example/r"><style>';

test('compiled CSS from <link> and @import cannot close its <style> element', async () => {
  const bundle = await readHtmlBundle(zip([
    MANIFEST,
    { name: 'index.html', data: '<!doctype html><html><head><link rel="stylesheet" href="css/a.css"><style>@import "css/b.css"; p{color:red}</style></head><body><p>hi</p></body></html>' },
    { name: 'css/a.css', data: `p{color:blue} /* ${BREAKOUT} */ i{content:"${BREAKOUT.replace(/"/g, "'")}"}` },
    { name: 'css/b.css', data: `b{content:'${BREAKOUT.replace(/'/g, '"')}'}` },
  ]));
  const { html } = jsdomRenderer(bundle).compilePage('index.html');
  const doc = assertNoBreakout(html);
  assert.equal(doc.getElementById('inj'), null);
  // The content survives as CSS: \3c / is the CSS escape for "</".
  assert.match(html, /\\3c \/style>/);
  assert.equal(doc.querySelectorAll('style').length, 2);
});

test('a percent-decoded url("#…") fragment in authored CSS is re-encoded', async () => {
  const bundle = await readHtmlBundle(zip([
    MANIFEST,
    { name: 'index.html', data: '<!doctype html><html><head><style>p{background:url("#%3C/style%3E%3Ca%20href=https://evil.example%3Ex%3C/a%3E")} svg{filter:url(#blur)}</style></head><body><p>hi</p></body></html>' },
  ]));
  const { html } = jsdomRenderer(bundle).compilePage('index.html');
  assertNoBreakout(html);
  assert.match(html, /url\("#blur"\)/);
});

test('CSS range media queries keep their bare "<"', async () => {
  const bundle = await readHtmlBundle(zip([MANIFEST, { name: 'index.html', data: '<style>@media (width < 600px){p{color:red}}</style><p>x</p>' }]));
  const { html } = jsdomRenderer(bundle).compilePage('index.html');
  assert.ok(new JSDOM(html).window.document.querySelector('style')?.textContent?.includes('(width < 600px)'), html);
});

test('<use> keeps same-document references and drops external SVG documents', async () => {
  const bundle = await readHtmlBundle(zip([
    MANIFEST,
    { name: 'index.html', data: '<svg><symbol id="i"><rect/></symbol><use id="local" href="#i"/><use id="ext" href="sprite.svg#icon"/><use id="xext" xlink:href="sprite.svg#icon"/><image id="img" href="sprite.svg"/></svg>' },
    { name: 'sprite.svg', data: '<svg xmlns="http://www.w3.org/2000/svg"><a href="https://evil.example/u"><set attributeName="href" to="https://evil.example/s"/><rect id="icon"/></a></svg>' },
  ]));
  const { html, missing } = jsdomRenderer(bundle).compilePage('index.html');
  const doc = new JSDOM(html).window.document;
  assert.equal(doc.getElementById('local')?.getAttribute('href'), '#i');
  assert.equal(doc.getElementById('ext')?.hasAttribute('href'), false);
  assert.equal(doc.getElementById('xext')?.hasAttribute('xlink:href'), false);
  assert.match(doc.getElementById('img')?.getAttribute('href') || '', /^blob:test\//);
  assert.deepEqual(missing, ['sprite.svg']);
});

test('compilePage fails closed when the reparsed page holds markup the sanitizer did not emit', async () => {
  const bundle = await readHtmlBundle(zip([MANIFEST, { name: 'index.html', data: '<p>x</p>' }]));
  // Stand-in for a serializer/parser round-trip difference: the verification parse sees more.
  let calls = 0;
  const parseHtml = (html: string) => new JSDOM(calls++ === 0 ? html : html.replace('</body>', '<a href="https://evil.example/x">x</a></body>')).window.document;
  assert.throws(() => jsdomRenderer(bundle, parseHtml).compilePage('index.html'), (err: unknown) => {
    assert.ok(err instanceof HtmlBundleError);
    assert.equal(err.code, 'unsafe');
    assert.match(err.message, /a href/);
    return true;
  });
});
