// Zero-Knowledge WebCrypto Vault Client Library
// Implements 256-bit AES-GCM vault key generation, PBKDF2 key derivation,
// BIP-39 12-word mnemonic recovery phrase generation, envelope wrapping/unwrapping,
// non-extractable CryptoKey management, and transient memory zeroing.
// REQ-VAULT-HARDEN-1, REQ-VAULT-HARDEN-2

import { BIP39_WORDS } from './bip39Words.ts';
import { clearActiveTaskChainSearchKey } from './taskChainSearchKey.ts';

export const DEFAULT_KDF_ITERATIONS = 100_000;
export const AES_GCM_KEY_LENGTH = 256;
export const AES_GCM_NONCE_BYTES = 12;
export const AES_GCM_TAG_BYTES = 16;
export const VAULT_KEY_BYTES = 32;
export const RECOVERY_ENTROPY_BYTES = 16;

export const VAULT_ARMOR_PREFIX = 'vault:v1:';
export const MIN_ARMOR_PAYLOAD_BYTES = AES_GCM_NONCE_BYTES + AES_GCM_TAG_BYTES; // 28 bytes

// Module-scoped active CryptoKey reference (in-memory C++ browser reference).
//
// The active key and the optional bridge-delivery material have separate setters on
// purpose. Replacing the key always clears the delivery material, so raw bytes from
// a previous vault can never be paired with a newer CryptoKey. Callers that obtained
// both values install the key first and then its matching raw material.
let activeVaultCryptoKey: CryptoKey | null = null;
let activeBridgeVaultKeyHex: string | null = null;

export function getActiveVaultKey(): CryptoKey | null {
  return activeVaultCryptoKey;
}

/**
 * Raw key material retained in memory only for the lifetime of an explicitly
 * unlocked browser session, so adding a bridge does not ask for the same master
 * password again. It is never written to Redux, sessionStorage, or IndexedDB.
 */
export function getActiveBridgeVaultKeyMaterial(): string | null {
  return activeBridgeVaultKeyHex;
}

export function setActiveBridgeVaultKeyMaterial(rawHex: string | null): void {
  const clean = String(rawHex || '').trim().toLowerCase();
  activeBridgeVaultKeyHex = /^[0-9a-f]{64}$/.test(clean) ? clean : null;
}

/**
 * Install (or, with `null`, purge) the active vault key.
 *
 * This remains a one-parameter API so every key replacement unconditionally
 * invalidates bridge-delivery material from the previous key.
 */
export function setActiveVaultKey(key: CryptoKey | null): void {
  activeVaultCryptoKey = key;
  // Every key replacement invalidates any material associated with the prior
  // key. A caller that has matching raw material must install it explicitly.
  activeBridgeVaultKeyHex = null;
  clearActiveTaskChainSearchKey();
}

/** Check if a string is armored with the vault content encryption prefix */
export function isVaultArmored(text: unknown): boolean {
  return typeof text === 'string' && text.startsWith(VAULT_ARMOR_PREFIX);
}

/** Check if a string contains any vault armored token */
export function containsVaultArmored(text: unknown): boolean {
  return typeof text === 'string' && /vault:v1:[A-Za-z0-9+/=_-]+/.test(text);
}

/** Validate standard base64 string syntax */
export function isValidBase64(str: string): boolean {
  if (!str || str.length % 4 !== 0) return false;
  return /^[A-Za-z0-9+/]+={0,2}$/.test(str);
}

/** Convert Uint8Array to base64 string across browser and Node.js environments */
export function bytesToBase64(bytes: Uint8Array): string {
  if (typeof Buffer !== 'undefined') {
    return Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString('base64');
  }
  let binary = '';
  const chunkSize = 8192;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    const chunk = bytes.subarray(i, Math.min(i + chunkSize, bytes.length));
    binary += String.fromCharCode.apply(null, Array.from(chunk));
  }
  return btoa(binary);
}

/** Convert base64 string to Uint8Array across browser and Node.js environments */
export function base64ToBytes(base64: string): Uint8Array {
  if (typeof Buffer !== 'undefined') {
    const buf = Buffer.from(base64, 'base64');
    return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
  }
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/** Convert Uint8Array to lowercase hex string */
export function bytesToHex(bytes: Uint8Array): string {
  let hex = '';
  for (let i = 0; i < bytes.length; i++) {
    hex += bytes[i].toString(16).padStart(2, '0');
  }
  return hex;
}

/** Convert hex string to Uint8Array */
export function hexToBytes(hex: string): Uint8Array {
  const clean = hex.trim().toLowerCase();
  if (clean.length % 2 !== 0) {
    throw new Error(`Hex string must have an even length, got length ${clean.length}`);
  }
  if (!/^[0-9a-f]*$/.test(clean)) {
    throw new Error(`Invalid hex character in string: ${hex}`);
  }
  const bytes = new Uint8Array(clean.length / 2);
  for (let i = 0; i < clean.length; i += 2) {
    bytes[i / 2] = parseInt(clean.substring(i, i + 2), 16);
  }
  return bytes;
}

/** Generate cryptographically random salt in hex format (default 16 bytes = 32 hex chars) */
export function generateSaltHex(byteLength = 16): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteLength));
  return bytesToHex(bytes);
}

/** Generate cryptographically random AES-GCM nonce in hex format (default 12 bytes = 24 hex chars) */
export function generateNonceHex(byteLength = AES_GCM_NONCE_BYTES): string {
  const bytes = crypto.getRandomValues(new Uint8Array(byteLength));
  return bytesToHex(bytes);
}

/**
 * Pure synchronous SHA-256 implementation for 16-byte entropy checksums.
 * Ensures generate12RecoveryWords() can return synchronously without async Promise overhead.
 */
function sha256Sync(bytes: Uint8Array): Uint8Array {
  const K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  const H = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  const l = bytes.length;
  const bitLen = l * 8;
  const withPad = new Uint8Array(((l + 8 + 64) >> 6) << 6);
  withPad.set(bytes);
  withPad[l] = 0x80;
  const view = new DataView(withPad.buffer);
  view.setUint32(withPad.length - 4, bitLen, false);

  const W = new Int32Array(64);
  const rotr = (x: number, n: number) => (x >>> n) | (x << (32 - n));

  for (let i = 0; i < withPad.length; i += 64) {
    for (let t = 0; t < 16; t++) {
      W[t] = view.getUint32(i + t * 4, false);
    }
    for (let t = 16; t < 64; t++) {
      const s0 = rotr(W[t - 15], 7) ^ rotr(W[t - 15], 18) ^ (W[t - 15] >>> 3);
      const s1 = rotr(W[t - 2], 17) ^ rotr(W[t - 2], 19) ^ (W[t - 2] >>> 10);
      W[t] = (W[t - 16] + s0 + W[t - 7] + s1) | 0;
    }
    let [a, b, c, d, e, f, g, h] = H;
    for (let t = 0; t < 64; t++) {
      const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const temp1 = (h + S1 + ch + K[t] + W[t]) | 0;
      const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (S0 + maj) | 0;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) | 0;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) | 0;
    }
    H[0] = (H[0] + a) | 0;
    H[1] = (H[1] + b) | 0;
    H[2] = (H[2] + c) | 0;
    H[3] = (H[3] + d) | 0;
    H[4] = (H[4] + e) | 0;
    H[5] = (H[5] + f) | 0;
    H[6] = (H[6] + g) | 0;
    H[7] = (H[7] + h) | 0;
  }

  const out = new Uint8Array(32);
  const outView = new DataView(out.buffer);
  for (let i = 0; i < 8; i++) {
    outView.setUint32(i * 4, H[i], false);
  }
  return out;
}

const wordToBip39IndexMap = new Map<string, number>();
BIP39_WORDS.forEach((word, idx) => {
  wordToBip39IndexMap.set(word, idx);
});

/**
 * Whether SubtleCrypto is actually available in this context (REQ-VAULT-UNSUP-1).
 */
export function isVaultSupported(): boolean {
  return typeof globalThis.crypto?.subtle?.generateKey === 'function';
}

/**
 * Generate a new 256-bit symmetric AES-GCM Vault Key (KV).
 * Kept extractable during setup wizard so it can be wrapped into envelopes.
 */
export async function generateVaultKey(): Promise<CryptoKey> {
  return await crypto.subtle.generateKey(
    { name: 'AES-GCM', length: AES_GCM_KEY_LENGTH },
    true,
    ['encrypt', 'decrypt'],
  );
}

/**
 * Export raw key bytes as a 64-character lowercase hex string.
 * Calling this on a non-extractable key throws InvalidAccessError.
 */
export async function exportRawKeyHex(key: CryptoKey): Promise<string> {
  const raw = await crypto.subtle.exportKey('raw', key);
  return bytesToHex(new Uint8Array(raw));
}

/**
 * Import a 256-bit AES-GCM key from a 64-character hex string.
 * By default imports with extractable: false (non-extractable) to prevent JS exfiltration (REQ-VAULT-HARDEN-1).
 * Immediately and securely wipes the transient byte buffer with .fill(0).
 */
export async function importRawKeyHex(hex: string, extractable = false): Promise<CryptoKey> {
  const bytes = hexToBytes(hex);
  if (bytes.length !== VAULT_KEY_BYTES) {
    bytes.fill(0);
    throw new Error(
      `Invalid vault key length: expected ${VAULT_KEY_BYTES} bytes (64 hex characters), got ${bytes.length} bytes`,
    );
  }
  try {
    return await crypto.subtle.importKey(
      'raw',
      bytes as unknown as BufferSource,
      { name: 'AES-GCM', length: AES_GCM_KEY_LENGTH },
      extractable,
      ['encrypt', 'decrypt'],
    );
  } finally {
    // Securely wipe transient Uint8Array buffers using .fill(0) immediately after import
    bytes.fill(0);
  }
}

/**
 * Derive a 256-bit AES-GCM key from a master password using PBKDF2-SHA256.
 * Generates key with extractable: false by default (REQ-VAULT-HARDEN-1).
 * Securely wipes transient passwordBytes and saltBytes with .fill(0).
 */
export async function deriveKeyFromPassword(
  password: string,
  saltHex: string,
  iterations: number = DEFAULT_KDF_ITERATIONS,
  extractable = false,
): Promise<CryptoKey> {
  const enc = new TextEncoder();
  const passwordBytes = enc.encode(password);
  const saltBytes = hexToBytes(saltHex);

  try {
    const baseKey = await crypto.subtle.importKey(
      'raw',
      passwordBytes as unknown as BufferSource,
      { name: 'PBKDF2' },
      false,
      ['deriveKey', 'deriveBits'],
    );

    return await crypto.subtle.deriveKey(
      {
        name: 'PBKDF2',
        salt: saltBytes as unknown as BufferSource,
        iterations,
        hash: 'SHA-256',
      },
      baseKey,
      { name: 'AES-GCM', length: AES_GCM_KEY_LENGTH },
      extractable,
      ['encrypt', 'decrypt'],
    );
  } finally {
    passwordBytes.fill(0);
    saltBytes.fill(0);
  }
}

/**
 * Generate 12 BIP-39 mnemonic recovery words from 128-bit cryptographically secure entropy.
 */
export function generate12RecoveryWords(entropyBytes?: Uint8Array): {
  words: string[];
  entropyHex: string;
} {
  const entropy = entropyBytes ?? crypto.getRandomValues(new Uint8Array(RECOVERY_ENTROPY_BYTES));
  if (entropy.length !== RECOVERY_ENTROPY_BYTES) {
    throw new Error(`Expected 16 bytes of entropy for 12 BIP-39 words, got ${entropy.length}`);
  }

  const hash = sha256Sync(entropy);
  const checksumBits = (hash[0] >> 4).toString(2).padStart(4, '0');

  let bits = '';
  for (let i = 0; i < entropy.length; i++) {
    bits += entropy[i].toString(2).padStart(8, '0');
  }
  bits += checksumBits;

  const words: string[] = [];
  for (let i = 0; i < 12; i++) {
    const chunk = bits.slice(i * 11, (i + 1) * 11);
    const index = parseInt(chunk, 2);
    words.push(BIP39_WORDS[index]);
  }

  return {
    words,
    entropyHex: bytesToHex(entropy),
  };
}

/**
 * Validate that a list of words forms a valid 12-word BIP-39 mnemonic with a matching checksum.
 */
export function validateRecoveryWords(words: string[]): boolean {
  if (!Array.isArray(words) || words.length !== 12) {
    return false;
  }
  let bits = '';
  for (const word of words) {
    const cleanWord = word.trim().toLowerCase();
    const idx = wordToBip39IndexMap.get(cleanWord);
    if (idx === undefined) {
      return false;
    }
    bits += idx.toString(2).padStart(11, '0');
  }

  const entropyBits = bits.slice(0, 128);
  const checksumBits = bits.slice(128, 132);

  const entropyBytes = new Uint8Array(16);
  for (let i = 0; i < 16; i++) {
    entropyBytes[i] = parseInt(entropyBits.slice(i * 8, (i + 1) * 8), 2);
  }

  const hash = sha256Sync(entropyBytes);
  const expectedChecksumBits = (hash[0] >> 4).toString(2).padStart(4, '0');
  return checksumBits === expectedChecksumBits;
}

/**
 * Derive a 256-bit AES-GCM recovery key (KR) from 12 recovery words and a recovery salt.
 */
export async function deriveKeyFromRecoveryWords(
  words: string[],
  saltHex: string,
  iterations: number = DEFAULT_KDF_ITERATIONS,
  extractable = false,
): Promise<CryptoKey> {
  const normalizedPhrase = words.map((w) => w.trim().toLowerCase()).join(' ');
  return await deriveKeyFromPassword(normalizedPhrase, saltHex, iterations, extractable);
}

/**
 * Encrypt the raw 256-bit vaultKey using wrappingKey (AES-GCM).
 */
export async function encryptVaultKeyEnvelope(
  wrappingKey: CryptoKey,
  vaultKey: CryptoKey,
): Promise<{ ciphertextHex: string; nonceHex: string; tagHex: string }> {
  const rawVaultKey = await crypto.subtle.exportKey('raw', vaultKey);
  const nonce = crypto.getRandomValues(new Uint8Array(AES_GCM_NONCE_BYTES));

  const encrypted = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: nonce as unknown as BufferSource, tagLength: 128 },
    wrappingKey,
    rawVaultKey,
  );

  const encryptedBytes = new Uint8Array(encrypted);
  const ciphertextBytes = encryptedBytes.slice(0, encryptedBytes.length - AES_GCM_TAG_BYTES);
  const tagBytes = encryptedBytes.slice(encryptedBytes.length - AES_GCM_TAG_BYTES);

  return {
    ciphertextHex: bytesToHex(ciphertextBytes),
    nonceHex: bytesToHex(nonce),
    tagHex: bytesToHex(tagBytes),
  };
}

/**
 * Decrypt a vault key envelope using wrappingKey (AES-GCM) and reconstruct the Vault Key (KV).
 * By default imports with extractable: false to ensure the decrypted key cannot be exfiltrated.
 * Securely wipes transient decrypted raw buffers.
 */
export async function decryptVaultKeyEnvelope(
  wrappingKey: CryptoKey,
  ciphertextHex: string,
  nonceHex: string,
  tagHex: string,
  extractable = false,
): Promise<CryptoKey> {
  const ciphertextBytes = hexToBytes(ciphertextHex);
  const nonceBytes = hexToBytes(nonceHex);
  const tagBytes = hexToBytes(tagHex);

  const combined = new Uint8Array(ciphertextBytes.length + tagBytes.length);
  combined.set(ciphertextBytes, 0);
  combined.set(tagBytes, ciphertextBytes.length);

  try {
    const decryptedRaw = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: nonceBytes as unknown as BufferSource, tagLength: 128 },
      wrappingKey,
      combined as unknown as BufferSource,
    );

    const decryptedBytes = new Uint8Array(decryptedRaw);
    try {
      return await crypto.subtle.importKey(
        'raw',
        decryptedBytes as unknown as BufferSource,
        { name: 'AES-GCM', length: AES_GCM_KEY_LENGTH },
        extractable,
        ['encrypt', 'decrypt'],
      );
    } finally {
      decryptedBytes.fill(0);
    }
  } finally {
    ciphertextBytes.fill(0);
    nonceBytes.fill(0);
    tagBytes.fill(0);
    combined.fill(0);
  }
}

/**
 * Decrypts vault key envelope and returns raw 64-character hex string.
 * Used to unseal bridges and populate Redux vault key safely.
 */
export async function decryptVaultKeyEnvelopeHex(
  wrappingKey: CryptoKey,
  ciphertextHex: string,
  nonceHex: string,
  tagHex: string,
): Promise<string> {
  const ciphertextBytes = hexToBytes(ciphertextHex);
  const nonceBytes = hexToBytes(nonceHex);
  const tagBytes = hexToBytes(tagHex);

  const combined = new Uint8Array(ciphertextBytes.length + tagBytes.length);
  combined.set(ciphertextBytes, 0);
  combined.set(tagBytes, ciphertextBytes.length);

  try {
    const decryptedRaw = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: nonceBytes as unknown as BufferSource, tagLength: 128 },
      wrappingKey,
      combined as unknown as BufferSource,
    );

    const decryptedBytes = new Uint8Array(decryptedRaw);
    const hex = bytesToHex(decryptedBytes);
    decryptedBytes.fill(0);
    return hex;
  } finally {
    ciphertextBytes.fill(0);
    nonceBytes.fill(0);
    tagBytes.fill(0);
    combined.fill(0);
  }
}

/**
 * Resolve a hex string, CryptoKey, or fallback to active in-memory CryptoKey instance.
 * Accepts CryptoKey directly without re-importing raw hex strings (REQ-VAULT-HARDEN-1).
 */
export async function resolveCryptoKey(key?: string | CryptoKey | null): Promise<CryptoKey> {
  if (key && typeof key === 'object' && 'algorithm' in key) {
    return key;
  }
  if (typeof key === 'string' && key.trim()) {
    return await importRawKeyHex(key.trim());
  }
  const activeKey = getActiveVaultKey();
  if (activeKey) {
    return activeKey;
  }
  throw new Error('Invalid vault key: expected a 64-character hex string or CryptoKey instance');
}

/**
 * Encrypt plaintext using 256-bit AES-GCM and return self-describing armored string:
 * 'vault:v1:<base64(12B_nonce + 16B_tag + ciphertext)>'
 * Accepts CryptoKey directly without re-importing raw strings.
 * Securely wipes transient byte arrays immediately after use.
 */
export async function encryptVaultText(
  plaintext: string,
  key?: string | CryptoKey | null,
): Promise<string> {
  const cryptoKey = await resolveCryptoKey(key);
  const nonce = crypto.getRandomValues(new Uint8Array(AES_GCM_NONCE_BYTES));

  const enc = new TextEncoder();
  const plaintextBytes = enc.encode(plaintext);

  let encrypted: ArrayBuffer;
  try {
    encrypted = await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: nonce as unknown as BufferSource, tagLength: 128 },
      cryptoKey,
      plaintextBytes as unknown as BufferSource,
    );
  } finally {
    plaintextBytes.fill(0);
  }

  const encryptedBytes = new Uint8Array(encrypted);
  const ciphertextLen = encryptedBytes.length - AES_GCM_TAG_BYTES;
  const ciphertextBytes = encryptedBytes.subarray(0, ciphertextLen);
  const tagBytes = encryptedBytes.subarray(ciphertextLen);

  const payload = new Uint8Array(MIN_ARMOR_PAYLOAD_BYTES + ciphertextLen);
  payload.set(nonce, 0);
  payload.set(tagBytes, AES_GCM_NONCE_BYTES);
  payload.set(ciphertextBytes, MIN_ARMOR_PAYLOAD_BYTES);

  const result = `${VAULT_ARMOR_PREFIX}${bytesToBase64(payload)}`;

  nonce.fill(0);
  payload.fill(0);
  encryptedBytes.fill(0);

  return result;
}

/**
 * Decrypt a vault armored string. If input is not armored with 'vault:v1:',
 * returns original input string as-is (transparent fallback).
 * Accepts CryptoKey directly without re-importing raw strings.
 * Securely wipes transient byte arrays immediately after use.
 */
export async function decryptVaultText(
  armored: string,
  key?: string | CryptoKey | null,
): Promise<string> {
  if (!isVaultArmored(armored)) {
    return armored;
  }

  const b64 = armored.slice(VAULT_ARMOR_PREFIX.length).trim();
  if (!isValidBase64(b64)) {
    throw new Error('Invalid vault armored ciphertext: malformed base64 payload');
  }

  const payload = base64ToBytes(b64);
  if (payload.length < MIN_ARMOR_PAYLOAD_BYTES) {
    payload.fill(0);
    throw new Error(
      `Invalid vault armored ciphertext: payload length (${payload.length} bytes) is less than header (${MIN_ARMOR_PAYLOAD_BYTES} bytes)`,
    );
  }

  const nonce = payload.subarray(0, AES_GCM_NONCE_BYTES);
  const tag = payload.subarray(AES_GCM_NONCE_BYTES, MIN_ARMOR_PAYLOAD_BYTES);
  const ciphertext = payload.subarray(MIN_ARMOR_PAYLOAD_BYTES);

  const combined = new Uint8Array(ciphertext.length + tag.length);
  combined.set(ciphertext, 0);
  combined.set(tag, ciphertext.length);

  try {
    const cryptoKey = await resolveCryptoKey(key);
    const decryptedRaw = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: nonce as unknown as BufferSource, tagLength: 128 },
      cryptoKey,
      combined as unknown as BufferSource,
    );

    const decryptedBytes = new Uint8Array(decryptedRaw);
    try {
      const dec = new TextDecoder();
      return dec.decode(decryptedBytes);
    } finally {
      decryptedBytes.fill(0);
    }
  } finally {
    payload.fill(0);
    combined.fill(0);
  }
}
