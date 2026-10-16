import { apiUrl, ApiError } from '../api/cookieFetch';
import { cookieJsonFetch } from '../api/cookieFetch';
import { getActiveBridgeVaultKeyMaterial } from '../store/vaultSlice';

const DOMAIN = 'heimdall/task-chain-search-rpc/v1';
const PREFIX = 'search:v1:';
const HEDGE_DELAY_MS = 250;
const DEADLINE_MS = 5000;
const MAX_LIMIT = 50;

export type TaskChainSearchHit = {
  chain_id: string;
  project_id: string;
  status: string;
  updated_at: string;
  title: string;
  description: string;
};

export type TaskChainSearchResponse = {
  request_id: string;
  bridge_id: string;
  indexed_revision: number;
  stale: boolean;
  hits: TaskChainSearchHit[];
};

export function taskChainSearchErrorMessage(error: unknown): string {
  const code = String((error as any)?.code || '');
  switch (code) {
    case 'bridge_offline': return 'No search Bridge is online.';
    case 'vault_locked': return 'Unlock the vault to search task chains.';
    case 'search_not_ready': return 'Bridge search is still preparing.';
    case 'search_stale': return 'Bridge search results may be stale.';
    case 'deadline_exceeded':
    case 'bridge_timeout': return 'Bridge search timed out.';
    case 'invalid_envelope': return 'The encrypted search response was rejected.';
    case 'query_too_short': return 'Enter at least two characters.';
    case 'limit_exceeded': return 'The search result limit is invalid.';
    default: return 'Bridge search unavailable; showing loaded chains.';
  }
}

type SearchBridge = { bridge_id?: string; id?: string; status?: string; runtime_status?: string; vault_status?: string; task_chain_search_ready?: boolean };

const utf8 = new TextEncoder();
const text = new TextDecoder();

function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

function base64ToBytes(value: string): Uint8Array {
  const binary = atob(value);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

function hexToBytes(value: string): Uint8Array {
  if (!/^[0-9a-f]{64}$/i.test(value)) throw new ApiError('Vault key unavailable', 423, 'vault_locked');
  return Uint8Array.from(value.match(/../g)!, (part) => Number.parseInt(part, 16));
}

export async function deriveTaskChainSearchKey(rawHex: string): Promise<CryptoKey> {
  const material = await crypto.subtle.importKey('raw', hexToBytes(rawHex) as unknown as BufferSource, 'HKDF', false, ['deriveKey']);
  const domain = utf8.encode(DOMAIN);
  return crypto.subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: domain as unknown as BufferSource, info: domain as unknown as BufferSource },
    material,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt'],
  );
}

export function taskChainSearchAad(ownerId: string, bridgeId: string, requestId: string, direction: 'request' | 'response', expiresAtMs: number): Uint8Array {
  return utf8.encode(`${DOMAIN}|${ownerId}|${bridgeId}|${requestId}|${direction}|${expiresAtMs}`);
}

export async function sealTaskChainSearch(
  plaintext: unknown,
  key: CryptoKey,
  associatedData: Uint8Array,
  nonce = crypto.getRandomValues(new Uint8Array(12)),
): Promise<string> {
  const combined = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce as unknown as BufferSource, additionalData: associatedData as unknown as BufferSource, tagLength: 128 }, key, utf8.encode(JSON.stringify(plaintext)) as unknown as BufferSource));
  const ciphertext = combined.subarray(0, combined.length - 16);
  const tag = combined.subarray(combined.length - 16);
  const wire = new Uint8Array(28 + ciphertext.length);
  wire.set(nonce, 0); wire.set(tag, 12); wire.set(ciphertext, 28);
  return PREFIX + bytesToBase64(wire);
}

export async function openTaskChainSearch<T>(envelope: string, key: CryptoKey, associatedData: Uint8Array): Promise<T> {
  if (!envelope.startsWith(PREFIX)) throw new ApiError('Invalid encrypted search response', 400, 'invalid_envelope');
  const wire = base64ToBytes(envelope.slice(PREFIX.length));
  if (wire.length < 28) throw new ApiError('Invalid encrypted search response', 400, 'invalid_envelope');
  const combined = new Uint8Array(wire.length - 12);
  combined.set(wire.subarray(28), 0); combined.set(wire.subarray(12, 28), wire.length - 28);
  try {
    const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: wire.subarray(0, 12) as unknown as BufferSource, additionalData: associatedData as unknown as BufferSource, tagLength: 128 }, key, combined as unknown as BufferSource);
    return JSON.parse(text.decode(plain)) as T;
  } catch {
    throw new ApiError('Invalid encrypted search response', 400, 'invalid_envelope');
  }
}

export async function firstValidWithSingleHedge<T>(
  primary: () => Promise<T>,
  backup: (() => Promise<T>) | undefined,
  hedgeDelayMs: number,
  deadlineMs: number,
): Promise<T> {
  let hedgeTimer: ReturnType<typeof setTimeout> | undefined;
  let deadlineTimer: ReturnType<typeof setTimeout> | undefined;
  const attempts: Promise<T>[] = [primary()];
  if (backup) attempts.push(new Promise((resolve, reject) => {
    hedgeTimer = setTimeout(() => backup().then(resolve, reject), hedgeDelayMs);
  }));
  const deadline = new Promise<T>((_, reject) => {
    deadlineTimer = setTimeout(() => reject(new ApiError('Search deadline exceeded', 504, 'deadline_exceeded')), deadlineMs);
  });
  try {
    return await Promise.race([Promise.any(attempts), deadline]);
  } catch (error) {
    throw error instanceof AggregateError ? (error.errors.at(-1) || error) : error;
  } finally {
    if (hedgeTimer) clearTimeout(hedgeTimer);
    if (deadlineTimer) clearTimeout(deadlineTimer);
  }
}

async function relayOne(
  bridgeId: string,
  ownerId: string,
  requestId: string,
  expiresAtMs: number,
  query: string,
  projectId: string,
  status: string,
  limit: number,
  key: CryptoKey,
  signal: AbortSignal,
): Promise<TaskChainSearchResponse> {
  const envelope = await sealTaskChainSearch(
    { request_id: requestId, query, project_id: projectId, status, limit },
    key,
    taskChainSearchAad(ownerId, bridgeId, requestId, 'request', expiresAtMs),
  );
  const response = await fetch(apiUrl('/task-chains/search/relay'), {
    method: 'POST', credentials: 'include', signal,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ bridge_id: bridgeId, request_id: requestId, expires_at_ms: expiresAtMs, envelope }),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new ApiError(String(body?.error?.message || 'Search relay failed'), response.status, body?.error?.code);
  const result = body?.data ?? body;
  if (!result?.ok) throw new ApiError(String(result?.error?.message || result?.error?.cause || 'Search failed'), 409, result?.error?.cause);
  const opened = await openTaskChainSearch<TaskChainSearchResponse>(result.envelope, key, taskChainSearchAad(ownerId, bridgeId, requestId, 'response', expiresAtMs));
  if (opened.request_id !== requestId || opened.bridge_id !== bridgeId) throw new ApiError('Mismatched encrypted search response', 400, 'invalid_envelope');
  return opened;
}

export async function searchTaskChainsEncrypted(
  query: string,
  ownerId: string,
  options: { projectId?: string; status?: string; limit?: number } = {},
): Promise<TaskChainSearchResponse> {
  const trimmed = query.trim();
  if (trimmed.length < 2) throw new ApiError('Enter at least two characters', 400, 'query_too_short');
  const limit = options.limit ?? 20;
  if (limit < 1 || limit > MAX_LIMIT) throw new ApiError('Search limit exceeded', 400, 'limit_exceeded');
  const rawKey = getActiveBridgeVaultKeyMaterial();
  if (!rawKey) throw new ApiError('Vault key unavailable', 423, 'vault_locked');
  const key = await deriveTaskChainSearchKey(rawKey);
  const raw = await cookieJsonFetch('/bridges');
  const bridges: SearchBridge[] = raw?.bridges ?? (Array.isArray(raw) ? raw : []);
  const candidates = bridges.filter((bridge) => {
    const state = String(bridge.status || bridge.runtime_status || '').toLowerCase();
    return state === 'online' && String(bridge.vault_status || '').toLowerCase() === 'unlocked' && bridge.task_chain_search_ready === true && Boolean(bridge.bridge_id || bridge.id);
  }).slice(0, 2);
  if (!candidates.length) throw new ApiError('No unlocked search Bridge is online', 409, 'bridge_offline');

  const requestId = crypto.randomUUID();
  const expiresAtMs = Date.now() + DEADLINE_MS;
  const controllers = candidates.map(() => new AbortController());
  const attempt = (index: number) => relayOne(
    String(candidates[index].bridge_id || candidates[index].id), ownerId, requestId, expiresAtMs,
    trimmed, options.projectId || '', options.status || '', limit, key, controllers[index].signal,
  );
  try {
    return await firstValidWithSingleHedge(
      () => attempt(0),
      candidates.length > 1 ? () => attempt(1) : undefined,
      HEDGE_DELAY_MS,
      DEADLINE_MS,
    );
  } finally {
    controllers.forEach((controller) => controller.abort());
  }
}
