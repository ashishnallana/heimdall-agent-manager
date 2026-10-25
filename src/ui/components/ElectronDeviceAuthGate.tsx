import { useEffect, useRef, useState } from 'react';
import type { FormEvent, ReactNode } from 'react';
import { Input, Text } from '@ui';

const API_PREFIX = '/api/v1';

type DeviceAuthBridge = {
  getConfig: () => Promise<{ apiBaseUrl?: string; safeStorageAvailable?: boolean }>;
  getStoredToken: () => Promise<{ ok: boolean; token?: string; error?: string }>;
  storeToken: (token: string) => Promise<{ ok: boolean; error?: string }>;
  clearToken: () => Promise<{ ok: boolean; error?: string }>;
  getDeviceInfo: () => Promise<{ client?: string; deviceLabel?: string; os?: string; appVersion?: string }>;
  openExternal: (url: string) => Promise<{ ok: boolean; error?: string }>;
};

type FlowState = {
  deviceCode: string;
  userCode: string;
  verificationUri: string;
  interval: number;
  expiresIn: number;
};

type GateState = 'checking' | 'ready' | 'authorize';
type DeviceScreenState = 'manual' | 'starting' | 'pending' | 'approved' | 'denied' | 'expired' | 'error';

let fetchBridgeInstalled = false;
let cachedBearerToken: string | null | undefined;
let cachedApiBaseUrl: string | null | undefined;

function deviceBridge(): DeviceAuthBridge | null {
  if (typeof window === 'undefined') return null;
  return ((window as any).odinApi?.deviceAuth || null) as DeviceAuthBridge | null;
}

function isElectronDeviceAuthAvailable(): boolean {
  return Boolean(deviceBridge());
}

function unwrapApiBody(body: any): any {
  return body?.data !== undefined ? body.data : body;
}

function isApiV1Input(input: RequestInfo | URL): boolean {
  const value = typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
  try {
    const url = new URL(value, window.location.href);
    return url.pathname.startsWith(`${API_PREFIX}/`) || url.pathname === API_PREFIX;
  } catch (_err) {
    return String(value).startsWith(`${API_PREFIX}/`);
  }
}

async function getApiBaseUrl(): Promise<string> {
  if (cachedApiBaseUrl !== undefined) return cachedApiBaseUrl || '';
  const bridge = deviceBridge();
  if (!bridge) {
    cachedApiBaseUrl = '';
    return '';
  }
  try {
    const cfg = await bridge.getConfig();
    cachedApiBaseUrl = String(cfg?.apiBaseUrl || (window as any).odinApi?.hubApiBaseUrl || '').replace(/\/$/, '');
  } catch (_err) {
    cachedApiBaseUrl = String((window as any).odinApi?.hubApiBaseUrl || '').replace(/\/$/, '');
  }
  return cachedApiBaseUrl || '';
}

async function getBearerToken(): Promise<string> {
  if (cachedBearerToken !== undefined) return cachedBearerToken || '';
  const bridge = deviceBridge();
  if (!bridge) {
    cachedBearerToken = '';
    return '';
  }
  const result = await bridge.getStoredToken().catch(() => ({ ok: false, token: '' }));
  cachedBearerToken = result?.ok ? String(result.token || '') : '';
  return cachedBearerToken || '';
}

async function clearBearerToken() {
  cachedBearerToken = '';
  await deviceBridge()?.clearToken().catch(() => undefined);
}

function toApiPath(path: string): string {
  return path.startsWith(API_PREFIX) ? path : `${API_PREFIX}${path.startsWith('/') ? path : `/${path}`}`;
}

async function absoluteApiUrl(path: string): Promise<string> {
  const apiPath = toApiPath(path);
  const base = await getApiBaseUrl();
  if (!base) return apiPath;
  return `${base}${apiPath}`;
}

async function rewriteApiInput(input: RequestInfo | URL): Promise<RequestInfo | URL> {
  if (!isApiV1Input(input)) return input;
  const value = typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url;
  const parsed = new URL(value, window.location.href);
  const rewritten = await absoluteApiUrl(`${parsed.pathname}${parsed.search}`);
  if (typeof input === 'string') return rewritten;
  if (input instanceof URL) return new URL(rewritten);
  return input;
}

export function installElectronApiFetchBridge() {
  if (typeof window === 'undefined' || fetchBridgeInstalled || !isElectronDeviceAuthAvailable()) return;
  const originalFetch = window.fetch.bind(window);
  fetchBridgeInstalled = true;
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const isApi = isApiV1Input(input);
    const nextInput = isApi ? await rewriteApiInput(input) : input;
    let nextInit = init;
    let sentStoredToken = false;
    let explicitAuthorization = false;
    if (isApi) {
      const headers = new Headers(init?.headers || (input instanceof Request ? input.headers : undefined));
      explicitAuthorization = headers.has('Authorization');
      const token = await getBearerToken();
      if (token && !explicitAuthorization) {
        headers.set('Authorization', `Bearer ${token}`);
        sentStoredToken = true;
      }
      // Electron uses bearer tokens only; do not send browser/outpost cookies on
      // device-authorized API calls even if the configured API URL is same-origin.
      nextInit = { ...init, headers, credentials: 'omit' };
    }
    const response = await originalFetch(nextInput, nextInit);
    if (isApi && response.status === 401 && !explicitAuthorization) {
      if (sentStoredToken) await clearBearerToken();
      window.dispatchEvent(new CustomEvent('heimdall:electron-device-auth-required'));
    }
    return response;
  };
}

async function apiJson(path: string, init?: RequestInit): Promise<{ response: Response; data: any }> {
  const response = await fetch(await absoluteApiUrl(path), {
    ...init,
    headers: { 'Content-Type': 'application/json', ...(init?.headers as Record<string, string> | undefined) },
  });
  const text = await response.text();
  let body: any = {};
  if (text) {
    try { body = JSON.parse(text); } catch (_err) { body = { raw: text }; }
  }
  return { response, data: unwrapApiBody(body) };
}

async function checkCurrentToken(): Promise<boolean> {
  const { response } = await apiJson('/me').catch(() => ({ response: { ok: false } as Response, data: {} }));
  return Boolean(response.ok);
}

async function validateAndStoreUserToken(token: string): Promise<void> {
  const trimmed = token.trim();
  if (!trimmed) throw new Error('Paste a user token first.');
  const response = await fetch(await absoluteApiUrl('/me'), {
    headers: { Authorization: `Bearer ${trimmed}` },
    credentials: 'omit',
  });
  if (!response.ok) {
    let msg = `Token validation failed (${response.status})`;
    try {
      const text = await response.text();
      const body = JSON.parse(text);
      msg = String(body?.error?.message || body?.message || msg);
    } catch (_err) {}
    throw new Error(msg);
  }
  const stored = await deviceBridge()?.storeToken(trimmed);
  if (!stored?.ok) throw new Error(stored?.error || 'Unable to store token in Electron safeStorage.');
  cachedBearerToken = trimmed;
}

export default function ElectronDeviceAuthGate({ children }: { children: ReactNode }) {
  const [state, setState] = useState<GateState>(() => isElectronDeviceAuthAvailable() ? 'checking' : 'ready');

  useEffect(() => {
    if (!isElectronDeviceAuthAvailable()) return;
    let cancelled = false;
    checkCurrentToken().then((ok) => {
      if (!cancelled) setState(ok ? 'ready' : 'authorize');
    });
    const onRequired = () => setState('authorize');
    window.addEventListener('heimdall:electron-device-auth-required', onRequired);
    return () => {
      cancelled = true;
      window.removeEventListener('heimdall:electron-device-auth-required', onRequired);
    };
  }, []);

  if (state === 'ready') return <>{children}</>;
  if (state === 'checking') return <DeviceAuthShell title="Checking stored device token…" body="Heimdall is checking the Electron keychain before starting the app." />;
  return <ElectronDeviceAuthScreen onAuthenticated={() => setState('ready')} />;
}

function DeviceAuthShell({ title, body, children }: { title: string; body: string; children?: ReactNode }) {
  return (
    <main data-debug-id="electron-device-auth" className="grid app-viewport-min-height place-items-center bg-canvas px-6 text-primary">
      <section className="w-full max-w-xl rounded-[2rem] border border-subtle bg-surface p-8 text-center shadow-2xl">
        <Text as="p" role="overline" tone="accent">Device authorization</Text>
        <h1 className="mt-3 text-3xl font-semibold tracking-tight">{title}</h1>
        <p className="mt-3 text-sm leading-6 text-muted">{body}</p>
        {children}
      </section>
    </main>
  );
}

function ElectronDeviceAuthScreen({ onAuthenticated }: { onAuthenticated: () => void }) {
  const [status, setStatus] = useState<DeviceScreenState>('manual');
  const [flow, setFlow] = useState<FlowState | null>(null);
  // TODO(oidc): the desktop app needs its own OIDC sign-in. The Hub no longer
  // issues user tokens or user device-authorization grants, so neither path below
  // can succeed against an OIDC-only Hub.
  const [message, setMessage] = useState('The desktop app cannot sign in to this Hub yet: Heimdall now uses OIDC sign-in and no longer issues user tokens. Use Heimdall in your browser for now.');
  const [tokenDraft, setTokenDraft] = useState('');
  const [manualError, setManualError] = useState('');
  const [manualBusy, setManualBusy] = useState(false);
  const pollTimerRef = useRef<number | null>(null);

  const stopPoll = () => {
    if (pollTimerRef.current !== null) window.clearTimeout(pollTimerRef.current);
    pollTimerRef.current = null;
  };

  const startAuthorize = async () => {
    stopPoll();
    setManualError('');
    setStatus('starting');
    setMessage('Requesting a one-time device code…');
    setFlow(null);
    try {
      await clearBearerToken();
      const info = (await deviceBridge()?.getDeviceInfo().catch(() => ({})) || {}) as { client?: string; deviceLabel?: string; os?: string; appVersion?: string };
      const { response, data } = await apiJson('/device/authorize', {
        method: 'POST',
        body: JSON.stringify({
          client: info.client || 'heimdall-electron',
          device_label: info.deviceLabel || 'Heimdall Desktop',
          os: info.os || 'desktop',
          app_version: info.appVersion || '0.1.0',
        }),
      });
      if (!response.ok) throw new Error(data?.message || data?.error?.message || `Authorize failed (${response.status})`);
      const nextFlow: FlowState = {
        deviceCode: String(data.device_code || data.deviceCode || ''),
        userCode: String(data.user_code || data.userCode || ''),
        verificationUri: String(data.verification_uri || data.verificationUri || ''),
        interval: Math.max(1, Number(data.interval || 5)),
        expiresIn: Math.max(1, Number(data.expires_in || data.expiresIn || 600)),
      };
      if (!nextFlow.deviceCode || !nextFlow.userCode || !nextFlow.verificationUri) throw new Error('Authorize response was missing device_code, user_code, or verification_uri.');
      setFlow(nextFlow);
      setStatus('pending');
      setMessage('Open the browser link, sign in, and type the code shown here. Heimdall will keep polling until the grant is approved.');
      schedulePoll(nextFlow, nextFlow.interval);
    } catch (err: any) {
      setStatus('error');
      setMessage(String(err?.message || err || 'Unable to start device authorization.'));
    }
  };

  const schedulePoll = (currentFlow: FlowState, delaySeconds: number) => {
    stopPoll();
    pollTimerRef.current = window.setTimeout(() => pollOnce(currentFlow), Math.max(1, delaySeconds) * 1000);
  };

  const pollOnce = async (currentFlow: FlowState) => {
    try {
      const { response, data } = await apiJson('/device/token', {
        method: 'POST',
        body: JSON.stringify({ device_code: currentFlow.deviceCode }),
      });
      const nextStatus = String(data?.status || '').toLowerCase();
      if (response.status === 429 || nextStatus === 'slow_down') {
        const retryAfter = Number(response.headers.get('Retry-After') || data?.interval || currentFlow.interval + 1);
        setMessage(`Polling too quickly; backing off for ${retryAfter}s.`);
        schedulePoll(currentFlow, retryAfter);
        return;
      }
      if (!response.ok) throw new Error(data?.message || data?.error?.message || `Token poll failed (${response.status})`);
      if (nextStatus === 'pending') {
        schedulePoll(currentFlow, currentFlow.interval);
        return;
      }
      if (nextStatus === 'denied' || nextStatus === 'expired') {
        stopPoll();
        setStatus(nextStatus as DeviceScreenState);
        setMessage(nextStatus === 'denied' ? 'The browser approval was denied. Retry to request a fresh code.' : 'The device code expired or was already used. Retry to request a fresh code.');
        return;
      }
      if (nextStatus === 'approved') {
        const token = String(data?.access_token || data?.accessToken || '');
        if (!token) throw new Error('Approved response did not include an access token.');
        const stored = await deviceBridge()?.storeToken(token);
        if (!stored?.ok) throw new Error(stored?.error || 'Unable to store token in Electron safeStorage.');
        cachedBearerToken = token;
        setStatus('approved');
        setMessage('Approved. Token stored in the OS keychain; loading Heimdall…');
        window.setTimeout(onAuthenticated, 250);
        return;
      }
      throw new Error(`Unexpected device token status: ${nextStatus || 'unknown'}`);
    } catch (err: any) {
      stopPoll();
      setStatus('error');
      setMessage(String(err?.message || err || 'Device token polling failed.'));
    }
  };

  useEffect(() => () => stopPoll(), []);

  const submitManualToken = async (event: FormEvent) => {
    event.preventDefault();
    setManualBusy(true);
    setManualError('');
    try {
      await validateAndStoreUserToken(tokenDraft);
      setStatus('approved');
      setMessage('Token accepted. Loading Heimdall…');
      window.setTimeout(onAuthenticated, 150);
    } catch (err: any) {
      setManualError(String(err?.message || err || 'Token validation failed.'));
    } finally {
      setManualBusy(false);
    }
  };

  const openBrowser = async () => {
    if (!flow?.verificationUri) return;
    await deviceBridge()?.openExternal(flow.verificationUri).catch((err: any) => {
      setStatus('error');
      setMessage(String(err?.message || err || 'Unable to open browser link.'));
    });
  };

  const copyCode = async () => {
    if (!flow?.userCode) return;
    await navigator.clipboard?.writeText(flow.userCode).catch(() => undefined);
  };

  const terminal = status === 'denied' || status === 'expired' || status === 'error';
  return (
    <DeviceAuthShell title={status === 'manual' ? 'Enter your Heimdall user token' : status === 'starting' ? 'Requesting access…' : 'Sign in from your browser'} body={message}>
      {status === 'manual' ? (
        <form data-debug-id="electron-device-auth-token-form" onSubmit={submitManualToken} className="mt-8 space-y-4 text-left">
          <label className="block text-sm font-medium text-primary">
            User token
            <Input
              data-debug-id="electron-device-auth-token-input"
              type="password"
              value={tokenDraft}
              onChange={(value) => { setTokenDraft(value); setManualError(''); }}
              placeholder="hut_..."
              size="lg"
              width="full"
              className="mt-2 font-mono"
              autoFocus
            />
          </label>
          {manualError ? <div data-debug-id="electron-device-auth-token-error" className="rounded-xl border border-danger/30 bg-danger-soft px-3 py-2 text-xs text-danger">{manualError}</div> : null}
          <button data-debug-id="electron-device-auth-token-submit" type="submit" disabled={manualBusy || !tokenDraft.trim()} className="w-full rounded-2xl bg-accent px-5 py-3 text-sm font-bold text-accent-fg hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-50">{manualBusy ? 'Checking…' : 'Use token'}</button>
          <button data-debug-id="electron-device-auth-use-browser-flow" type="button" onClick={startAuthorize} className="w-full rounded-2xl border border-subtle bg-neutral-soft px-5 py-3 text-sm font-bold text-primary hover:bg-surface-raised">Use browser device authorization instead</button>
        </form>
      ) : null}
      {flow ? (
        <div className="mt-8 space-y-5">
          <div className="rounded-3xl border border-accent/30 bg-info-soft p-5">
            <Text as="p" role="overline" tone="accent">Your code</Text>
            <button data-debug-id="electron-device-auth-copy-code" onClick={copyCode} className="mt-3 w-full rounded-2xl border border-subtle bg-surface-raised px-4 py-4 font-mono text-4xl font-black tracking-[0.18em] text-primary hover:bg-neutral-soft">
              {flow.userCode}
            </button>
            <p className="mt-2 text-xs text-muted">Click the code to copy it, then type it in the browser page.</p>
          </div>
          <button data-debug-id="electron-device-auth-open-browser" onClick={openBrowser} className="inline-flex rounded-2xl bg-accent px-5 py-3 text-sm font-bold text-accent-fg hover:opacity-90">
            Open browser approval page
          </button>
          <div className="break-all rounded-2xl border border-subtle bg-surface-raised p-3 text-xs text-muted">{flow.verificationUri}</div>
          <p className="text-xs text-faint">Polling every {flow.interval}s. The code expires in about {Math.ceil(flow.expiresIn / 60)} minutes. Tokens are stored with Electron safeStorage; unsigned development builds depend on local OS keychain availability.</p>
        </div>
      ) : null}
      {terminal ? (
        <button data-debug-id="electron-device-auth-retry" onClick={startAuthorize} className="mt-6 inline-flex rounded-2xl bg-surface-raised px-5 py-3 text-sm font-bold text-primary hover:bg-neutral-soft">
          Retry sign in
        </button>
      ) : null}
    </DeviceAuthShell>
  );
}
