// Zero-Knowledge Vault Transformers for Memories
// REQ-VAULT-MEMORIES-1

import type { VaultKeyring } from './vaultKeyring.ts';
import { isVaultArmored, encryptVaultText, decryptVaultText, getActiveVaultKey } from './vaultContent.ts';

export interface MemoryPayload {
  title?: string;
  description?: string;
  body?: string;
  evidence?: string;
  [key: string]: any;
}

/**
 * Encrypt memory content fields (title, description, body, evidence) if vault is unlocked using active CryptoKey or key string.
 */
export async function encryptMemoryFields<T extends MemoryPayload>(
  payload: T,
  activeKey?: VaultKeyring | null,
): Promise<T> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey) return { ...payload };
  const res = { ...payload };
  if (res.title && !isVaultArmored(res.title)) {
    res.title = await encryptVaultText(res.title, resolvedKey);
  }
  if (res.description && !isVaultArmored(res.description)) {
    res.description = await encryptVaultText(res.description, resolvedKey);
  }
  if (res.body && !isVaultArmored(res.body)) {
    res.body = await encryptVaultText(res.body, resolvedKey);
  }
  if (res.evidence && !isVaultArmored(res.evidence)) {
    res.evidence = await encryptVaultText(res.evidence, resolvedKey);
  }
  return res;
}

/**
 * Decrypt memory content fields (title, description, body, evidence) using active CryptoKey or key string.
 */
export async function decryptMemoryRecord<T extends MemoryPayload>(
  memory: T,
  activeKey?: VaultKeyring | null,
): Promise<T> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey) return memory;
  let title = memory.title;
  let description = memory.description;
  let body = memory.body;
  let evidence = memory.evidence;

  if (title && isVaultArmored(title)) {
    try {
      title = await decryptVaultText(title, resolvedKey);
    } catch {}
  }
  if (description && isVaultArmored(description)) {
    try {
      description = await decryptVaultText(description, resolvedKey);
    } catch {}
  }
  if (body && isVaultArmored(body)) {
    try {
      body = await decryptVaultText(body, resolvedKey);
    } catch {}
  }
  if (evidence && isVaultArmored(evidence)) {
    try {
      evidence = await decryptVaultText(evidence, resolvedKey);
    } catch {}
  }

  return {
    ...memory,
    title,
    description,
    body,
    evidence,
  };
}
