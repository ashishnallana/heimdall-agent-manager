#!/usr/bin/env node
// preview-server.mjs — serves a BUILT renderer bundle for a Heimdall shell-session
// preview, with `/api/v1` proxied to a `ham-dev-proxy`.
//
// Why this exists
// ---------------
// A shell session started with `--kind server --port N` is reachable only under a
// path prefix the app never sees:
//
//     https://<hub>/api/v1/preview/<session_id>/<path>          (what the user opens)
//     http://127.0.0.1:<local_endpoint_port>/proxy/<sid>/<path> (the same, locally)
//
// The bridge strips that prefix before dialling 127.0.0.1:N, so this server sees
// plain paths — but the BROWSER does not: anything the page requests at an absolute
// path is requested without the prefix and never reaches here. Hence two rules,
// and the build must satisfy both:
//   * assets  — `base: './'` in vite.config.js already makes them relative;
//   * the API — build with `VITE_API_BASE=.` so `/api/v1/...` becomes
//     document-relative too (see src/ui/api/apiBase.ts).
// With both, every request the page makes arrives here under the prefix, and this
// server answers files from `dist/` and forwards `/api/v1` upstream.
//
// AUTH IS NOT WEAKENED. This process injects no identity. Users authenticate only
// with OIDC: `ham-dev-proxy` signs in on the dev user's behalf (locally against
// tools/mock-oidc) and attaches the hub session after this hop, exactly as in
// `npm run dev`; the preview relay strips hub cookies, so the browser never holds
// one. The one thing changed here is the Origin: the preview origin is forwarded
// as this server's loopback origin so the proxy trusts it (scripts/lib/preview-origin.mjs);
// any other Origin passes unchanged. Legacy `X-authentik-*` headers mean nothing to
// the hub any more; they are still stripped here so nothing pretends otherwise.
//
// Usage:
//   HEIMDALL_PREVIEW_PORT=45180 \
//   HEIMDALL_PREVIEW_UPSTREAM=http://127.0.0.1:8110 \
//   [HEIMDALL_PREVIEW_URL=<preview_url> | HEIMDALL_PREVIEW_URL_FILE=<path>] [HAM_CTL=ham-ctl] \
//   node scripts/preview-server.mjs [--dir dist]
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createPreviewOriginGate } from './lib/preview-origin.mjs';

const ROOT = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const PORT = Number(process.env.HEIMDALL_PREVIEW_PORT || 45180);
const UPSTREAM = new URL(process.env.HEIMDALL_PREVIEW_UPSTREAM || 'http://127.0.0.1:8110');
const dirArg = process.argv.indexOf('--dir');
const DIST = path.resolve(ROOT, dirArg > -1 ? process.argv[dirArg + 1] : 'dist');
const originGate = createPreviewOriginGate({
  port: PORT,
  previewUrl: process.env.HEIMDALL_PREVIEW_URL || process.env.HEIMDALL_PREVIEW_ORIGIN || '',
  previewUrlFile: process.env.HEIMDALL_PREVIEW_URL_FILE || '',
  hamCtl: [process.env.HAM_CTL, 'ham-ctl'],
});

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.map': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
};

if (!fs.existsSync(path.join(DIST, 'index.html'))) {
  console.error(`[preview] no bundle at ${DIST}/index.html — run: VITE_API_BASE=. npm run build`);
  process.exit(1);
}

/**
 * Log every request, not only the API ones.
 *
 * The usual way a preview breaks is silent: the page requests an ABSOLUTE path, the
 * `/proxy/<sid>/` prefix is lost, and nothing ever reaches here. The log in
 * `ham-ctl shell log <sid>` is what distinguishes "the API is down" from "the browser
 * never asked us" — which only works if static requests are logged too. They were not,
 * and that is part of why the bare-URL trap below went unnoticed.
 */
function logRequest(req, res) {
  const startedAt = Date.now();
  res.on('finish', () => {
    console.log(`[preview] ${req.method} ${new URL(req.url, 'http://local').pathname} -> ${res.statusCode} (${Date.now() - startedAt}ms)`);
  });
}

/** Forward `/api/v1/...` (and the dev login endpoints) to ham-dev-proxy. */
function proxyApi(req, res) {
  const headers = {};
  for (const [key, value] of Object.entries(req.headers)) {
    const lower = key.toLowerCase();
    // Legacy identity headers are dropped (the hub ignores them; identity is the
    // session cookie).
    if (lower.startsWith('x-authentik')) continue;
    if (lower === 'host' || lower === 'connection') continue;
    headers[key] = value;
  }
  headers.host = UPSTREAM.host;
  originGate.rewrite(headers);

  const upstreamReq = http.request(
    {
      protocol: UPSTREAM.protocol,
      hostname: UPSTREAM.hostname,
      port: UPSTREAM.port,
      method: req.method,
      path: req.url,
      headers,
    },
    (upstreamRes) => {
      res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
      upstreamRes.pipe(res);
    },
  );
  upstreamReq.on('error', (err) => {
    res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: { code: 'upstream_unreachable', message: String(err.message || err) } }));
  });
  req.pipe(upstreamReq);
}

// Two URL traps the preview prefix creates, and why the fix is a script not a 301.
// ------------------------------------------------------------------------------
// 1. TRAILING SLASH. `/proxy/<sid>` is not equivalent to `/proxy/<sid>/`: with
//    `VITE_API_BASE=.` every API call is document-relative, so the bare form resolves
//    them one level up to `/proxy/api/v1/...`, which 404s. The page still paints —
//    the user gets a loaded-looking UI with no data and nothing naming the cause.
// 2. EMPTY HASH. Routing is hash-based, but with no hash `getRoutePathname()` falls
//    back to `window.location.pathname` (src/ui/utils/appLocation.ts:23-29). That
//    fallback is right for `npm run dev` and for Electron's `file://` load, where the
//    pathname IS a route-ish `/`. Under the prefix it is `/proxy/<sid>/`, which
//    matches no route, so the entry URL lands on "This route is not part of the v1
//    shell map" — again a loaded-looking page that reads as a broken preview.
//
// Neither can be fixed with a redirect here. The bridge normalises the bare form to
// "/" BEFORE forwarding (src/bridge/local_proxy.odin:117-124, pinned by the test
// `bridge_proxy_parse_bare_session_root_path`), so both spellings arrive as the
// byte-identical request `GET /`; and the hash is never sent to a server at all.
// The browser is the only hop that knows either, so the guard runs there: an inline
// classic script, first in <head>, before the deferred module scripts evaluate and
// therefore before any route is derived or any API call made.
//
// The two corrections must use DIFFERENT mechanisms, and this is not a style choice.
// A wrong pathname needs a real navigation, so it is `location.replace`. A missing
// hash must NOT be: calling `location.replace` for a fragment-only change while the
// document is still parsing aborts the in-flight load in Firefox and leaves a blank
// page — observed, not theorised. `history.replaceState` rewrites the URL without
// navigating, so parsing continues and the app boots reading the corrected hash.
// When both are wrong the single navigation carries the hash with it.
// Both branches are idempotent, and an existing deep link's hash is preserved.
const SLASH_GUARD =
  '<script data-heimdall-preview-guard>(function(){' +
  'var p=location.pathname,q=location.search,h=location.hash;' +
  'var g=!h||h==="#";' +
  'if(p.charAt(p.length-1)!=="/"){location.replace(p+"/"+q+(g?"#/":h));}' +
  'else if(g&&history.replaceState){history.replaceState(null,"",p+q+"#/");}' +
  '})();</script>';

/** index.html with the guard injected. Read per request — the bundle is rebuilt in place. */
function serveIndex(res, status = 200) {
  fs.readFile(path.join(DIST, 'index.html'), 'utf8', (err, html) => {
    if (err) {
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      res.end('no bundle');
      return;
    }
    const injected = html.includes('<head>')
      ? html.replace('<head>', `<head>${SLASH_GUARD}`)
      : SLASH_GUARD + html;
    const body = Buffer.from(injected, 'utf8');
    res.writeHead(status, {
      'Content-Type': MIME['.html'],
      'Cache-Control': 'no-store',
      'Content-Length': body.length,
    });
    res.end(body);
  });
}

function serveFile(res, filePath, status = 200) {
  const ext = path.extname(filePath).toLowerCase();
  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('not found');
      return;
    }
    res.writeHead(status, {
      'Content-Type': MIME[ext] || 'application/octet-stream',
      // The preview is rebuilt in place; a cached bundle would hide the rebuild.
      'Cache-Control': 'no-store',
      'Content-Length': data.length,
    });
    res.end(data);
  });
}

const server = http.createServer((req, res) => {
  logRequest(req, res);
  const url = new URL(req.url || '/', 'http://127.0.0.1');
  const pathname = decodeURIComponent(url.pathname);

  if (pathname.startsWith('/api/v1') || pathname.startsWith('/_dev/')) {
    proxyApi(req, res);
    return;
  }

  // Everything else is a file in the bundle. Routing is hash-based, so a path that
  // is not a file is the app's entry point rather than a 404.
  const relative = pathname.replace(/^\/+/, '') || 'index.html';
  const resolved = path.resolve(DIST, relative);
  if (!resolved.startsWith(DIST)) {
    res.writeHead(403, { 'Content-Type': 'text/plain' });
    res.end('forbidden');
    return;
  }
  fs.stat(resolved, (err, stat) => {
    if (!err && stat.isFile() && relative !== 'index.html') serveFile(res, resolved);
    else serveIndex(res);
  });
});

// The renderer opens one user WebSocket for live invalidation events. Tunnel the
// upgrade through to ham-dev-proxy so the preview gets live updates too; if the
// hop in front of us cannot carry an upgrade the socket simply fails and the app
// falls back to its reconnect/refetch path, which is why this is best-effort.
server.on('upgrade', (req, clientSocket, head) => {
  const headers = { ...req.headers, host: UPSTREAM.host };
  for (const key of Object.keys(headers)) {
    if (key.toLowerCase().startsWith('x-authentik')) delete headers[key];
  }
  originGate.rewrite(headers);
  const upstreamReq = http.request({
    protocol: UPSTREAM.protocol,
    hostname: UPSTREAM.hostname,
    port: UPSTREAM.port,
    method: req.method,
    path: req.url,
    headers,
  });
  upstreamReq.on('upgrade', (upstreamRes, upstreamSocket, upstreamHead) => {
    const statusLine = Object.entries(upstreamRes.headers)
      .map(([k, v]) => `${k}: ${Array.isArray(v) ? v.join(', ') : v}`)
      .join('\r\n');
    clientSocket.write(`HTTP/1.1 101 Switching Protocols\r\n${statusLine}\r\n\r\n`);
    if (upstreamHead?.length) clientSocket.write(upstreamHead);
    if (head?.length) upstreamSocket.write(head);
    console.log(`[preview] WS ${new URL(req.url, 'http://local').pathname} -> 101`);
    upstreamSocket.pipe(clientSocket).pipe(upstreamSocket);
    upstreamSocket.on('error', () => clientSocket.destroy());
    clientSocket.on('error', () => upstreamSocket.destroy());
  });
  upstreamReq.on('response', (upstreamRes) => {
    // Upstream declined the upgrade (auth, wrong path). Pass the refusal on.
    console.log(`[preview] WS ${new URL(req.url, 'http://local').pathname} -> ${upstreamRes.statusCode} (no upgrade)`);
    clientSocket.end(`HTTP/1.1 ${upstreamRes.statusCode} ${upstreamRes.statusMessage}\r\n\r\n`);
  });
  upstreamReq.on('error', () => clientSocket.destroy());
  upstreamReq.end();
});

// The bridge dials 127.0.0.1 on this host; there is no reason to listen wider.
server.listen(PORT, '127.0.0.1', () => {
  console.log(`[preview] serving ${DIST} on http://127.0.0.1:${PORT} (api → ${UPSTREAM.origin})`);
});
