// Static HTML bundle artifacts (REQ-BUNDLE-3/4/5).
//
// An html-bundle artifact is a ZIP with the manifest `heimdall-artifact.json`
// = {"format_version":1,"entrypoint":"<member>.html"}; ham-ctl builds and validates it
// (src/ctl/html_bundle.odin — keep limits, path grammar and manifest rules in step).
//
// The viewer never extracts to disk and never loads the archive as a document. The
// decrypted bytes are parsed here, in memory, and each HTML page is compiled into a
// self-contained `srcdoc`:
//   - scripts, event handlers, executable URLs, frames/objects, forms, <base> and
//     <meta http-equiv> are removed;
//   - local images/fonts/stylesheets become blob: URLs (stylesheets inlined, @import
//     inlined recursively, url() rewritten relative to the stylesheet);
//   - remote references are dropped and a CSP meta forbids any network load;
//   - links to other pages carry data-hb-page/data-hb-fragment for the host to follow,
//     and fragment links point at about:srcdoc#frag (a bare "#frag" in a srcdoc
//     document resolves against the PARENT url and would navigate the frame away).
// The iframe is sandboxed without allow-scripts (see HtmlBundlePreview.tsx).

export const HTML_BUNDLE_KIND = 'html-bundle';
export const HTML_BUNDLE_MANIFEST = 'heimdall-artifact.json';
export const HTML_BUNDLE_LIMITS = Object.freeze({
  archiveBytes: 10 * 1024 * 1024,
  expandedBytes: 50 * 1024 * 1024,
  entries: 1000,
  memberBytes: 10 * 1024 * 1024,
  manifestBytes: 64 * 1024,
  pathBytes: 1024,
});

export const HTML_BUNDLE_CSP = "default-src 'none'; img-src blob: data:; style-src 'unsafe-inline'; font-src blob: data:; form-action 'none'; base-uri 'none'";

export type HtmlBundleErrorCode = 'malformed' | 'unsafe' | 'too_large' | 'missing_entry';

export class HtmlBundleError extends Error {
  code: HtmlBundleErrorCode;
  constructor(code: HtmlBundleErrorCode, message: string) {
    super(message);
    this.code = code;
    this.name = 'HtmlBundleError';
  }
}

export type HtmlBundle = {
  entry: string;
  pages: string[];
  files: Map<string, Uint8Array>;
};

const NESTED_ARCHIVE_EXT = ['.zip', '.jar', '.war', '.apk', '.gz', '.tgz', '.tar', '.bz2', '.xz', '.7z', '.rar', '.zst'];

export function isHtmlPath(path: string): boolean {
  const lower = path.toLowerCase();
  return lower.endsWith('.html') || lower.endsWith('.htm');
}

/** Member path grammar shared with ham-ctl. Returns '' when acceptable, else the reason. */
export function validateMemberPath(path: string): string {
  if (!path) return 'empty member path';
  if (new TextEncoder().encode(path).length > HTML_BUNDLE_LIMITS.pathBytes) return 'member path is too long';
  if (path.startsWith('/')) return 'absolute member path';
  if (path.length >= 2 && path[1] === ':') return 'drive-qualified member path';
  for (let i = 0; i < path.length; i += 1) {
    const c = path.charCodeAt(i);
    if (c < 0x20 || c === 0x7f) return 'control character in member path';
    if (path[i] === '\\') return 'backslash in member path';
  }
  const trimmed = path.endsWith('/') ? path.slice(0, -1) : path;
  for (const segment of trimmed.split('/')) {
    if (segment === '') return 'empty segment in member path';
    if (segment === '.' || segment === '..') return 'path traversal in member path';
  }
  return '';
}

// ── ZIP reading ──────────────────────────────────────────────────────────────

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

export function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i += 1) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

type ZipMember = {
  path: string;
  isDir: boolean;
  method: number;
  crc: number;
  compressed: number;
  size: number;
  localOffset: number;
  dataOffset: number;
};

function fail(code: HtmlBundleErrorCode, message: string): never {
  throw new HtmlBundleError(code, message);
}

const utf8Strict = new TextDecoder('utf-8', { fatal: true });

/** Parse the central directory and enforce every rule that does not need member bytes. */
export function parseZipDirectory(data: Uint8Array): ZipMember[] {
  if (data.length > HTML_BUNDLE_LIMITS.archiveBytes) fail('too_large', `Archive is ${data.length} bytes; the limit is 10 MiB.`);
  if (data.length < 22) fail('malformed', 'Not a ZIP archive.');
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const u16 = (o: number) => view.getUint16(o, true);
  const u32 = (o: number) => view.getUint32(o, true);
  let eocd = -1;
  for (let i = data.length - 22; i >= Math.max(0, data.length - 22 - 0xffff); i -= 1) {
    if (u32(i) === 0x06054b50 && i + 22 + u16(i + 20) === data.length) { eocd = i; break; }
  }
  if (eocd < 0) fail('malformed', 'Not a ZIP archive (no end of central directory).');
  if (u16(eocd + 4) !== 0 || u16(eocd + 6) !== 0 || u16(eocd + 8) !== u16(eocd + 10)) fail('malformed', 'Multi-disk ZIP archives are not supported.');
  const count = u16(eocd + 10);
  const cdSize = u32(eocd + 12);
  const cdOffset = u32(eocd + 16);
  if (count === 0xffff || cdSize === 0xffffffff || cdOffset === 0xffffffff) fail('malformed', 'Zip64 archives are not supported.');
  if (count > HTML_BUNDLE_LIMITS.entries) fail('too_large', `Archive has ${count} entries; the limit is ${HTML_BUNDLE_LIMITS.entries}.`);
  if (cdOffset + cdSize > eocd) fail('malformed', 'Corrupt ZIP archive (central directory out of range).');

  const members: ZipMember[] = [];
  let pos = cdOffset;
  let declaredTotal = 0;
  for (let n = 0; n < count; n += 1) {
    if (pos + 46 > cdOffset + cdSize || u32(pos) !== 0x02014b50) fail('malformed', 'Corrupt ZIP archive (bad central directory record).');
    const madeBy = u16(pos + 4);
    const flags = u16(pos + 8);
    const method = u16(pos + 10);
    const crc = u32(pos + 16);
    const compressed = u32(pos + 20);
    const size = u32(pos + 24);
    const nameLen = u16(pos + 28);
    const recordEnd = pos + 46 + nameLen + u16(pos + 30) + u16(pos + 32);
    const external = u32(pos + 38);
    const localOffset = u32(pos + 42);
    if (recordEnd > cdOffset + cdSize) fail('malformed', 'Corrupt ZIP archive (central directory record out of range).');
    const nameBytes = data.subarray(pos + 46, pos + 46 + nameLen);
    if (!(flags & 0x0800) && nameBytes.some((b) => b >= 0x80)) fail('unsafe', 'A member path is not ASCII and not flagged UTF-8.');
    let path: string;
    try { path = utf8Strict.decode(nameBytes); } catch { fail('unsafe', 'A member path is not valid UTF-8.'); }
    if (flags & 0x0001) fail('unsafe', `Member "${path}" is encrypted; encrypted ZIPs are not supported.`);
    if (compressed === 0xffffffff || size === 0xffffffff || localOffset === 0xffffffff) fail('malformed', 'Zip64 archives are not supported.');
    if (method !== 0 && method !== 8) fail('unsafe', `Member "${path}" uses unsupported compression method ${method}.`);
    const reason = validateMemberPath(path);
    if (reason) fail('unsafe', `${reason}: "${path}"`);
    if (madeBy >> 8 === 3 && ((external >>> 16) & 0o170000) === 0o120000) fail('unsafe', `Member "${path}" is a symbolic link.`);
    const isDir = path.endsWith('/');
    if (isDir && size !== 0) fail('malformed', `Directory member "${path}" has content.`);
    if (!isDir && NESTED_ARCHIVE_EXT.some((ext) => path.toLowerCase().endsWith(ext))) fail('unsafe', `Member "${path}" is a nested archive.`);
    if (size > HTML_BUNDLE_LIMITS.memberBytes) fail('too_large', `Member "${path}" declares ${size} bytes; the per-member limit is 10 MiB.`);
    if (method === 0 && compressed !== size) fail('malformed', `Stored member "${path}" has mismatched sizes.`);
    declaredTotal += size;
    if (declaredTotal > HTML_BUNDLE_LIMITS.expandedBytes) fail('too_large', 'Archive expands past 50 MiB.');
    if (localOffset + 30 > cdOffset || u32(localOffset) !== 0x04034b50) fail('malformed', `Corrupt ZIP archive (bad local header for "${path}").`);
    const localNameLen = u16(localOffset + 26);
    const dataOffset = localOffset + 30 + localNameLen + u16(localOffset + 28);
    const localName = data.subarray(localOffset + 30, localOffset + 30 + localNameLen);
    if (dataOffset > cdOffset || localName.length !== nameBytes.length || localName.some((b, i) => b !== nameBytes[i])) fail('malformed', `Corrupt ZIP archive (local header disagrees for "${path}").`);
    if (u16(localOffset + 6) & 0x0001) fail('unsafe', `Member "${path}" is encrypted; encrypted ZIPs are not supported.`);
    if (dataOffset + compressed > cdOffset) fail('malformed', `Corrupt ZIP archive (data for "${path}" out of range).`);
    members.push({ path, isDir, method, crc, compressed, size, localOffset, dataOffset });
    pos = recordEnd;
  }
  const byOffset = [...members].sort((a, b) => a.localOffset - b.localOffset);
  for (let i = 1; i < byOffset.length; i += 1) {
    const prev = byOffset[i - 1];
    if (byOffset[i].localOffset < prev.dataOffset + prev.compressed) fail('unsafe', `Members "${prev.path}" and "${byOffset[i].path}" overlap.`);
  }
  const files = new Set<string>();
  const dirs = new Set<string>();
  for (const m of members) {
    const key = m.isDir ? m.path.slice(0, -1) : m.path;
    if (files.has(key) || (m.isDir && dirs.has(key))) fail('unsafe', `Duplicate member path "${key}".`);
    if (!m.isDir && dirs.has(key)) fail('unsafe', `Member "${key}" is both a file and a directory.`);
    (m.isDir ? dirs : files).add(key);
  }
  for (const f of files) {
    let p = f;
    for (let slash = p.lastIndexOf('/'); slash >= 0; slash = p.lastIndexOf('/')) {
      p = p.slice(0, slash);
      if (files.has(p)) fail('unsafe', `Member "${p}" is both a file and a directory.`);
    }
  }
  return members;
}

/** Inflate a raw deflate stream, aborting as soon as output passes `limit` bytes. */
async function inflateBounded(raw: Uint8Array, limit: number, path: string): Promise<Uint8Array> {
  const stream = new Blob([raw as unknown as BlobPart]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
  const reader = stream.getReader();
  const out = new Uint8Array(limit);
  let length = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (length + value.length > limit) {
        await reader.cancel().catch(() => {});
        fail('too_large', `Member "${path}" expands beyond its declared size.`);
      }
      out.set(value, length);
      length += value.length;
    }
  } catch (err) {
    if (err instanceof HtmlBundleError) throw err;
    fail('malformed', `Member "${path}" could not be inflated.`);
  }
  return out.subarray(0, length);
}

export function parseManifest(bytes: Uint8Array): string {
  if (bytes.length > HTML_BUNDLE_LIMITS.manifestBytes) fail('malformed', `${HTML_BUNDLE_MANIFEST} is larger than 64 KiB.`);
  let value: unknown;
  try { value = JSON.parse(utf8Strict.decode(bytes)); } catch { fail('malformed', `${HTML_BUNDLE_MANIFEST} is not valid JSON.`); }
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail('malformed', `${HTML_BUNDLE_MANIFEST} must be a JSON object.`);
  const record = value as Record<string, unknown>;
  for (const key of Object.keys(record)) {
    if (key !== 'format_version' && key !== 'entrypoint') fail('malformed', `${HTML_BUNDLE_MANIFEST} has unsupported field "${key}".`);
  }
  if (record.format_version !== 1) fail('malformed', `${HTML_BUNDLE_MANIFEST} format_version must be 1.`);
  if (typeof record.entrypoint !== 'string' || !record.entrypoint) fail('malformed', `${HTML_BUNDLE_MANIFEST} needs a string entrypoint.`);
  return record.entrypoint;
}

/** Parse and fully validate a decrypted html-bundle archive, in memory. */
export async function readHtmlBundle(data: Uint8Array): Promise<HtmlBundle> {
  const members = parseZipDirectory(data);
  const files = new Map<string, Uint8Array>();
  let manifestEntry = '';
  let actualTotal = 0;
  for (const m of members) {
    if (m.isDir) continue;
    const raw = data.subarray(m.dataOffset, m.dataOffset + m.compressed);
    const bytes = m.method === 0 ? raw : await inflateBounded(raw, m.size, m.path);
    if (bytes.length !== m.size) fail('malformed', `Member "${m.path}" expands to ${bytes.length} bytes but declares ${m.size}.`);
    if (crc32(bytes) !== m.crc) fail('malformed', `Member "${m.path}" fails its CRC-32 check.`);
    actualTotal += bytes.length;
    if (actualTotal > HTML_BUNDLE_LIMITS.expandedBytes) fail('too_large', 'Archive expands past 50 MiB.');
    if (bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4b && bytes[2] === 3 && bytes[3] === 4) fail('unsafe', `Member "${m.path}" is a nested archive.`);
    if (m.path === HTML_BUNDLE_MANIFEST) {
      manifestEntry = parseManifest(bytes);
      continue;
    }
    files.set(m.path, bytes);
  }
  if (!manifestEntry) fail('malformed', `The archive has no ${HTML_BUNDLE_MANIFEST} manifest.`);
  if (!isHtmlPath(manifestEntry)) fail('missing_entry', `Entry "${manifestEntry}" is not an HTML page.`);
  if (!files.has(manifestEntry)) fail('missing_entry', `Entry page "${manifestEntry}" is missing from the bundle (paths are case-sensitive).`);
  const pages = [...files.keys()].filter(isHtmlPath).sort();
  return { entry: manifestEntry, pages, files };
}

// ── Reference resolution ─────────────────────────────────────────────────────

export type ResolvedRef =
  | { kind: 'local'; path: string; fragment: string }
  | { kind: 'fragment'; fragment: string }
  | { kind: 'data' }
  | { kind: 'external' }
  | { kind: 'invalid' };

function dirname(path: string): string {
  const slash = path.lastIndexOf('/');
  return slash < 0 ? '' : path.slice(0, slash);
}

/**
 * Resolve a reference found in `fromPath`. `/x` means the bundle root, never the
 * application; a scheme or `//` is external; `..` above the root is invalid.
 */
export function resolveBundleRef(ref: string, fromPath: string): ResolvedRef {
  // Browsers strip ASCII whitespace and control characters before parsing a URL scheme.
  const cleaned = ref.replace(/^[\x00-\x20]+|[\x00-\x20]+$/g, '');
  if (!cleaned) return { kind: 'invalid' };
  const schemeProbe = cleaned.replace(/[\t\n\r]/g, '');
  if (/^data:/i.test(schemeProbe)) return { kind: 'data' };
  if (/^[a-z][a-z0-9+.-]*:/i.test(schemeProbe) || schemeProbe.startsWith('//') || schemeProbe.startsWith('\\\\')) return { kind: 'external' };
  const hash = cleaned.indexOf('#');
  const fragment = hash >= 0 ? cleaned.slice(hash + 1) : '';
  let target = hash >= 0 ? cleaned.slice(0, hash) : cleaned;
  const query = target.indexOf('?');
  if (query >= 0) target = target.slice(0, query);
  if (!target) return { kind: 'fragment', fragment: safeDecode(fragment) };
  target = safeDecode(target);
  if (target.includes('\\')) return { kind: 'invalid' };
  const base = target.startsWith('/') ? [] : dirname(fromPath).split('/').filter(Boolean);
  for (const segment of target.split('/')) {
    if (segment === '' || segment === '.') continue;
    if (segment === '..') {
      if (base.length === 0) return { kind: 'invalid' };
      base.pop();
    } else {
      base.push(segment);
    }
  }
  if (base.length === 0) return { kind: 'invalid' };
  return { kind: 'local', path: base.join('/'), fragment: safeDecode(fragment) };
}

function safeDecode(value: string): string {
  try { return decodeURIComponent(value); } catch { return value; }
}

const MIME_BY_EXT: Record<string, string> = {
  css: 'text/css',
  png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp',
  avif: 'image/avif', bmp: 'image/bmp', ico: 'image/x-icon', svg: 'image/svg+xml',
  woff: 'font/woff', woff2: 'font/woff2', ttf: 'font/ttf', otf: 'font/otf', eot: 'application/vnd.ms-fontobject',
};

/** MIME for an image/font/stylesheet member, or '' for a type the preview does not load. */
export function bundleAssetMime(path: string): string {
  const dot = path.lastIndexOf('.');
  return dot < 0 ? '' : MIME_BY_EXT[path.slice(dot + 1).toLowerCase()] || '';
}

// ── Page compilation ─────────────────────────────────────────────────────────

export type CompiledPage = { html: string; missing: string[] };

export type BundleRendererDeps = {
  createObjectURL?: (blob: Blob) => string;
  revokeObjectURL?: (url: string) => void;
  parseHtml?: (html: string) => Document;
};

const REMOVED_ELEMENTS = 'script,iframe,frame,frameset,object,embed,applet,portal,base,meta[http-equiv],template,noembed';
// SVG SMIL animation runs without allow-scripts and can rewrite attributes after
// compilation, e.g. <set attributeName="href" to="https://…"> retargets a link to a
// remote page. Static bundles do not need it, so every animation element goes. Matched
// by lowercased localName: SVG type selectors are case-sensitive (animateMotion).
const REMOVED_SVG_ANIMATION = new Set(['animate', 'animatecolor', 'animatemotion', 'animatetransform', 'set', 'discard']);
const URL_ATTRS = ['href', 'src', 'srcset', 'poster', 'action', 'formaction', 'xlink:href', 'background', 'lowsrc', 'dynsrc', 'longdesc', 'ping', 'data', 'codebase', 'cite', 'manifest', 'icon'];
const CSS_URL_RE = /url\(\s*(?:"([^"]*)"|'([^']*)'|([^)"']*))\s*\)/gi;
const CSS_IMPORT_RE = /@import\s+(?:url\(\s*(?:"([^"]*)"|'([^']*)'|([^)"']*))\s*\)|"([^"]*)"|'([^']*)')\s*([^;]*);?/gi;
const MAX_IMPORT_DEPTH = 16;

/**
 * Compiles pages of one bundle to srcdoc HTML. Owns every blob: URL it creates;
 * dispose() revokes them all (close, version change, vault lock).
 */
export class HtmlBundleRenderer {
  private urls = new Map<string, string>();
  private pages = new Map<string, CompiledPage>();
  private disposed = false;
  private createObjectURL: (blob: Blob) => string;
  private revokeObjectURL: (url: string) => void;
  private parseHtml: (html: string) => Document;
  private bundle: HtmlBundle;

  constructor(bundle: HtmlBundle, deps: BundleRendererDeps = {}) {
    this.bundle = bundle;
    this.createObjectURL = deps.createObjectURL || ((blob) => URL.createObjectURL(blob));
    this.revokeObjectURL = deps.revokeObjectURL || ((url) => URL.revokeObjectURL(url));
    this.parseHtml = deps.parseHtml || ((html) => new DOMParser().parseFromString(html, 'text/html'));
  }

  get objectUrlCount(): number { return this.urls.size; }

  dispose(): void {
    this.disposed = true;
    for (const url of this.urls.values()) this.revokeObjectURL(url);
    this.urls.clear();
    this.pages.clear();
  }

  hasPage(path: string): boolean {
    return this.bundle.files.has(path) && isHtmlPath(path);
  }

  private assetUrl(path: string, missing: Set<string>): string {
    if (this.disposed) return '';
    const cached = this.urls.get(path);
    if (cached) return cached;
    const bytes = this.bundle.files.get(path);
    const mime = bundleAssetMime(path);
    if (!bytes || !mime || mime === 'text/css') {
      missing.add(path);
      return '';
    }
    const url = this.createObjectURL(new Blob([bytes as unknown as BlobPart], { type: mime }));
    this.urls.set(path, url);
    return url;
  }

  private rewriteCssUrls(css: string, fromPath: string, missing: Set<string>): string {
    return css.replace(CSS_URL_RE, (_m, dq, sq, bare) => {
      const ref = String(dq ?? sq ?? bare ?? '').trim();
      const resolved = resolveBundleRef(ref, fromPath);
      if (resolved.kind === 'data' && /^data:(image|font)\//i.test(ref)) return `url("${ref.replace(/"/g, '%22')}")`;
      if (resolved.kind === 'fragment') return `url("#${resolved.fragment.replace(/"/g, '%22')}")`;
      if (resolved.kind !== 'local') {
        if (resolved.kind === 'external' || resolved.kind === 'invalid') missing.add(ref);
        return 'url("")';
      }
      const url = this.assetUrl(resolved.path, missing);
      return url ? `url("${url}${resolved.fragment ? `#${encodeURIComponent(resolved.fragment)}` : ''}")` : 'url("")';
    });
  }

  /** Compile CSS from `fromPath`, inlining local @import recursively. */
  compileCss(css: string, fromPath: string, missing: Set<string>, seen: string[] = []): string {
    // Imports are swapped for placeholders first so that url() rewriting applies to this
    // file only: inlined stylesheets are already compiled (their url()s hold blob: URLs,
    // which a second pass would treat as external and drop).
    const inlined: string[] = [];
    const withPlaceholders = css.replace(CSS_IMPORT_RE, (_m, u1, u2, u3, s1, s2, media) => {
      const ref = String(u1 ?? u2 ?? u3 ?? s1 ?? s2 ?? '').trim();
      const resolved = resolveBundleRef(ref, fromPath);
      let inner = '';
      if (resolved.kind !== 'local') {
        missing.add(ref);
      } else {
        const bytes = this.bundle.files.get(resolved.path);
        if (!bytes || bundleAssetMime(resolved.path) !== 'text/css') {
          missing.add(resolved.path);
        } else if (!seen.includes(resolved.path) && seen.length < MAX_IMPORT_DEPTH) {
          inner = this.compileCss(new TextDecoder().decode(bytes), resolved.path, missing, [...seen, resolved.path]);
          const mediaText = String(media || '').trim();
          if (mediaText) inner = `@media ${mediaText} {\n${inner}\n}`;
        }
      }
      inlined.push(inner);
      return `/*hb-import-${inlined.length - 1}*/`;
    });
    return this.rewriteCssUrls(withPlaceholders, fromPath, missing)
      .replace(/\/\*hb-import-(\d+)\*\//g, (_m, index) => inlined[Number(index)] ?? '');
  }

  private rewriteSrcset(value: string, page: string, missing: Set<string>): string {
    return value.split(',').map((candidate) => {
      const parts = candidate.trim().split(/\s+/);
      const resolved = resolveBundleRef(parts[0] || '', page);
      if (resolved.kind !== 'local') {
        if (parts[0]) missing.add(parts[0]);
        return '';
      }
      const url = this.assetUrl(resolved.path, missing);
      return url ? [url, ...parts.slice(1)].join(' ') : '';
    }).filter(Boolean).join(', ');
  }

  compilePage(page: string): CompiledPage {
    const cached = this.pages.get(page);
    if (cached) return cached;
    const bytes = this.bundle.files.get(page);
    if (!bytes || !isHtmlPath(page)) throw new HtmlBundleError('missing_entry', `Page "${page}" is not in the bundle.`);
    const missing = new Set<string>();
    const doc = this.parseHtml(new TextDecoder().decode(bytes));

    doc.querySelectorAll(REMOVED_ELEMENTS).forEach((el) => el.remove());
    for (const el of Array.from(doc.getElementsByTagName('*'))) {
      if (REMOVED_SVG_ANIMATION.has(el.localName.toLowerCase())) el.remove();
    }
    doc.querySelectorAll('form').forEach((form) => {
      const div = doc.createElement('div');
      while (form.firstChild) div.appendChild(form.firstChild);
      for (const attr of Array.from(form.attributes)) if (attr.name === 'class' || attr.name === 'id' || attr.name === 'style') div.setAttribute(attr.name, attr.value);
      form.replaceWith(div);
    });
    // Authored <style> first: stylesheets inlined from <link> below are already compiled.
    doc.querySelectorAll('style').forEach((style) => {
      style.textContent = this.compileCss(style.textContent || '', page, missing);
    });
    doc.querySelectorAll('link').forEach((link) => {
      const rel = (link.getAttribute('rel') || '').toLowerCase().split(/\s+/);
      const href = link.getAttribute('href') || '';
      if (rel.includes('stylesheet') && !rel.includes('alternate')) {
        const resolved = resolveBundleRef(href, page);
        const css = resolved.kind === 'local' && bundleAssetMime(resolved.path) === 'text/css' ? this.bundle.files.get(resolved.path) : undefined;
        if (resolved.kind === 'local' && css) {
          const style = doc.createElement('style');
          const media = link.getAttribute('media');
          style.textContent = this.compileCss(new TextDecoder().decode(css), resolved.path, missing, [resolved.path]);
          if (media) style.setAttribute('media', media);
          link.replaceWith(style);
          return;
        }
        missing.add(resolved.kind === 'local' ? resolved.path : href);
      }
      link.remove();
    });

    for (const el of Array.from(doc.querySelectorAll('*'))) {
      for (const attr of Array.from(el.attributes)) {
        const name = attr.name.toLowerCase();
        if (name.startsWith('on') || name.startsWith('data-hb-') || name === 'srcdoc' || name === 'target' || name === 'formtarget' || name === 'download' || name === 'http-equiv' || name === 'is') {
          el.removeAttribute(attr.name);
        }
      }
      if (el.hasAttribute('style')) el.setAttribute('style', this.compileCss(el.getAttribute('style') || '', page, missing));
      const tag = el.tagName.toLowerCase();
      for (const name of URL_ATTRS) {
        if (!el.hasAttribute(name)) continue;
        const value = el.getAttribute(name) || '';
        if ((tag === 'a' || tag === 'area') && name === 'href') {
          this.rewriteLink(el, value, page, missing);
        } else if (name === 'srcset') {
          el.setAttribute('srcset', this.rewriteSrcset(value, page, missing));
        } else if (name === 'src' || name === 'poster' || ((tag === 'image' || tag === 'use' || tag === 'feimage') && (name === 'href' || name === 'xlink:href'))) {
          const resolved = resolveBundleRef(value, page);
          if (resolved.kind === 'data' && /^data:(image|font)\//i.test(value.trim())) continue;
          if (resolved.kind === 'fragment' && (tag === 'use')) continue;
          const url = resolved.kind === 'local' ? this.assetUrl(resolved.path, missing) : '';
          if (resolved.kind !== 'local' && value.trim()) missing.add(value.trim());
          if (url) el.setAttribute(name, url + (resolved.kind === 'local' && resolved.fragment ? `#${encodeURIComponent(resolved.fragment)}` : ''));
          else el.removeAttribute(name);
        } else {
          el.removeAttribute(name);
        }
      }
    }

    const head = doc.head || doc.documentElement.insertBefore(doc.createElement('head'), doc.body);
    const csp = doc.createElement('meta');
    csp.setAttribute('http-equiv', 'Content-Security-Policy');
    csp.setAttribute('content', HTML_BUNDLE_CSP);
    head.insertBefore(csp, head.firstChild);
    if (!doc.querySelector('meta[charset]')) {
      const charset = doc.createElement('meta');
      charset.setAttribute('charset', 'utf-8');
      head.insertBefore(charset, head.firstChild);
    }

    const compiled = { html: `<!doctype html>\n${doc.documentElement.outerHTML}`, missing: [...missing].sort() };
    this.pages.set(page, compiled);
    return compiled;
  }

  private rewriteLink(el: Element, value: string, page: string, missing: Set<string>): void {
    const resolved = resolveBundleRef(value, page);
    if (resolved.kind === 'fragment') {
      el.setAttribute('href', `about:srcdoc#${encodeURIComponent(resolved.fragment)}`);
      return;
    }
    if (resolved.kind === 'local' && this.hasPage(resolved.path)) {
      el.setAttribute('href', `about:srcdoc#${encodeURIComponent(resolved.fragment)}`);
      el.setAttribute('data-hb-page', resolved.path);
      if (resolved.fragment) el.setAttribute('data-hb-fragment', resolved.fragment);
      else el.removeAttribute('data-hb-fragment');
      return;
    }
    if (resolved.kind === 'local' && isHtmlPath(resolved.path)) missing.add(resolved.path);
    el.removeAttribute('href');
    el.setAttribute('data-hb-unavailable', resolved.kind === 'external' ? 'external' : 'local');
    el.setAttribute('title', resolved.kind === 'external' ? `External link not available in preview: ${value}` : 'Not available in preview');
  }
}
