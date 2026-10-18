// Zero-Knowledge Vault Transformers for Task Chains
// REQ-VAULT-CHAINS-1

import type { VaultKeyring } from './vaultKeyring.ts';
import { isVaultArmored, encryptVaultText, decryptVaultText, getActiveVaultKey } from './vaultContent.ts';

export interface ChainPayload {
  title?: string;
  description?: string;
  [key: string]: any;
}

/**
 * Encrypt chain fields (title, description) if vault is unlocked using active CryptoKey or key string.
 */
export async function encryptChainFields<T extends ChainPayload>(
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
  return res;
}

/**
 * Decrypt chain fields (title, description, description_preview) using active CryptoKey or key string.
 * If vault is locked or key is not provided, leaves armored strings as-is (graceful fallback).
 */
export async function decryptChainRecord<T extends ChainPayload>(
  chain: T,
  activeKey?: VaultKeyring | null,
): Promise<T> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey) return chain;
  let title = chain.title;
  let description = chain.description;
  let descriptionPreview = (chain as any).descriptionPreview || (chain as any).description_preview;

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
  if (descriptionPreview && isVaultArmored(descriptionPreview)) {
    try {
      descriptionPreview = await decryptVaultText(descriptionPreview, resolvedKey);
    } catch {}
  }

  return {
    ...chain,
    title,
    description,
    descriptionPreview,
    description_preview: descriptionPreview,
  };
}

/**
 * Decrypt an array of chain records.
 */
export async function decryptChainList<T extends ChainPayload>(
  chains: T[],
  activeKey?: VaultKeyring | null,
): Promise<T[]> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey || !Array.isArray(chains)) return chains;
  return Promise.all(chains.map((chain) => decryptChainRecord(chain, resolvedKey)));
}
