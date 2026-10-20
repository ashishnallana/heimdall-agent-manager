// Zero-Knowledge Vault Content Cryptography & Declarative Transformers
// Implements armored envelope wire format 'vault:v2:e<epoch>:<base64(12B_nonce + 16B_tag + ciphertext)>',
// transparent unarmored fallback, and declarative field/list transformers.
// REQ-VAULT-CONTENT-LIB-1, REQ-VAULT-HARDEN-1

export {
  VAULT_ARMOR_PREFIX,
  MIN_ARMOR_PAYLOAD_BYTES,
  isVaultArmored,
  containsVaultArmored,
  isValidBase64,
  bytesToBase64,
  base64ToBytes,
  resolveKeyring,
  encryptVaultText,
  decryptVaultText,
  getActiveVaultKey,
  setActiveVaultKey,
  VAULT_TOKEN_RE,
  VAULT_LOCKED_MARKER,
  replaceVaultTokens,
  findVaultTokens,
} from './vaultCrypto.ts';

import { isVaultArmored, containsVaultArmored, resolveKeyring, decryptVaultText, getActiveVaultKey, findVaultTokens, replaceVaultTokens, VAULT_LOCKED_MARKER, type VaultKeyring } from './vaultCrypto.ts';

/** Placeholder substituted for vault-armored text that is not available in plaintext. */
export const VAULT_MASK_PLACEHOLDER = VAULT_LOCKED_MARKER;

/**
 * Replace every armored vault token in `value` with the locked placeholder.
 *
 * It is a mask, never a decrypt -- it only ever removes information. Use it for any
 * surface that must not leak ciphertext, notably `aria-label` and other accessible
 * names: the common `useState(raw)` + mask-in-`useEffect` pattern leaves a token in
 * the committed DOM until effects flush, and an accessible name is exactly where a
 * brief leak goes unnoticed -- invisible to both a screenshot and a text-content
 * assertion.
 *
 * Single definition for the app. Previously duplicated as `maskVaultArmored` in
 * `api/endpoints/memory.ts` and `maskVaultTokens` in `components/vault/VaultText.tsx`.
 */
export function maskVaultArmored(value: string): string {
  return replaceVaultTokens(value, VAULT_MASK_PLACEHOLDER);
}

/**
 * Decrypt every embedded v2 vault token (VAULT_TOKEN_RE) found inside a string.
 * Tokens that decrypt are replaced with their plaintext; tokens of an epoch this
 * keyring does not hold become the locked marker; tokens that fail to authenticate
 * become the mask placeholder. Surrounding text is preserved.
 *
 * @param text The input string potentially containing one or more embedded vault tokens.
 * @param keyring The keyring to use, or the active keyring.
 */
export async function decryptEmbeddedVaultTokens(
  text: string,
  keyring?: VaultKeyring | null,
): Promise<string> {
  if (typeof text !== 'string' || !containsVaultArmored(text)) {
    return text;
  }

  // No keyring anywhere: return text as-is without throwing
  const kr = keyring ?? getActiveVaultKey();
  if (!kr) {
    return text;
  }

  const matches = findVaultTokens(text);
  if (matches.length === 0) {
    return text;
  }

  const uniqueTokens = Array.from(new Set(matches));

  const replacements = await Promise.all(
    uniqueTokens.map(async (token) => {
      try {
        const decrypted = await decryptVaultText(token, kr);
        return { token, decrypted };
      } catch {
        return { token, decrypted: VAULT_MASK_PLACEHOLDER };
      }
    }),
  );

  let result = text;
  for (const { token, decrypted } of replacements) {
    if (token !== decrypted) {
      result = result.split(token).join(decrypted);
    }
  }
  return result;
}

/**
 * Plaintext for copying a message body to the clipboard: never the raw ciphertext.
 *
 * Armored and embedded vault tokens are decrypted with `key`; any token that cannot be
 * decrypted (no key, wrong key, corrupt payload) is masked with the locked placeholder.
 * Unencrypted bodies are returned unchanged.
 */
export async function resolveCopyableVaultText(
  text: string,
  key?: VaultKeyring | null,
): Promise<string> {
  if (typeof text !== 'string' || !containsVaultArmored(text)) return text;
  let result = text;
  if (key) {
    try {
      result = isVaultArmored(text)
        ? await decryptVaultText(text, key)
        : await decryptEmbeddedVaultTokens(text, key);
    } catch {
      result = text;
    }
  }
  return maskVaultArmored(result);
}

/**
 * Declarative object transformer: decrypts specified string fields of an object.
 * Non-targeted fields and unarmored fields are preserved intact (transparent fallback).
 *
 * @param data Target object.
 * @param fields List of keys to decrypt.
 * @param key The keyring, or fallback to the active keyring.
 */
export async function decryptFields<T>(
  data: T,
  fields: (keyof T)[],
  key?: VaultKeyring | null,
): Promise<T> {
  if (data == null || typeof data !== 'object') {
    return data;
  }

  const cryptoKey = await resolveKeyring(key);
  const result = (Array.isArray(data) ? [...data] : { ...data }) as T;

  for (const field of fields) {
    const val = (result as Record<string, unknown>)[field as string];
    if (typeof val === 'string' && isVaultArmored(val)) {
      (result as Record<string, unknown>)[field as string] = await decryptVaultText(val, cryptoKey);
    }
  }

  return result;
}

/**
 * Declarative array transformer: decrypts specified string fields for each object in an array.
 *
 * @param items Array of target objects.
 * @param fields List of keys to decrypt on each item.
 * @param key The keyring, or fallback to the active keyring.
 */
export async function decryptList<T>(
  items: T[],
  fields: (keyof T)[],
  key?: VaultKeyring | null,
): Promise<T[]> {
  if (!Array.isArray(items)) {
    return [];
  }
  const cryptoKey = await resolveKeyring(key);
  return await Promise.all(items.map((item) => decryptFields(item, fields, cryptoKey)));
}
