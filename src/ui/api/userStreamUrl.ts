import { apiAbsoluteUrl } from './apiBase';
import { UserWsAuthError, authProbeResultForStatus } from './userWsRecovery';

export function hasElectronDeviceAuth(): boolean {
  return typeof window !== 'undefined' && Boolean((window as any).odinApi?.deviceAuth);
}

async function electronApiBaseUrl(): Promise<string> {
  try {
    const cfg = await (window as any).odinApi?.deviceAuth?.getConfig?.();
    return String(cfg?.apiBaseUrl || (window as any).odinApi?.hubApiBaseUrl || '').replace(/\/$/, '');
  } catch (_err) {
    return String((window as any).odinApi?.hubApiBaseUrl || '').replace(/\/$/, '');
  }
}

function httpToWsUrl(base: string, path: string): string {
  const parsed = new URL(base || window.location.origin);
  parsed.protocol = parsed.protocol === 'https:' ? 'wss:' : 'ws:';
  parsed.pathname = path;
  parsed.search = '';
  parsed.hash = '';
  return parsed.toString();
}

async function electronStreamUrl(path: string, signal?: AbortSignal): Promise<string> {
  const response = await fetch('/api/v1/me/ws-ticket', { method: 'POST', headers: { 'Content-Type': 'application/json' }, signal });
  const text = await response.text();
  let body: any = {};
  if (text) {
    try { body = JSON.parse(text); } catch (_err) { body = {}; }
  }
  const data = body?.data !== undefined ? body.data : body;
  if (!response.ok) {
    const message = String(data?.error?.message || data?.message || `WebSocket ticket failed (${response.status})`);
    // 401/403 on the ticket mint is the Electron equivalent of a refused upgrade:
    // retrying cannot fix it.
    const verdict = authProbeResultForStatus(response.status);
    if (verdict === 'unauthenticated' || verdict === 'forbidden') throw new UserWsAuthError(verdict, message);
    throw new Error(message);
  }
  const ticket = String(data?.ticket || '');
  if (!ticket) throw new Error('WebSocket ticket response did not include a ticket');
  const base = await electronApiBaseUrl();
  const url = new URL(httpToWsUrl(base, path));
  url.searchParams.set('ticket', ticket);
  return url.toString();
}

export async function authenticatedStreamUrl(path: string, signal?: AbortSignal): Promise<string> {
  if (typeof window === 'undefined') return '';
  if (hasElectronDeviceAuth()) return electronStreamUrl(path, signal);
  // Built from the API base so a preview build's socket follows the same path
  // prefix as its fetches, rather than silently attaching to whatever hub happens
  // to own the origin the preview is framed in.
  const url = new URL(apiAbsoluteUrl(path));
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  return url.toString();
}

