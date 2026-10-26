// REQ-BUNDLE-2/3/4/5: in-memory html-bundle reading, validation and reference resolution.
// Page compilation needs a real DOM and is exercised in Electron by
// tests/e2e/html_bundle_preview_e2e.cjs.
//
// RUN: node --test tests/ui_html_bundle_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deflateRawSync } from 'node:zlib';
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
