// URL policy for the desktop shell, kept free of Electron imports so it is unit
// tested directly.
//
// REQ-EXT-URL-1: the renderer is the remote Hub UI, so any URL it hands to
// shell.openExternal must be a web or mail link. file:, smb:, javascript: and
// custom-scheme URLs can launch local applications on macOS.
const EXTERNAL_PROTOCOLS = new Set(['https:', 'mailto:']);

// allowedExternalUrl returns the normalized URL when it may be opened in the
// system browser or mail client, or '' when it must be refused.
function allowedExternalUrl(value: unknown): string {
  try {
    const url = new URL(String(value || '').trim());
    if (!EXTERNAL_PROTOCOLS.has(url.protocol)) return '';
    if (url.protocol === 'https:' && (!url.hostname || url.username || url.password)) return '';
    return url.href;
  } catch (_err) {
    return '';
  }
}

// allowedPairingUrl accepts a Bridge enrollment approval URL only on one of the
// configured Hub/UI origins. Those origins may be http: in local development.
function allowedPairingUrl(value: unknown, trustedOrigins: string[]): string {
  try {
    const url = new URL(String(value || '').trim());
    const origins = new Set(trustedOrigins.map((origin) => { try { return new URL(origin).origin; } catch (_err) { return ''; } }).filter(Boolean));
    if (!origins.has(url.origin) || url.username || url.password) return '';
    return url.href;
  } catch (_err) {
    return '';
  }
}

// REQ-NAV-ROUTE-1: where a main-window navigation goes.
//   allow    - stays in the main window (the trusted Hub UI origin)
//   auth     - OIDC sign-in/sign-out, run in the preload-free OIDC window
//   external - any other https:/mailto: page, opened in the system browser
//   block    - everything else is refused
type NavigationRoute = 'allow' | 'auth' | 'external' | 'block';

interface NavigationContext {
  uiOrigin: string;
  // Origin of the identity provider, from GET /api/v1/auth/config; '' if unknown.
  idpOrigin: string;
  // True while the main window follows a redirect chain started at the Hub's
  // own /api/v1/auth/login or /api/v1/auth/logout.
  inAuthRedirect: boolean;
}

function originOf(value: unknown): string {
  try { return new URL(String(value || '')).origin; } catch (_err) { return ''; }
}

// isAuthStartUrl reports whether a main-window navigation enters the Hub's own
// sign-in or sign-out routes, whose redirects lead to the identity provider.
function isAuthStartUrl(value: unknown, uiOrigin: string): boolean {
  try {
    const url = new URL(String(value || ''));
    if (url.origin !== originOf(uiOrigin)) return false;
    return url.pathname.startsWith('/api/v1/auth/login') || url.pathname.startsWith('/api/v1/auth/logout');
  } catch (_err) {
    return false;
  }
}

function classifyNavigation(value: unknown, context: NavigationContext): NavigationRoute {
  let url: URL;
  try { url = new URL(String(value || '')); } catch (_err) { return 'block'; }
  if (url.origin === originOf(context.uiOrigin)) return 'allow';
  const idpOrigin = originOf(context.idpOrigin);
  if (url.protocol === 'https:' && (context.inAuthRedirect || (idpOrigin && url.origin === idpOrigin))) return 'auth';
  return allowedExternalUrl(url.href) ? 'external' : 'block';
}

// idpOriginFromAuthConfig reads the provider origin from the Hub's public auth
// config: `logout_url` is the provider's end-session endpoint.
function idpOriginFromAuthConfig(body: any): string {
  const logoutUrl = String(body?.data?.logout_url || body?.logout_url || '').trim();
  try {
    const url = new URL(logoutUrl);
    return url.protocol === 'https:' ? url.origin : '';
  } catch (_err) {
    return '';
  }
}

// REQ-NAV-ROUTE-2: the OIDC window may move between the provider's https:
// pages (social login can span several origins) and back to the Hub UI.
function oidcWindowNavigationAllowed(value: unknown, uiOrigin: string): boolean {
  try {
    const url = new URL(String(value || ''));
    return url.protocol === 'https:' || url.origin === originOf(uiOrigin);
  } catch (_err) {
    return false;
  }
}

// F25: trustedIpcSender accepts an IPC call only from the app's own main-frame
// document on one of the trusted UI origins. A navigated-away page, an iframe or
// any other origin is refused before a privileged handler runs.
function trustedIpcSender(frameUrl: unknown, isMainFrame: boolean, trustedOrigins: string[]): boolean {
  if (!isMainFrame) return false;
  try {
    const url = new URL(String(frameUrl || ''));
    const origins = new Set(trustedOrigins.map((origin) => { try { return new URL(origin).origin; } catch (_err) { return ''; } }).filter(Boolean));
    return origins.has(url.origin);
  } catch (_err) {
    return false;
  }
}

module.exports = { trustedIpcSender, allowedExternalUrl, allowedPairingUrl, classifyNavigation, idpOriginFromAuthConfig, isAuthStartUrl, oidcWindowNavigationAllowed };
