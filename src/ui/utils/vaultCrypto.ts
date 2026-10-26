// Zero-Knowledge WebCrypto Vault Client Library
// v2 content envelope (docs/plans/passwordless-vault.md §1), keyring-aware encrypt /
// decrypt, and BIP-39 recovery words (for the P4 recovery key).
// The Odin twin of the envelope is src/lib/vault/envelope.odin; both are pinned by
// tests/fixtures/vault_v2_vectors.json.
// REQ-VAULT-HARDEN-1, REQ-VAULT-HARDEN-2

import { BIP39_WORDS } from './bip39Words.ts';
import { clearActiveTaskChainSearchKey } from './taskChainSearchKey.ts';
import { ID_VALUE_RE, VAULT_ID_RE, isVaultKeyring, keyFor, currentKey, type VaultKeyring } from './vaultKeyring.ts';

export type { VaultKeyring } from './vaultKeyring.ts';
export { currentKey, keyFor } from './vaultKeyring.ts';
export const AES_GCM_NONCE_BYTES = 12;
export const AES_GCM_TAG_BYTES = 16;
export const RECOVERY_ENTROPY_BYTES = 16;

export const VAULT_ARMOR_PREFIX = 'vault:v2:';
export const MIN_ARMOR_PAYLOAD_BYTES = AES_GCM_NONCE_BYTES + AES_GCM_TAG_BYTES; // 28 bytes
/** Upper bound on one envelope's decoded nonce|tag|ct (matches src/lib/vault MAX_PAYLOAD_BYTES). */
export const MAX_ARMOR_PAYLOAD_BYTES = 64 * 1024 * 1024;
const MAX_ARMOR_B64_LEN = Math.floor((MAX_ARMOR_PAYLOAD_BYTES + 2) / 3) * 4;

/**
 * The ONE vault token pattern for the app:
 * `vault:v2:<vault_id 16 hex>:e<epoch>:<b64std(nonce|tag|ct)>`.
 * Global; use it with `replace`/`match` (which reset lastIndex) or via the helpers
 * below. Dead older-format tokens do not match and are never decrypted.
 */
export const VAULT_TOKEN_RE = /vault:v2:[0-9a-f]{16}:e[1-9][0-9]{0,9}:[A-Za-z0-9+/]+={0,2}/g;
const VAULT_TOKEN_TEST_RE = /vault:v2:[0-9a-f]{16}:e[1-9][0-9]{0,9}:[A-Za-z0-9+/]+={0,2}/;
const VAULT_TOKEN_EXACT_RE = /^vault:v2:([0-9a-f]{16}):e([1-9][0-9]{0,9}):([A-Za-z0-9+/]+={0,2})$/;

/** Shown in place of a token whose epoch key this browser does not hold. */
export const VAULT_LOCKED_MARKER = '[🔒 Encrypted]';
/** Shown in place of a token sealed in a previous (reset) vault: never tried with these keys. */
export const VAULT_OTHER_VAULT_MARKER = '[🔒 From a previous vault]';

/** Replace every vault token in `text` with `replacement` (default: the locked marker). */
export function replaceVaultTokens(text: string, replacement: string = VAULT_LOCKED_MARKER): string {
  return text.replace(VAULT_TOKEN_RE, () => replacement);
}

/** Every vault token in `text`, in order (duplicates included). */
export function findVaultTokens(text: string): string[] {
  return text.match(VAULT_TOKEN_RE) ?? [];
}

// -- Active keyring ----------------------------------------------------------
//
// Installed by vaultKeyringSession after this device's wrap was verified against the
// signed directory chain and opened. Holds only non-extractable keys.
let activeVaultKeyring: VaultKeyring | null = null;

/** The active keyring, or null until this device's keyring is installed. */
export function getActiveVaultKey(): VaultKeyring | null {
  return activeVaultKeyring;
}

/**
 * Install (or, with `null`, purge) the active vault keyring. Every replacement
 * invalidates the derived search key of the previous keyring.
 */
export function setActiveVaultKey(keyring: VaultKeyring | null): void {
  if (keyring !== null && !isVaultKeyring(keyring)) throw new Error('setActiveVaultKey expects a VaultKeyring');
  activeVaultKeyring = keyring;
  clearActiveTaskChainSearchKey();
}

/** Whether a string is a v2 vault envelope (prefix test; decryption validates it). */
export function isVaultArmored(text: unknown): boolean {
  return typeof text === 'string' && text.startsWith(VAULT_ARMOR_PREFIX);
}

/** Whether a string contains at least one complete v2 vault token. */
export function containsVaultArmored(text: unknown): boolean {
  return typeof text === 'string' && VAULT_TOKEN_TEST_RE.test(text);
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
 * The 128-bit entropy of a valid 12-word BIP-39 mnemonic (checksum verified). Throws
 * on anything else. The caller zeroes the result.
 */
export function recoveryWordsToEntropy(words: string[]): Uint8Array {
  if (!validateRecoveryWords(words)) throw new Error('These are not 12 valid recovery words');
  let bits = '';
  for (const word of words) bits += (wordToBip39IndexMap.get(word.trim().toLowerCase()) as number).toString(2).padStart(11, '0');
  const entropy = new Uint8Array(RECOVERY_ENTROPY_BYTES);
  for (let i = 0; i < RECOVERY_ENTROPY_BYTES; i++) entropy[i] = parseInt(bits.slice(i * 8, (i + 1) * 8), 2);
  return entropy;
}

/** Thrown for a token that claims to be v2 but is not exactly canonical. */
export class VaultEnvelopeFormatError extends Error {
  constructor(reason: string) {
    super(`Invalid vault armored ciphertext: ${reason}`);
    this.name = 'VaultEnvelopeFormatError';
  }
}

/**
 * Strict standard-base64 decode: padded, length % 4 === 0, no foreign characters
 * (URL-safe included) and zero trailing bits, so every payload has one spelling.
 */
export function decodeBase64Strict(b64: string): Uint8Array {
  if (!isValidBase64(b64)) throw new VaultEnvelopeFormatError('malformed base64 payload');
  const bytes = base64ToBytes(b64);
  if (bytesToBase64(bytes) !== b64) {
    bytes.fill(0);
    throw new VaultEnvelopeFormatError('non-canonical base64 payload');
  }
  return bytes;
}

/** Parse one complete token into its vault id, epoch and decoded payload. Throws when malformed. */
export function parseVaultEnvelope(token: string): { vaultId: string; epoch: number; payload: Uint8Array } {
  const m = VAULT_TOKEN_EXACT_RE.exec(token);
  if (!m) throw new VaultEnvelopeFormatError('not a canonical v2 token');
  const vaultId = m[1];
  const epoch = Number(m[2]);
  if (!Number.isInteger(epoch) || epoch < 1 || epoch > 0xffffffff) throw new VaultEnvelopeFormatError('epoch out of range');
  if (m[3].length > MAX_ARMOR_B64_LEN) throw new VaultEnvelopeFormatError('payload too large');
  const payload = decodeBase64Strict(m[3]);
  if (payload.length < MIN_ARMOR_PAYLOAD_BYTES || payload.length > MAX_ARMOR_PAYLOAD_BYTES) {
    payload.fill(0);
    throw new VaultEnvelopeFormatError(`payload length ${payload.length} out of range`);
  }
  return { vaultId, epoch, payload };
}

/** "vault:v2:<vault_id>:e<epoch>:" -- the header every token-format channel uses. */
export function vaultTokenPrefix(vaultId: string, epoch: number): string {
  if (!VAULT_ID_RE.test(vaultId)) throw new Error('invalid vault id');
  if (!Number.isInteger(epoch) || epoch < 1 || epoch > 0xffffffff) throw new Error('invalid epoch');
  return `${VAULT_ARMOR_PREFIX}${vaultId}:e${epoch}:`;
}

export function vaultEnvelopeAad(vaultId: string, epoch: number): Uint8Array {
  return new TextEncoder().encode(`heimdall-vault-v2|${vaultId}|e${epoch}`);
}

function requireKeyring(keyring?: VaultKeyring | null): VaultKeyring {
  const kr = keyring ?? getActiveVaultKey();
  if (!kr) throw new Error('Vault keyring unavailable');
  return kr;
}

/** Resolve an explicit keyring or fall back to the active one; throws when neither exists. */
export async function resolveKeyring(keyring?: VaultKeyring | null): Promise<VaultKeyring> {
  return requireKeyring(keyring);
}

/**
 * Seal `plaintext` under `key` for `epoch`. `nonce` is for test vectors only;
 * production callers omit it and get a fresh CSPRNG nonce (getRandomValues throws on
 * failure, so nothing is sealed without randomness).
 */
export async function sealVaultEnvelope(plaintext: Uint8Array, key: CryptoKey, vaultId: string, epoch: number, nonce?: Uint8Array, aad?: Uint8Array): Promise<string> {
  const prefix = vaultTokenPrefix(vaultId, epoch);
  if (plaintext.length > MAX_ARMOR_PAYLOAD_BYTES - MIN_ARMOR_PAYLOAD_BYTES) throw new Error('plaintext too large for a vault envelope');
  const iv = nonce ? Uint8Array.from(nonce) : crypto.getRandomValues(new Uint8Array(AES_GCM_NONCE_BYTES));
  if (iv.length !== AES_GCM_NONCE_BYTES) throw new Error('invalid nonce length');
  const encryptedBytes = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: iv as unknown as BufferSource, additionalData: (aad ?? vaultEnvelopeAad(vaultId, epoch)) as unknown as BufferSource, tagLength: 128 },
    key,
    plaintext as unknown as BufferSource,
  ));
  const ctLen = encryptedBytes.length - AES_GCM_TAG_BYTES;
  const payload = new Uint8Array(MIN_ARMOR_PAYLOAD_BYTES + ctLen);
  payload.set(iv, 0);
  payload.set(encryptedBytes.subarray(ctLen), AES_GCM_NONCE_BYTES);
  payload.set(encryptedBytes.subarray(0, ctLen), MIN_ARMOR_PAYLOAD_BYTES);
  const result = `${prefix}${bytesToBase64(payload)}`;
  iv.fill(0);
  payload.fill(0);
  encryptedBytes.fill(0);
  return result;
}

/**
 * Encrypt plaintext under the keyring's CURRENT epoch (never an older one):
 * `vault:v2:<vault_id>:e<epoch>:<base64(12B nonce + 16B tag + ciphertext)>`.
 */
export async function encryptVaultText(plaintext: string, keyring?: VaultKeyring | null): Promise<string> {
  const kr = requireKeyring(keyring);
  const bytes = new TextEncoder().encode(plaintext);
  try {
    return await sealVaultEnvelope(bytes, currentKey(kr), kr.vaultId, kr.currentEpoch);
  } finally {
    bytes.fill(0);
  }
}

// ── File write v3 (finding N4 + P4 root binding) ──────────────────────────────
// File content sent for a bridge to write uses the v2 token format under the current
// epoch key with AAD
//   "heimdall-fs-write-v3|<vault_id>|e<epoch>|<bridge_id>|<hex sha256(root)>|<hex sha256(path)>",
// binding it to one vault, one bridge, one sandbox ROOT (the canonical root directory
// the bridge reports as `root` in its fs results) and the exact path string of the
// request, so a write sealed for project A cannot be replayed into project B. Mirrors
// lib/vault fs_write_aad / fs_write_open; vectors in tests/fixtures/vault_v2_vectors.json.

async function sha256Hex(s: string): Promise<string> {
  return bytesToHex(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s) as unknown as BufferSource)));
}

export async function fsWriteAad(vaultId: string, epoch: number, bridgeId: string, root: string, path: string): Promise<Uint8Array> {
  if (!VAULT_ID_RE.test(vaultId)) throw new Error('invalid vault id');
  if (!Number.isInteger(epoch) || epoch < 1 || epoch > 0xffffffff) throw new Error('invalid epoch');
  if (!bridgeId || bridgeId.length > 256 || !ID_VALUE_RE.test(bridgeId)) throw new Error('a file write needs the target bridge id');
  if (!root) throw new Error('a file write needs the project root the bridge writes under');
  if (!path) throw new Error('a file write needs the target path');
  return new TextEncoder().encode(`heimdall-fs-write-v3|${vaultId}|e${epoch}|${bridgeId}|${await sha256Hex(root)}|${await sha256Hex(path)}`);
}

/** Seal file content for `bridgeId` to write at exactly `path` under `root` (current epoch). */
export async function sealFsWriteContent(plaintext: string, bridgeId: string, root: string, path: string, keyring?: VaultKeyring | null, nonce?: Uint8Array): Promise<string> {
  const kr = requireKeyring(keyring);
  const aad = await fsWriteAad(kr.vaultId, kr.currentEpoch, bridgeId, root, path);
  const bytes = new TextEncoder().encode(plaintext);
  try {
    return await sealVaultEnvelope(bytes, currentKey(kr), kr.vaultId, kr.currentEpoch, nonce, aad);
  } finally {
    bytes.fill(0);
  }
}

/** Open a file-write token for (`bridgeId`, `root`, `path`); throws when it does not authenticate. */
export async function openFsWriteContent(token: string, bridgeId: string, root: string, path: string, keyring?: VaultKeyring | null): Promise<string> {
  const kr = requireKeyring(keyring);
  const { vaultId, epoch, payload } = parseVaultEnvelope(token);
  try {
    if (vaultId !== kr.vaultId) throw new Error('sealed in another vault');
    const key = keyFor(kr, epoch);
    if (!key) throw new Error('unknown epoch');
    const aad = await fsWriteAad(vaultId, epoch, bridgeId, root, path);
    const nonce = payload.subarray(0, AES_GCM_NONCE_BYTES);
    const tag = payload.subarray(AES_GCM_NONCE_BYTES, MIN_ARMOR_PAYLOAD_BYTES);
    const ct = payload.subarray(MIN_ARMOR_PAYLOAD_BYTES);
    const combined = new Uint8Array(ct.length + tag.length);
    combined.set(ct, 0);
    combined.set(tag, ct.length);
    const plain = new Uint8Array(await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: nonce as unknown as BufferSource, additionalData: aad as unknown as BufferSource, tagLength: 128 },
      key,
      combined as unknown as BufferSource,
    ));
    return new TextDecoder().decode(plain);
  } finally {
    payload.fill(0);
  }
}

/** Open a decoded payload for (`vaultId`, `epoch`) under `key`; throws when it does not authenticate. */
export async function openVaultPayload(payload: Uint8Array, key: CryptoKey, vaultId: string, epoch: number): Promise<Uint8Array> {
  const nonce = payload.subarray(0, AES_GCM_NONCE_BYTES);
  const tag = payload.subarray(AES_GCM_NONCE_BYTES, MIN_ARMOR_PAYLOAD_BYTES);
  const ciphertext = payload.subarray(MIN_ARMOR_PAYLOAD_BYTES);
  const combined = new Uint8Array(ciphertext.length + tag.length);
  combined.set(ciphertext, 0);
  combined.set(tag, ciphertext.length);
  try {
    return new Uint8Array(await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: nonce as unknown as BufferSource, additionalData: vaultEnvelopeAad(vaultId, epoch) as unknown as BufferSource, tagLength: 128 },
      key,
      combined as unknown as BufferSource,
    ));
  } finally {
    combined.fill(0);
  }
}

/**
 * Decrypt a vault envelope with the key for the epoch in its header.
 * - Not armored (plain text, or a dead older-format token): returned unchanged.
 * - Another (reset) vault: VAULT_OTHER_VAULT_MARKER -- never tried with these keys.
 * - Unknown epoch: VAULT_LOCKED_MARKER -- never an exception, never ciphertext.
 * - Malformed, or does not authenticate: throws.
 */
export async function decryptVaultText(armored: string, keyring?: VaultKeyring | null): Promise<string> {
  const opened = await decryptVaultBytes(armored, keyring);
  switch (opened.status) {
    case 'not_armored': return armored;
    case 'other_vault': return VAULT_OTHER_VAULT_MARKER;
    case 'locked': return VAULT_LOCKED_MARKER;
    case 'ok':
      try {
        return new TextDecoder().decode(opened.bytes);
      } finally {
        opened.bytes.fill(0);
      }
  }
}

export type VaultBytesResult =
  | { status: 'ok'; bytes: Uint8Array }
  | { status: 'not_armored' }
  | { status: 'other_vault' }
  | { status: 'locked' };

/**
 * Byte form of decryptVaultText for binary content (ZIP bundles, images): the plaintext
 * exactly as it was sealed. Never routed through TextDecoder, which would replace every
 * invalid UTF-8 sequence with U+FFFD and corrupt the payload. The caller owns `bytes`.
 * Malformed tokens, and tokens that do not authenticate, throw.
 */
export async function decryptVaultBytes(armored: string, keyring?: VaultKeyring | null): Promise<VaultBytesResult> {
  if (!isVaultArmored(armored)) return { status: 'not_armored' };
  const { vaultId, epoch, payload } = parseVaultEnvelope(armored);
  try {
    const kr = requireKeyring(keyring);
    if (vaultId !== kr.vaultId) return { status: 'other_vault' };
    const key = keyFor(kr, epoch);
    if (!key) return { status: 'locked' };
    return { status: 'ok', bytes: await openVaultPayload(payload, key, vaultId, epoch) };
  } finally {
    payload.fill(0);
  }
}
