import { apiUrl, errorFromResponse } from '../cookieFetch';
import { currentDeviceIdentity } from '../../services/deviceVault';
import { signedRequestHeaders } from '../../utils/vaultRequestSigner';
import type { McpConsentBody, McpConsentRequest } from '../../utils/mcpConsent';
import type { ConnectorRecipient, ConnectorEpochDelivery } from '../../utils/mcpEpochDelivery';
import type { McpWorkerJob, McpWorkerReply } from '../../utils/mcpWorker';

const BASE = '/api/v1/mcp/oauth';

async function request<T>(method: string, suffix: string, value?: unknown, timeoutMs?: number): Promise<T> {
  const identity = currentDeviceIdentity();
  if (!identity) throw new Error('An approved unlocked Ninjy device is required');
  const path = `${BASE}${suffix}`;
  const body = value === undefined ? '' : JSON.stringify(value);
  const headers = await signedRequestHeaders(identity, identity.userId, method, path.split('?')[0], body);
  if (body) headers['Content-Type'] = 'application/json';
  const controller = timeoutMs ? new AbortController() : undefined;
  const timer = controller ? setTimeout(() => controller.abort(), timeoutMs) : undefined;
  try {
    const res = await fetch(apiUrl(path), { method, credentials: 'include', headers, body: body || undefined, signal: controller?.signal });
    if (!res.ok) throw await errorFromResponse(res);
    if (res.status === 204) return null as T;
    return await res.json() as T;
  } finally { if (timer !== undefined) clearTimeout(timer); }
}

export function fetchMcpConsent(ticket: string): Promise<McpConsentRequest> {
  return request('GET', `/consent?request=${encodeURIComponent(ticket)}`);
}
export function completeMcpConsent(body: McpConsentBody): Promise<{ redirect: string }> {
  return request('POST', '/consent', body);
}
export interface McpConnection { grant: string; client: string; resource: string; mode: string; created_ms: number; revoked: boolean }
export function fetchMcpConnections(): Promise<McpConnection[]> { return request('GET', '/connections'); }
export function disconnectMcpConnection(grant: string): Promise<{ disconnected: boolean }> { return request('POST', '/disconnect', { grant }); }
export function fetchMcpRecipients(): Promise<ConnectorRecipient[]> { return request('GET', '/recipients', undefined, 10000); }
export function deliverMcpEpochWrap(body: ConnectorEpochDelivery): Promise<{ delivered: boolean }> { return request('POST', '/wraps', body, 10000); }
export function fetchMcpWorkerJob(generation: string): Promise<McpWorkerJob | null> { return request('GET', `/jobs?generation=${encodeURIComponent(generation)}`, undefined, 3000); }
export function deliverMcpWorkerReply(body: McpWorkerReply, generation: string): Promise<{ accepted: boolean }> { return request('POST', `/jobs?generation=${encodeURIComponent(generation)}`, body, 3000); }
export function registerMcpWorker(generation: string, enabled: boolean): Promise<{ registered: boolean }> { return request('POST', '/worker', { generation, enabled, expires_ms: Date.now() + 60000 }, 3000); }
