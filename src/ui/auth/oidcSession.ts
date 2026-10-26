/**
 * Browser sign-in helpers for the Hub's OIDC login (docs/plans/oidc-only-auth.md).
 *
 * The Hub runs the OIDC authorization-code flow itself and keeps tokens server
 * side; the browser only holds an HttpOnly session cookie. So the UI never sees
 * a token: it navigates to /api/v1/auth/login to sign in and POSTs
 * /api/v1/auth/logout to sign out. Pure functions (no React) so they can be
 * unit-tested in Node.
 */

export const LOGIN_PATH = '/api/v1/auth/login';
export const LOGOUT_PATH = '/api/v1/auth/logout';
/** sessionStorage key: when the UI last auto-redirected to sign in. */
export const LOGIN_REDIRECT_KEY = 'heimdall:login-redirect-at';
/** Never auto-redirect to sign in more than once in this window (loop guard). */
export const LOGIN_REDIRECT_COOLDOWN_MS = 30_000;

export type AuthError = 'failed' | 'forbidden';

type LocationLike = { pathname: string; search: string; hash: string };

/** Removes the `auth_error` parameter from a query string ("" or "?a=b"). */
export function stripAuthError(search: string): string {
  const params = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search);
  // Leave the query byte-for-byte alone unless there is something to strip.
  if (!params.has('auth_error')) return search && !search.startsWith('?') ? `?${search}` : search;
  params.delete('auth_error');
  const rest = params.toString();
  return rest ? `?${rest}` : '';
}

function returnToShapeOk(value: string): boolean {
  if (!value.startsWith('/')) return false;
  if (value.length > 1 && (value[1] === '/' || value[1] === '\\')) return false;
  for (let i = 0; i < value.length; i += 1) {
    const c = value.charCodeAt(i);
    if (c < 0x20 || c === 0x7f || value[i] === '\\') return false;
  }
  return !value.includes('://');
}

const RETURN_TO_MAX_LENGTH = 2048;

/**
 * Mirrors the Hub's `safe_return_to`: a single leading '/', no scheme or
 * authority, no backslashes or control characters, the same after up to three
 * percent-decoding passes, and nothing still percent-encoded after them.
 */
export function isSafeReturnTo(value: string): boolean {
  if (!value || value.length > RETURN_TO_MAX_LENGTH) return false;
  let candidate = value;
  for (let pass = 0; pass < 3; pass += 1) {
    if (!returnToShapeOk(candidate)) return false;
    if (!candidate.includes('%')) break;
    try {
      candidate = decodeURIComponent(candidate);
    } catch (_err) {
      return false;
    }
  }
  return returnToShapeOk(candidate) && !candidate.includes('%');
}

/**
 * The same-origin path the Hub should return to after sign-in. Falls back to
 * "/" whenever the Hub would refuse it, so a strange URL never turns sign-in
 * into a 400.
 */
export function currentReturnTo(location: LocationLike): string {
  const path = location.pathname && location.pathname.startsWith('/') ? location.pathname : '/';
  const candidate = `${path}${stripAuthError(location.search || '')}${location.hash || ''}`;
  return isSafeReturnTo(candidate) ? candidate : '/';
}

/**
 * Where the browser may go after logout: an https: URL (the provider's
 * end-session endpoint) or a single-'/' same-origin path. Anything else
 * (javascript:, data:, protocol-relative, http:) becomes "/".
 */
export function safeLogoutTarget(value: string): string {
  const url = String(value || '').trim();
  if (url.startsWith('/') && !url.startsWith('//') && !url.startsWith('/\\')) return url;
  try {
    if (new URL(url).protocol === 'https:') return url;
  } catch (_err) {}
  return '/';
}

/** URL of the Hub's sign-in route, returning to `location` afterwards. */
export function loginHref(location: LocationLike): string {
  return `${LOGIN_PATH}?return_to=${encodeURIComponent(currentReturnTo(location))}`;
}

/** Reads the `auth_error` the Hub's callback appends after a failed sign-in. */
export function readAuthError(search: string): AuthError | null {
  const value = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search).get('auth_error');
  if (!value) return null;
  return value === 'forbidden' ? 'forbidden' : 'failed';
}

export function authErrorMessage(error: AuthError): string {
  if (error === 'forbidden') {
    return "Your account isn't linked to a Heimdall user; ask the operator to run ham-hub users link-oidc.";
  }
  return 'Sign-in did not complete. Try again; if it keeps failing, the identity provider may be unavailable.';
}

/**
 * Whether the UI may automatically navigate to the sign-in route now. Never
 * after a failed sign-in (the user must choose to retry), and at most once per
 * cooldown window, so a broken login can never become a redirect loop.
 */
export function shouldAutoRedirect(now: number, lastRedirectAt: number | null, authError: AuthError | null): boolean {
  if (authError) return false;
  if (lastRedirectAt === null || !Number.isFinite(lastRedirectAt)) return true;
  return now - lastRedirectAt >= LOGIN_REDIRECT_COOLDOWN_MS || now < lastRedirectAt;
}

type StorageLike = { getItem(key: string): string | null; setItem(key: string, value: string): void };

export function readLastLoginRedirect(storage: StorageLike | null | undefined): number | null {
  try {
    const raw = storage?.getItem(LOGIN_REDIRECT_KEY);
    if (!raw) return null;
    const value = Number(raw);
    return Number.isFinite(value) ? value : null;
  } catch (_err) {
    return null;
  }
}

export function recordLoginRedirect(storage: StorageLike | null | undefined, now: number): void {
  try { storage?.setItem(LOGIN_REDIRECT_KEY, String(now)); } catch (_err) {}
}

/**
 * Signs out: POST /api/v1/auth/logout (same-origin, cookie) and return the URL
 * the browser should go to next (the provider's end-session URL, or "/").
 * Logout always "succeeds" from the UI's point of view: the Hub expires the
 * cookie even when the session was already gone.
 */
export async function postLogout(fetchImpl: typeof fetch, url: string = LOGOUT_PATH): Promise<string> {
  try {
    const response = await fetchImpl(url, {
      method: 'POST',
      credentials: 'include',
      headers: { 'Content-Type': 'application/json' },
      body: '{}',
    });
    if (response.ok) {
      const body = await response.json().catch(() => ({}));
      const url = String(body?.data?.logout_url || body?.logout_url || '').trim();
      if (url) return safeLogoutTarget(url);
    }
  } catch (_err) {}
  return '/';
}

/** 429/503 from the identity check mean "provider or Hub temporarily unavailable". */
export function isTransientAuthStatus(status: number): boolean {
  return status === 429 || status === 503;
}
