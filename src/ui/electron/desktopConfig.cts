// REQ-OIDC-HANDOFF-1: resolve one UI URL before any window/session consumer runs.
const PRODUCTION_API = 'https://hub.brolabs.ai';
const LEGACY_UI = 'https://heimdall.brolabs.ai';
const CANONICAL_UI = 'https://web.ninjy.ai';

function base(value: unknown): string {
  return String(value || '').trim().replace(/\/$/, '');
}

function checkedUrl(value: string, name: string): string {
  const url = new URL(value);
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) {
    throw new Error(`${name} must be an HTTP(S) URL without credentials.`);
  }
  return value;
}

function resolveDesktopConfig(env: Record<string, string | undefined>, packaged: boolean) {
  const apiOverride = base(env.HEIMDALL_HUB_API_URL || env.HEIMDALL_HUB_URL);
  const hubApiBaseUrl = checkedUrl(apiOverride || (packaged ? PRODUCTION_API : 'http://127.0.0.1:8081'), 'Hub API');
  const requestedUi = base(env.HEIMDALL_UI_URL);
  const viteUi = base(env.VITE_DEV_SERVER_URL);
  if (viteUi) {
    checkedUrl(viteUi, 'Vite UI');
    if (requestedUi && requestedUi !== viteUi) {
      throw new Error('HEIMDALL_UI_URL conflicts with VITE_DEV_SERVER_URL; use the same UI URL or unset HEIMDALL_UI_URL.');
    }
    return { hubApiBaseUrl, uiUrl: viteUi, isDev: true, migratedLegacyUi: false };
  }
  // A locally built shell can load the hosted UI; app.isPackaged is not dev mode.
  const production = hubApiBaseUrl === PRODUCTION_API;
  let uiUrl = checkedUrl(requestedUi || (packaged || (apiOverride && production) ? CANONICAL_UI : 'http://127.0.0.1:5173'), 'UI');
  const migratedLegacyUi = production && uiUrl === LEGACY_UI;
  if (migratedLegacyUi) uiUrl = CANONICAL_UI;
  return { hubApiBaseUrl, uiUrl, isDev: false, migratedLegacyUi };
}

/** Only a committed return to this exact UI may complete a desktop login. */
function desktopAuthReturnUrl(value: unknown, uiUrl: string): string {
  try {
    const url = new URL(String(value || ''));
    const ui = new URL(uiUrl);
    if (url.origin !== ui.origin || url.username || url.password
      || !['http:', 'https:'].includes(url.protocol) || url.pathname.startsWith('/api/')) return '';
    return url.href;
  } catch { return ''; }
}

export = { resolveDesktopConfig, desktopAuthReturnUrl };
