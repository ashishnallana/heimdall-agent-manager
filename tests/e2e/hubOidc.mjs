// Test helper (node): run tools/mock-oidc and sign in to a local hub like a
// browser. The hub accepts only OIDC: a browser session cookie from the real
// authorization-code flow, or an OIDC bearer (device-proof gated on most routes).
//
//   const mock = await startMockOidc();
//   spawn(hubBin, [...args, '--ui-origin', base], { env: { ...process.env, ...mock.hubEnv(base) } })
//   const cookie = await hubLogin(base, 'alice');
//   fetch(url, { headers: sessionHeaders(cookie, base) })   // Origin satisfies CSRF
import { spawn } from 'node:child_process';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const MOCK = path.join(REPO_ROOT, 'tools', 'mock-oidc', 'mock_oidc.py');
export const SESSION_COOKIE = '__Host-heimdall_session';
export const LOGIN_COOKIE = '__Host-heimdall_login';

export function freePort() {
  return new Promise((resolve, reject) => {
    const s = net.createServer();
    s.unref();
    s.on('error', reject);
    s.listen(0, '127.0.0.1', () => { const { port } = s.address(); s.close(() => resolve(port)); });
  });
}

export async function startMockOidc({ username = 'dev', clientId = 'heimdall-web' } = {}) {
  const port = await freePort();
  const child = spawn(process.env.PYTHON || 'python3', [MOCK, '--port', String(port), '--username', username, '--client-id', clientId], { stdio: 'ignore' });
  const issuer = `http://127.0.0.1:${port}/application/o/heimdall-native/`;
  const deadline = Date.now() + 10_000;
  for (;;) {
    try { if ((await fetch(`${issuer}jwks/`)).ok) break; } catch { /* not up yet */ }
    if (Date.now() > deadline) { child.kill(); throw new Error('mock OIDC provider did not start'); }
    await new Promise((r) => setTimeout(r, 50));
  }
  return {
    port,
    issuer,
    stop: () => child.kill(),
    // Hub environment for this provider. `hubBase` sets the redirect URI so the
    // callback lands on this hub even when --ui-origin names another origin.
    hubEnv(hubBase) {
      return {
        HAM_OIDC_ALLOW_INSECURE_LOCALHOST: '1',
        HAM_OIDC_ISSUER: issuer,
        HAM_OIDC_JWKS_URL: `${issuer}jwks/`,
        HAM_OIDC_USERINFO_URL: `${issuer}userinfo/`,
        HAM_OIDC_AUTHORIZE_URL: `${issuer}authorize/`,
        HAM_OIDC_TOKEN_URL: `${issuer}token/`,
        HAM_OIDC_END_SESSION_URL: `${issuer}end-session/`,
        HAM_OIDC_API_AUDIENCE: 'heimdall-api',
        HAM_OIDC_API_SCOPE: 'heimdall.api',
        HAM_OIDC_WEB_CLIENT_ID: clientId,
        HAM_AUTO_PROVISION_USERS: 'true',
        HAM_OIDC_CLAIM_EXISTING_USERS: 'true',
        ...(hubBase ? { HAM_OIDC_REDIRECT_URI: `${hubBase.replace(/\/$/, '')}/api/v1/auth/callback` } : {}),
      };
    },
    async accessToken(user = username) {
      const res = await fetch(`http://127.0.0.1:${port}/__mock/access-token`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username: user }) });
      return (await res.json()).access_token;
    },
  };
}

function setCookie(res, name) {
  for (const value of res.headers.getSetCookie()) {
    const pair = value.split(';', 1)[0];
    const eq = pair.indexOf('=');
    if (pair.slice(0, eq).trim() === name && pair.slice(eq + 1)) return pair.slice(eq + 1);
  }
  return '';
}

// hubLogin runs /api/v1/auth/login -> mock authorize -> /api/v1/auth/callback and
// returns the raw __Host-heimdall_session value. An empty username adds no
// login_hint (through ham-dev-proxy that signs in as the proxy's selected user).
export async function hubLogin(base, username = 'dev', returnTo = '/') {
  base = base.replace(/\/$/, '');
  const start = await fetch(`${base}/api/v1/auth/login?return_to=${encodeURIComponent(returnTo)}`, { redirect: 'manual' });
  if (start.status !== 302) throw new Error(`/api/v1/auth/login returned ${start.status}`);
  const loginState = setCookie(start, LOGIN_COOKIE);
  const hint = username ? `&login_hint=${encodeURIComponent(username)}` : '';
  const authz = await fetch(`${start.headers.get('location')}${hint}`, { redirect: 'manual' });
  if (authz.status !== 302) throw new Error(`mock authorize returned ${authz.status}`);
  // Deliver the callback to `base` whatever origin the redirect URI names (e.g. a
  // UI dev server that is not running yet); the session cookie is host-scoped.
  const cb = new URL(authz.headers.get('location'), base);
  const callback = `${base}${cb.pathname}${cb.search}`;
  const done = await fetch(callback, { redirect: 'manual', headers: { Cookie: `${LOGIN_COOKIE}=${loginState}` } });
  const session = setCookie(done, SESSION_COOKIE);
  if (done.status !== 302 || !session) throw new Error(`callback failed: ${done.status} ${done.headers.get('location')} ${await done.text()}`);
  return session;
}

export function sessionHeaders(session, uiOrigin, extra = {}) {
  return { Cookie: `${SESSION_COOKIE}=${session}`, Origin: uiOrigin.replace(/\/$/, ''), ...extra };
}

// sessionPool lazily signs each username in once.
export function sessionPool(base) {
  const sessions = new Map();
  return async (username) => {
    if (!sessions.has(username)) sessions.set(username, await hubLogin(base, username));
    return sessions.get(username);
  };
}
