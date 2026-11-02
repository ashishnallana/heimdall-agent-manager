// preview-origin.mjs — lets the Heimdall preview origin use ham-dev-proxy's
// brokered sign-in (docs/auth-oidc.md, "Local development").
//
// ham-dev-proxy signs in to the hub on the dev user's behalf and attaches that
// session only to requests from a trusted browser origin: loopback, or a
// --trusted-origin it was started with. A page opened through the Heimdall
// preview sends Origin: <preview origin>, which a proxy started before the preview
// existed cannot know. The preview relays (dev-preview.mjs, preview-server.mjs)
// do know it, from the session's preview_url, so they vouch for it: a request
// whose Origin is exactly the preview origin is forwarded with the relay's own
// loopback origin instead. Any other Origin is forwarded unchanged, so a foreign
// page still gets no session (the proxy's CSRF guard is untouched).
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

/** scheme://host[:port] of a URL, lower-cased; '' when it is not a URL. */
export function originOf(url) {
  if (!url) return '';
  try {
    const { origin } = new URL(url);
    return origin === 'null' ? '' : origin.toLowerCase();
  } catch {
    return '';
  }
}

/**
 * rewritePreviewOrigin(headers, previewOrigin, relayOrigin) -> the headers to send
 * upstream. Only an exact preview-origin match is replaced.
 */
export function rewritePreviewOrigin(headers, previewOrigin, relayOrigin) {
  if (!previewOrigin) return headers;
  for (const key of Object.keys(headers)) {
    if (key.toLowerCase() !== 'origin') continue;
    const value = String(headers[key] || '').trim().replace(/\/+$/, '').toLowerCase();
    if (value === previewOrigin) headers[key] = relayOrigin;
  }
  return headers;
}

/**
 * createPreviewOriginGate({ port, previewUrl, previewUrlFile, hamCtl }) learns the
 * preview origin from an explicit URL (--preview-url / HEIMDALL_PREVIEW_URL /
 * HEIMDALL_PREVIEW_ORIGIN), else from previewUrlFile (the launcher writes the
 * session's preview_url there once `ham-ctl shell start` returns it), else from the
 * running shell session serving `port` (`ham-ctl shell list`). Discovery is retried
 * at most every 5s until it succeeds.
 */
export function createPreviewOriginGate({ port, previewUrl = '', previewUrlFile = '', hamCtl = [] }) {
  const relayOrigin = `http://127.0.0.1:${port}`;
  let previewOrigin = originOf(previewUrl);
  let nextLookup = 0;

  function discover() {
    if (previewOrigin || Date.now() < nextLookup) return previewOrigin;
    nextLookup = Date.now() + 5000;
    if (previewUrlFile) {
      try {
        previewOrigin = originOf(fs.readFileSync(previewUrlFile, 'utf8').trim());
      } catch {}
      if (previewOrigin) {
        console.log(`[preview-origin] trusting preview origin ${previewOrigin} as ${relayOrigin}`);
        return previewOrigin;
      }
    }
    const bridgeArgs = process.env.HEIMDALL_BRIDGE_ID ? ['--bridge', process.env.HEIMDALL_BRIDGE_ID] : [];
    for (const bin of hamCtl.filter(Boolean)) {
      try {
        const out = execFileSync(bin, ['shell', 'list', ...bridgeArgs, '--status', 'running'],
          { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 3000 });
        const data = JSON.parse(out);
        const sessions = data?.data?.data?.sessions || data?.data?.sessions || [];
        const match = sessions.find((s) => s.server_port === port && s.status === 'running' && s.preview_url);
        if (match) {
          previewOrigin = originOf(match.preview_url);
          if (previewOrigin) {
            console.log(`[preview-origin] trusting preview origin ${previewOrigin} as ${relayOrigin}`);
            return previewOrigin;
          }
        }
      } catch {}
    }
    return previewOrigin;
  }

  return {
    relayOrigin,
    previewOrigin: () => discover(),
    rewrite(headers) {
      // Only a request that names an Origin can need it; skip the lookup otherwise.
      if (!Object.keys(headers).some((key) => key.toLowerCase() === 'origin')) return headers;
      return rewritePreviewOrigin(headers, discover(), relayOrigin);
    },
  };
}
