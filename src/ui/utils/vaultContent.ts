// Zero-Knowledge Vault Content Cryptography & Declarative Transformers
// Implements armored envelope wire format 'vault:v1:<base64(12B_nonce + 16B_tag + ciphertext)>',
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
  resolveCryptoKey,
  encryptVaultText,
  decryptVaultText,
  getActiveVaultKey,
  setActiveVaultKey,
} from './vaultCrypto.ts';

import {
  isVaultArmored,
  containsVaultArmored,
  resolveCryptoKey,
  encryptVaultText,
  decryptVaultText,
  getActiveVaultKey,
} from './vaultCrypto.ts';

/** Placeholder substituted for vault-armored text that is not available in plaintext. */
export const VAULT_MASK_PLACEHOLDER = '[🔒 Encrypted]';

/** Matches one armored vault token. Module-scoped; only ever used with `String.replace`,
 *  which resets `lastIndex`, so the `g` flag carries no state between calls. */
const VAULT_ARMORED_TOKEN_RE = /vault:v1:[A-Za-z0-9+/=_-]+/g;

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
  return value.replace(VAULT_ARMORED_TOKEN_RE, VAULT_MASK_PLACEHOLDER);
}

/**
 * Decrypt any embedded vault armored tokens (/vault:v1:[A-Za-z0-9+/=]+/) found inside a string.
 * Tokens that successfully decrypt are replaced with their plaintext; tokens that fail
 * decryption or non-token surrounding text are preserved intact.
 *
 * @param text The input string potentially containing one or more embedded vault tokens.
 * @param key The vault key as a 64-character hex string, CryptoKey, or fallback to active vault key.
 */
export async function decryptEmbeddedVaultTokens(
  text: string,
  key?: string | CryptoKey | null,
): Promise<string> {
  if (typeof text !== 'string' || !containsVaultArmored(text)) {
    return text;
  }

  // If explicit empty key or no key available anywhere, return text as-is without throwing
  if (key === '' || (!key && !getActiveVaultKey())) {
    return text;
  }

  let cryptoKey: CryptoKey;
  try {
    cryptoKey = await resolveCryptoKey(key);
  } catch {
    return text;
  }

  const matches = text.match(/vault:v1:[A-Za-z0-9+/=_-]+/g);
  if (!matches || matches.length === 0) {
    return text;
  }

  const uniqueTokens = Array.from(new Set(matches));

  const replacements = await Promise.all(
    uniqueTokens.map(async (token) => {
      try {
        const decrypted = await decryptVaultText(token, cryptoKey);
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
  key?: string | CryptoKey | null,
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
 * Declarative object transformer: encrypts specified string fields of an object in-place or clone.
 * Unencrypted/non-targeted fields and already-armored fields are preserved intact.
 *
 * @param data Target object.
 * @param fields List of keys to encrypt.
 * @param key The vault key as a 64-char hex string, CryptoKey, or fallback to active key.
 */
export async function encryptFields<T>(
  data: T,
  fields: (keyof T)[],
  key?: string | CryptoKey | null,
): Promise<T> {
  if (data == null || typeof data !== 'object') {
    return data;
  }

  const cryptoKey = await resolveCryptoKey(key);
  const result = (Array.isArray(data) ? [...data] : { ...data }) as T;

  for (const field of fields) {
    const val = (result as Record<string, unknown>)[field as string];
    if (typeof val === 'string' && !isVaultArmored(val)) {
      (result as Record<string, unknown>)[field as string] = await encryptVaultText(val, cryptoKey);
    }
  }

  return result;
}

/**
 * Declarative object transformer: decrypts specified string fields of an object.
 * Non-targeted fields and unarmored fields are preserved intact (transparent fallback).
 *
 * @param data Target object.
 * @param fields List of keys to decrypt.
 * @param key The vault key as a 64-char hex string, CryptoKey, or fallback to active key.
 */
export async function decryptFields<T>(
  data: T,
  fields: (keyof T)[],
  key?: string | CryptoKey | null,
): Promise<T> {
  if (data == null || typeof data !== 'object') {
    return data;
  }

  const cryptoKey = await resolveCryptoKey(key);
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
 * @param key The vault key as a 64-char hex string, CryptoKey, or fallback to active key.
 */
export async function decryptList<T>(
  items: T[],
  fields: (keyof T)[],
  key?: string | CryptoKey | null,
): Promise<T[]> {
  if (!Array.isArray(items)) {
    return [];
  }
  const cryptoKey = await resolveCryptoKey(key);
  return await Promise.all(items.map((item) => decryptFields(item, fields, cryptoKey)));
}

/**
 * Declarative array transformer: encrypts specified string fields for each object in an array.
 *
 * @param items Array of target objects.
 * @param fields List of keys to encrypt on each item.
 * @param key The vault key as a 64-char hex string, CryptoKey, or fallback to active key.
 */
export async function encryptList<T>(
  items: T[],
  fields: (keyof T)[],
  key?: string | CryptoKey | null,
): Promise<T[]> {
  if (!Array.isArray(items)) {
    return [];
  }
  const cryptoKey = await resolveCryptoKey(key);
  return await Promise.all(items.map((item) => encryptFields(item, fields, cryptoKey)));
}
