// Zero-Knowledge Vault Transformers for Artifacts
// REQ-VAULT-ARTIFACTS-1

import type { VaultKeyring } from './vaultKeyring.ts';
import {
  isVaultArmored,
  encryptVaultText,
  decryptVaultText,
  base64ToBytes,
  bytesToBase64,
  getActiveVaultKey,
} from './vaultContent.ts';

export interface ArtifactPayload {
  name?: string;
  description?: string;
  content?: string;
  contentBase64?: string;
  [key: string]: any;
}

/**
 * Encrypt artifact content fields (name, description, content / contentBase64)
 * if vault is unlocked using active CryptoKey or key string.
 * Non-content metadata (mime, kind, ext, size, dates) remain plaintext.
 */
export async function encryptArtifactFields<T extends ArtifactPayload>(
  payload: T,
  activeKey?: VaultKeyring | null,
): Promise<T> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey) return { ...payload };
  const res = { ...payload };

  if (res.name && !isVaultArmored(res.name)) {
    res.name = await encryptVaultText(res.name, resolvedKey);
  }

  if (res.description && !isVaultArmored(res.description)) {
    res.description = await encryptVaultText(res.description, resolvedKey);
  }

  if (res.content && !isVaultArmored(res.content)) {
    res.content = await encryptVaultText(res.content, resolvedKey);
    res.contentBase64 = bytesToBase64(new TextEncoder().encode(res.content));
  } else if (res.contentBase64) {
    try {
      const decoded = new TextDecoder('utf-8', { fatal: true }).decode(base64ToBytes(res.contentBase64));
      if (decoded && !isVaultArmored(decoded)) {
        const encrypted = await encryptVaultText(decoded, resolvedKey);
        res.content = encrypted;
        res.contentBase64 = bytesToBase64(new TextEncoder().encode(encrypted));
      }
    } catch {
      // Binary non-UTF8 payload: preserve untouched
    }
  }

  return res;
}

/**
 * Decrypt artifact record fields (name, description, content) using active CryptoKey or key string.
 * Unencrypted/legacy plaintext fields remain untouched.
 */
export async function decryptArtifactRecord<T extends ArtifactPayload>(
  artifact: T,
  activeKey?: VaultKeyring | null,
): Promise<T> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey) return artifact;
  let name = artifact.name;
  let description = artifact.description;
  let content = artifact.content;

  if (name && isVaultArmored(name)) {
    try {
      name = await decryptVaultText(name, resolvedKey);
    } catch {}
  }

  if (description && isVaultArmored(description)) {
    try {
      description = await decryptVaultText(description, resolvedKey);
    } catch {}
  }

  if (content && isVaultArmored(content)) {
    try {
      content = await decryptVaultText(content, resolvedKey);
    } catch {}
  }

  return {
    ...artifact,
    name,
    description,
    ...(content !== undefined ? { content } : {}),
  };
}

/**
 * Transparently decrypt raw text content if armored and vault key is provided.
 */
export async function decryptArtifactText(
  text: string,
  activeKey?: VaultKeyring | null,
): Promise<string> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey || !text || !isVaultArmored(text)) return text;
  try {
    return await decryptVaultText(text, resolvedKey);
  } catch {
    return text;
  }
}
