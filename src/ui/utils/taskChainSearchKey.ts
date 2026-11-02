import { ApiError } from '../api/cookieFetch.ts';

/**
 * Search key v2 (docs/plans/passwordless-vault.md §1): per epoch,
 * HKDF-SHA256(ikm = epoch key, salt = DOMAIN, info = `${DOMAIN}|e<epoch>`). The
 * bridge accepts search RPCs only under its current epoch.
 */
export const TASK_CHAIN_SEARCH_KEY_DOMAIN = 'heimdall/task-chain-search-rpc/v2';

/** A derived search key and the epoch it belongs to. */
export interface TaskChainSearchKey {
  readonly epoch: number;
  readonly key: CryptoKey;
}

const utf8 = new TextEncoder();
let activeTaskChainSearchKey: TaskChainSearchKey | null = null;
let pendingTaskChainSearchKey: Promise<TaskChainSearchKey> | null = null;
let keyGeneration = 0;

function epochKeyBytes(material: string | Uint8Array): Uint8Array {
  if (material instanceof Uint8Array) {
    if (material.length !== 32) throw new ApiError('Vault key unavailable', 423, 'vault_locked');
    return Uint8Array.from(material);
  }
  if (!/^[0-9a-f]{64}$/i.test(material)) {
    throw new ApiError('Vault key unavailable', 423, 'vault_locked');
  }
  return Uint8Array.from(material.match(/../g)!, (part) => Number.parseInt(part, 16));
}

/** Derive the epoch's search key. The transient copy of the epoch key is zeroed. */
export async function deriveTaskChainSearchKey(epochKey: string | Uint8Array, epoch: number): Promise<TaskChainSearchKey> {
  if (!Number.isInteger(epoch) || epoch < 1 || epoch > 0xffffffff) throw new ApiError('Vault key unavailable', 423, 'vault_locked');
  const bytes = epochKeyBytes(epochKey);
  try {
    const material = await crypto.subtle.importKey('raw', bytes as unknown as BufferSource, 'HKDF', false, ['deriveKey']);
    const key = await crypto.subtle.deriveKey(
      {
        name: 'HKDF',
        hash: 'SHA-256',
        salt: utf8.encode(TASK_CHAIN_SEARCH_KEY_DOMAIN) as unknown as BufferSource,
        info: utf8.encode(`${TASK_CHAIN_SEARCH_KEY_DOMAIN}|e${epoch}`) as unknown as BufferSource,
      },
      material,
      { name: 'AES-GCM', length: 256 },
      false,
      ['encrypt', 'decrypt'],
    );
    return Object.freeze({ epoch, key });
  } finally {
    bytes.fill(0);
  }
}

export function getActiveTaskChainSearchKey(): TaskChainSearchKey | null {
  return activeTaskChainSearchKey;
}

export function setActiveTaskChainSearchKey(key: TaskChainSearchKey | null): void {
  keyGeneration += 1;
  pendingTaskChainSearchKey = null;
  activeTaskChainSearchKey = key;
}

export function clearActiveTaskChainSearchKey(): void {
  setActiveTaskChainSearchKey(null);
}

export async function waitForActiveTaskChainSearchKey(): Promise<TaskChainSearchKey | null> {
  if (activeTaskChainSearchKey) return activeTaskChainSearchKey;
  if (!pendingTaskChainSearchKey) return null;
  await pendingTaskChainSearchKey;
  return activeTaskChainSearchKey;
}
