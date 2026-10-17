import { ApiError } from '../api/cookieFetch';

export const TASK_CHAIN_SEARCH_KEY_DOMAIN = 'heimdall/task-chain-search-rpc/v1';

const utf8 = new TextEncoder();
let activeTaskChainSearchKey: CryptoKey | null = null;
let pendingTaskChainSearchKey: Promise<CryptoKey> | null = null;
let keyGeneration = 0;

function rawHexToBytes(value: string): Uint8Array {
  if (!/^[0-9a-f]{64}$/i.test(value)) {
    throw new ApiError('Vault key unavailable', 423, 'vault_locked');
  }
  return Uint8Array.from(value.match(/../g)!, (part) => Number.parseInt(part, 16));
}

export async function deriveTaskChainSearchKey(rawHex: string): Promise<CryptoKey> {
  const bytes = rawHexToBytes(rawHex);
  try {
    const material = await crypto.subtle.importKey(
      'raw',
      bytes as unknown as BufferSource,
      'HKDF',
      false,
      ['deriveKey'],
    );
    const domain = utf8.encode(TASK_CHAIN_SEARCH_KEY_DOMAIN);
    return await crypto.subtle.deriveKey(
      {
        name: 'HKDF',
        hash: 'SHA-256',
        salt: domain as unknown as BufferSource,
        info: domain as unknown as BufferSource,
      },
      material,
      { name: 'AES-GCM', length: 256 },
      false,
      ['encrypt', 'decrypt'],
    );
  } finally {
    bytes.fill(0);
  }
}

export function getActiveTaskChainSearchKey(): CryptoKey | null {
  return activeTaskChainSearchKey;
}

export function setActiveTaskChainSearchKey(key: CryptoKey | null): void {
  keyGeneration += 1;
  pendingTaskChainSearchKey = null;
  activeTaskChainSearchKey = key;
}

export function clearActiveTaskChainSearchKey(): void {
  setActiveTaskChainSearchKey(null);
}

export function beginTaskChainSearchKeyDerivation(rawHex: string): Promise<CryptoKey> {
  const generation = ++keyGeneration;
  activeTaskChainSearchKey = null;
  const pending = deriveTaskChainSearchKey(rawHex).then((key) => {
    if (keyGeneration === generation) {
      activeTaskChainSearchKey = key;
      pendingTaskChainSearchKey = null;
    }
    return key;
  }, (error) => {
    if (keyGeneration === generation) pendingTaskChainSearchKey = null;
    throw error;
  });
  pendingTaskChainSearchKey = pending;
  return pending;
}

export async function waitForActiveTaskChainSearchKey(): Promise<CryptoKey | null> {
  if (activeTaskChainSearchKey) return activeTaskChainSearchKey;
  if (!pendingTaskChainSearchKey) return null;
  await pendingTaskChainSearchKey;
  return activeTaskChainSearchKey;
}
