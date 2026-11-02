#!/usr/bin/env node
// dev-preview.mjs — runs a live Vite dev server with instant HMR inside a
// Heimdall shell session preview tunnel (/api/v1/preview/<session_id>/).
//
// Architecture
// ------------
// 1. Declared session port (PORT, default 5173):
//    A lightweight Node reverse proxy accepts incoming HTTP and WebSocket requests
//    forwarded by the Hub preview tunnel (where /api/v1/preview/<session_id> was stripped).
//    It re-adds the prefix and forwards to internal Vite, and injects the hash routing
//    slash guard into HTML responses.
// 2. Internal Vite dev server (VITE_PORT, default 5174):
//    Runs standard `vite` with `--base /api/v1/preview/<session_id>/`.
//    This guarantees that all module URLs (/@vite/client, /src/ui/main.tsx, dynamic chunks)
//    and the WebSocket HMR endpoint carry the preview tunnel prefix in browser requests.
// 3. Hot Module Replacement (HMR):
//    The reverse proxy forwards WebSocket upgrade requests to Vite on VITE_PORT, enabling
//    real-time live reload and state-preserving React Fast Refresh across the tunnel.

import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';
import { spawn, execSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createPreviewOriginGate } from './lib/preview-origin.mjs';

function argValue(name, fallback = '') {
  const idx = process.argv.indexOf(name);
  if (idx >= 0 && idx + 1 < process.argv.length) return process.argv[idx + 1];
  return fallback;
}

// Directory the script was invoked from is assumed to be the target project/repo to watch
const ROOT = path.resolve(argValue('--root', process.env.HEIMDALL_ROOT || process.cwd()));

const PORT = Number(argValue('--port', process.env.HEIMDALL_PREVIEW_PORT || '5173'));
const VITE_PORT = Number(argValue('--vite-port', process.env.HEIMDALL_VITE_PORT || '5174'));
let sessionId = argValue('--session-id', process.env.HEIMDALL_PREVIEW_SESSION_ID || '');
const UPSTREAM = new URL(argValue('--upstream', process.env.HEIMDALL_PREVIEW_UPSTREAM || 'http://127.0.0.1:8080'));

/** Forward `/api/v1/...` and `/_dev/...` to local ham-dev-proxy (127.0.0.1:8080). */
function proxyApi(req, res, targetPath) {
  const headers = {};
  for (const [key, value] of Object.entries(req.headers)) {
    const lower = key.toLowerCase();
    if (lower.startsWith('x-authentik')) continue; // legacy identity headers: never relayed (the hub uses its session cookie)
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
      path: targetPath,
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

// Two URL traps the preview prefix creates (from preview-server.mjs / ham-ctl-reference):
// 1. TRAILING SLASH: /api/v1/preview/<sid> must have trailing slash. A path whose last
//    segment has a file extension (e.g. the dev-only composer-demo.html) is left
//    alone entirely: a slash would make Vite's SPA fallback serve index.html instead.
// 2. EMPTY HASH: Routing is hash-based; with no hash getRoutePathname() falls back to
//    window.location.pathname (/api/v1/preview/<sid>/) which matches no route.
//    history.replaceState seeds #/ without aborting module parsing in the browser.
const SLASH_GUARD =
  '<script data-heimdall-preview-guard>(function(){' +
  'var p=location.pathname,q=location.search,h=location.hash;' +
  'var g=!h||h==="#";' +
  'if(/\\.[a-z0-9]+$/i.test(p)){}' +
  'else if(p.charAt(p.length-1)!=="/"){location.replace(p+"/"+q+(g?"#/":h));}' +
  'else if(g&&history.replaceState){history.replaceState(null,"",p+q+"#/");}' +
  '})();</script>';

/** Log static and module requests for diagnostics */
function logRequest(req, res, targetUrl) {
  const startedAt = Date.now();
  res.on('finish', () => {
    console.log(`[dev-preview] ${req.method} ${req.url} -> Vite ${targetUrl} -> ${res.statusCode} (${Date.now() - startedAt}ms)`);
  });
}

// The Hub serves previews under one of two shapes, and which one is live is the
// Hub's choice, not ours (see the heimdall-preview-setup skill):
//   preview-origin mode : <preview_origin>/p/<sid>/
//   legacy mode         : <ui_origin>/api/v1/preview/<sid>/
// Vite's --base must match the shape the BROWSER actually loads, because every
// module URL it emits is absolute. Hardcoding the legacy shape on a Hub running
// preview-origin mode makes the document load from /p/<sid>/ while its scripts
// point at /api/v1/preview/<sid>/ — which that origin does not serve, so the
// whole module graph 404s (e.g. GET .../@react-refresh -> 404). So: read the
// session's real preview_url and take its path.
let discoveredPrefix = '';
let discoveredPreviewUrl = '';

function hamCtlBins() {
  return [
    argValue('--ham-ctl'),
    process.env.HAM_CTL,
    'ham-ctl',
    path.join(process.env.HOME || '', '.nix-profile/bin/ham-ctl'),
  ].filter(Boolean);
}

/** Find this session's ID from ham-ctl shell list or state file */
function discoverSessionId(port) {
  // dev-preview.sh records the session (and, just before it, its preview_url) as
  // soon as `shell start` returns, which can be before `shell list` reports it as
  // running. Take the preview_url with it: without it Vite falls back to the legacy
  // prefix, which a preview-origin Hub does not serve.
  let stateSid = '';
  try {
    const sid = fs.readFileSync(path.join(ROOT, '.dev-preview-session'), 'utf8').trim();
    if (sid.startsWith('sh_')) stateSid = sid;
  } catch {}
  if (stateSid) {
    try {
      const url = fs.readFileSync(path.join(ROOT, '.dev-preview-url'), 'utf8').trim();
      if (url) {
        discoveredPrefix = previewPathFrom(url);
        discoveredPreviewUrl = url;
        return stateSid;
      }
    } catch {}
  }

  const bridgeFlag = process.env.HEIMDALL_BRIDGE_ID ? ` --bridge ${process.env.HEIMDALL_BRIDGE_ID}` : '';
  for (const bin of hamCtlBins()) {
    try {
      const out = execSync(`${bin} shell list${bridgeFlag} --status running`, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'], timeout: 3000 });
      const data = JSON.parse(out);
      const sessions = data?.data?.data?.sessions || data?.data?.sessions || [];
      const match = sessions.find((s) => (stateSid ? s.session_id === stateSid : s.server_port === port) && s.status === 'running');
      if (match && match.session_id) {
        discoveredPrefix = previewPathFrom(match.preview_url);
        discoveredPreviewUrl = match.preview_url || '';
        return match.session_id;
      }
    } catch {}
  }
  return stateSid;
}

/** Path component of a preview_url, normalised to a trailing slash. */
function previewPathFrom(previewUrl) {
  if (!previewUrl) return '';
  try {
    const p = new URL(previewUrl).pathname || '';
    if (!p || p === '/') return '';
    return p.endsWith('/') ? p : `${p}/`;
  } catch {
    return '';
  }
}

/** The prefix the browser loads under. Explicit flag > discovered > legacy. */
function resolveBasePrefix(sid) {
  const explicit = previewPathFrom(argValue('--preview-url', process.env.HEIMDALL_PREVIEW_URL || ''));
  if (explicit) return explicit;
  if (discoveredPrefix) return discoveredPrefix;
  return sid ? `/api/v1/preview/${sid}/` : '/';
}

let viteProcess = null;
let viteReady = false;
let pendingRequests = [];

function startVite(sid) {
  const base = basePrefix || '/';
  // Use the concrete browser prefix for HTTP API calls. A document-relative
  // `./api/v1/...` works in Chromium, but WebKit can reject it with
  // "The string did not match the expected pattern" after the OIDC sign-in
  // redirect restores a hash route. The absolute path remains same-origin and
  // still traverses this preview proxy, while avoiding browser-dependent URL
  // resolution during the session bootstrap request.
  const apiBase = base === '/' ? '' : base.replace(/\/$/, '');
  console.log(`[dev-preview] launching internal Vite on 127.0.0.1:${VITE_PORT} with base: ${base}`);

  const args = [
    'vite',
    '--port', String(VITE_PORT),
    '--host', '127.0.0.1',
    '--base', base,
    '--strictPort',
  ];

  viteProcess = spawn('npx', args, {
    cwd: ROOT,
    stdio: ['inherit', 'pipe', 'pipe'],
    env: {
      ...process.env,
      VITE_API_BASE: process.env.VITE_API_BASE ?? apiBase,
      VITE_BASE_API: process.env.VITE_BASE_API ?? apiBase,
      // index.html interpolates these; nothing reads them in dev, but leaving
      // them undefined makes Vite warn on every HTML request (30+ lines of
      // "%VITE_HEIMDALL_LOGIN_URL% is not defined" noise per page load).
      VITE_HEIMDALL_LOGIN_URL: process.env.VITE_HEIMDALL_LOGIN_URL ?? '',
      VITE_HEIMDALL_LOGOUT_URL: process.env.VITE_HEIMDALL_LOGOUT_URL ?? '',
      FORCE_COLOR: '1',
    },
  });

  viteProcess.stdout.on('data', (chunk) => {
    const text = chunk.toString();
    process.stdout.write(`[vite] ${text}`);
    if (text.includes('ready in') || text.includes('Local:')) {
      viteReady = true;
      flushPending();
    }
  });

  viteProcess.stderr.on('data', (chunk) => {
    process.stderr.write(`[vite-err] ${chunk.toString()}`);
  });

  viteProcess.on('exit', (code, signal) => {
    console.log(`[dev-preview] Vite exited with code ${code} signal ${signal}`);
    process.exit(code || 0);
  });
}

function flushPending() {
  while (pendingRequests.length > 0) {
    const fn = pendingRequests.shift();
    try { fn(); } catch {}
  }
}

// Persistent HTTP agent for upstream requests to Vite, enabling TCP connection pooling
const upstreamAgent = new http.Agent({
  keepAlive: true,
  maxSockets: 100,
  maxFreeSockets: 20,
  timeout: 60000,
});

// Clean shutdown on signals
function cleanup() {
  upstreamAgent.destroy();
  if (viteProcess) {
    try { viteProcess.kill('SIGTERM'); } catch {}
  }
  process.exit(0);
}
process.on('SIGINT', cleanup);
process.on('SIGTERM', cleanup);

// Attempt discovery if sessionId was not passed explicitly
if (!sessionId) {
  for (let attempt = 0; attempt < 10; attempt++) {
    sessionId = discoverSessionId(PORT);
    if (sessionId) {
      console.log(`[dev-preview] discovered session ID: ${sessionId}`);
      break;
    }
    // Synchronous sleep 400ms
    try {
      const waitTill = new Date(new Date().getTime() + 400);
      while (waitTill > new Date()) {}
    } catch {}
  }
  if (!sessionId) {
    console.warn(`[dev-preview] warning: could not determine session ID for port ${PORT}, starting Vite with base /`);
  }
}

const basePrefix = resolveBasePrefix(sessionId);
// Legacy shape is still accepted on the way IN, so a client that was handed the
// old URL keeps working even when Vite is based on the preview-origin shape.
const legacyPrefix = sessionId ? `/api/v1/preview/${sessionId}` : '';
const prefixesIn = [basePrefix.replace(/\/$/, ''), legacyPrefix].filter(Boolean);
console.log(`[dev-preview] browser base prefix: ${basePrefix}`);

// The page's API calls carry Origin: <preview origin>; vouch for it so ham-dev-proxy
// attaches its brokered hub session (see scripts/lib/preview-origin.mjs).
const originGate = createPreviewOriginGate({
  port: PORT,
  previewUrl: argValue('--preview-url', process.env.HEIMDALL_PREVIEW_URL || process.env.HEIMDALL_PREVIEW_ORIGIN || discoveredPreviewUrl),
  previewUrlFile: path.join(ROOT, '.dev-preview-url'),
  hamCtl: hamCtlBins(),
});

/** Strip whichever known preview prefix the request arrived with. */
function stripPrefix(urlPath) {
  for (const p of prefixesIn) {
    if (urlPath === p) return '/';
    if (urlPath.startsWith(p + '/')) return urlPath.slice(p.length) || '/';
  }
  return urlPath;
}

startVite(sessionId);

// Start the reverse proxy server on PORT
const server = http.createServer((req, res) => {
  const handler = () => {
    let targetPath = req.url || '/';
    const cleanPath = stripPrefix(targetPath);

    // Forward API and dev-auth routes directly to the local ham-dev-proxy
    if (cleanPath.startsWith('/api/v1/') || cleanPath.startsWith('/_dev/')) {
      proxyApi(req, res, cleanPath);
      return;
    }

    // Re-express every request in the prefix Vite is based on, whichever
    // prefix (or none) it arrived with.
    targetPath = basePrefix.replace(/\/$/, '') + (cleanPath.startsWith('/') ? cleanPath : '/' + cleanPath);

    logRequest(req, res, targetPath);

    const headers = { ...req.headers };
    headers.host = `127.0.0.1:${VITE_PORT}`;
    // Strip incoming 'connection: close' so upstreamAgent can maintain persistent TCP keep-alive sockets to Vite
    delete headers.connection;

    const upstreamReq = http.request(
      {
        hostname: '127.0.0.1',
        port: VITE_PORT,
        method: req.method,
        path: targetPath,
        headers,
        agent: upstreamAgent,
      },
      (upstreamRes) => {
        const contentType = upstreamRes.headers['content-type'] || '';
        const isHtml = contentType.toLowerCase().includes('text/html');

        if (isHtml) {
          // Buffer HTML to inject the slash guard
          const chunks = [];
          upstreamRes.on('data', (c) => chunks.push(c));
          upstreamRes.on('end', () => {
            const raw = Buffer.concat(chunks).toString('utf8');
            const injected = raw.includes('<head>')
              ? raw.replace('<head>', `<head>${SLASH_GUARD}`)
              : SLASH_GUARD + raw;
            const body = Buffer.from(injected, 'utf8');

            const outHeaders = { ...upstreamRes.headers };
            delete outHeaders['content-length'];
            delete outHeaders['transfer-encoding'];
            outHeaders['content-length'] = body.length;
            outHeaders['cache-control'] = 'no-store';
            outHeaders['connection'] = 'close';

            res.writeHead(upstreamRes.statusCode || 200, outHeaders);
            res.end(body);
          });
        } else {
          // Non-HTML assets (JS, CSS, images, maps) stream directly.
          // Preserve ETag and allow conditional 304 caching (via cache-control: no-cache)
          // while ensuring HMR remains live.
          const outHeaders = { ...upstreamRes.headers };
          const upstreamCache = upstreamRes.headers['cache-control'];
          outHeaders['cache-control'] = upstreamCache && upstreamCache !== 'no-store' ? upstreamCache : 'no-cache';
          outHeaders['connection'] = 'close';

          res.writeHead(upstreamRes.statusCode || 200, outHeaders);
          upstreamRes.pipe(res);
        }
      }
    );

    upstreamReq.on('error', (err) => {
      console.error(`[dev-preview] upstream error: ${err.message}`);
      if (!res.headersSent) {
        res.writeHead(502, { 'content-type': 'text/plain' });
      }
      res.end(`dev preview upstream error: ${err.message}\n`);
    });

    req.pipe(upstreamReq);
  };

  if (viteReady) {
    handler();
  } else {
    pendingRequests.push(handler);
  }
});

// Relay WebSocket upgrades (API WebSockets to ham-dev-proxy, HMR to Vite)
server.on('upgrade', (req, clientSocket, head) => {
  let targetPath = req.url || '/';
  const cleanPath = stripPrefix(targetPath);

  // Forward API WebSockets (e.g. /api/v1/user-ws, /api/v1/lsp/, /api/v1/shells/.../stream) to ham-dev-proxy (8080)
  if (cleanPath.startsWith('/api/v1/')) {
    console.log(`[dev-preview-ws] Proxying API WebSocket upgrade to ham-dev-proxy: ${cleanPath}`);
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
      path: cleanPath,
      headers,
    });
    upstreamReq.on('upgrade', (upstreamRes, upstreamSocket, upstreamHead) => {
      console.log(`[dev-preview-ws] Upstream WebSocket upgrade 101 Switching Protocols received for ${cleanPath}`);
      const statusLine = Object.entries(upstreamRes.headers)
        .map(([k, v]) => `${k}: ${Array.isArray(v) ? v.join(', ') : v}`)
        .join('\r\n');
      clientSocket.write(`HTTP/1.1 101 Switching Protocols\r\n${statusLine}\r\n\r\n`);
      if (upstreamHead?.length) clientSocket.write(upstreamHead);
      if (head?.length) upstreamSocket.write(head);
      upstreamSocket.pipe(clientSocket);
      clientSocket.pipe(upstreamSocket);

      upstreamSocket.on('close', (hadError) => {
        console.log(`[dev-preview-ws] upstreamSocket closed for ${cleanPath}, hadError=${hadError}`);
      });
      upstreamSocket.on('end', () => {
        console.log(`[dev-preview-ws] upstreamSocket end for ${cleanPath}`);
      });
      clientSocket.on('close', (hadError) => {
        console.log(`[dev-preview-ws] clientSocket closed for ${cleanPath}, hadError=${hadError}`);
      });
      clientSocket.on('end', () => {
        console.log(`[dev-preview-ws] clientSocket end for ${cleanPath}`);
      });
      upstreamSocket.on('error', (err) => {
        console.error(`[dev-preview-ws] upstreamSocket error for ${cleanPath}:`, err.message);
        clientSocket.destroy();
      });
      clientSocket.on('error', (err) => {
        console.error(`[dev-preview-ws] clientSocket error for ${cleanPath}:`, err.message);
        upstreamSocket.destroy();
      });
    });
    upstreamReq.on('response', (upstreamRes) => {
      console.warn(`[dev-preview-ws] upstreamReq non-upgrade response for ${cleanPath}: status=${upstreamRes.statusCode}`);
      clientSocket.end(`HTTP/1.1 ${upstreamRes.statusCode} ${upstreamRes.statusMessage}\r\n\r\n`);
    });
    upstreamReq.on('error', (err) => {
      console.error(`[dev-preview-ws] upstreamReq error for ${cleanPath}:`, err.message);
      clientSocket.destroy();
    });
    upstreamReq.end();
    return;
  }

  // HMR socket must reach Vite under the prefix it is based on.
  targetPath = basePrefix.replace(/\/$/, '') + (cleanPath.startsWith('/') ? cleanPath : '/' + cleanPath);

  console.log(`[dev-preview] WebSocket upgrade for ${req.url} -> forwarding to Vite ${targetPath}`);

  const upstreamSocket = net.connect(VITE_PORT, '127.0.0.1', () => {
    const headers = { ...req.headers };
    headers.host = `127.0.0.1:${VITE_PORT}`;

    const lines = [`${req.method || 'GET'} ${targetPath} HTTP/1.1`];
    for (const [name, val] of Object.entries(headers)) {
      if (Array.isArray(val)) {
        for (const item of val) lines.push(`${name}: ${item}`);
      } else if (val !== undefined) {
        lines.push(`${name}: ${val}`);
      }
    }
    lines.push('', '');

    upstreamSocket.write(lines.join('\r\n'));
    if (head && head.length) upstreamSocket.write(head);

    clientSocket.pipe(upstreamSocket).pipe(clientSocket);
  });

  upstreamSocket.on('error', (err) => {
    console.error(`[dev-preview] WebSocket relay error: ${err.message}`);
    clientSocket.destroy();
  });

  clientSocket.on('error', (err) => {
    upstreamSocket.destroy();
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[dev-preview] listening on http://127.0.0.1:${PORT}`);
  console.log(`[dev-preview] proxying to Vite on http://127.0.0.1:${VITE_PORT}`);
  if (sessionId) {
    console.log(`[dev-preview] base path: ${basePrefix}`);
  }
});
