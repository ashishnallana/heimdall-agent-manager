// Passwordless vault keyring (docs/plans/passwordless-vault.md §1).
//
// HKR2 binary layout, identical to src/lib/vault/keyring.odin:
//   "HKR2" | u16be uid_len | user_id | vault_id[8] | u32be current_epoch | u16be count |
//   count × (u32be epoch | key[32])        entries strictly ascending
//
// vault_id = SHA-256(root_sign_pub_raw65)[0:8] (`vaultIdFor`): it names the account's
// vault, so content of a previous (reset) vault is recognised and never tried with
// this keyring's keys.
//
// A VaultKeyring holds one NON-EXTRACTABLE AES-GCM CryptoKey per epoch. Raw keyring
// bytes exist only transiently (to import, or to wrap for a bridge) and are zeroed
// by the functions that consume them.

export const KEYRING_MAGIC = 'HKR2';
export const KEYRING_MAX_EPOCHS = 64;
export const KEYRING_MAX_USER_ID = 64;
export const KEYRING_KEY_BYTES = 32;
export const VAULT_ID_BYTES = 8;
/** 16 lowercase hex characters. */
export const VAULT_ID_RE = /^[0-9a-f]{16}$/;
export const KEYRING_ENTRY_BYTES = 4 + KEYRING_KEY_BYTES;
export const KEYRING_MAX_BYTES = 4 + 2 + KEYRING_MAX_USER_ID + VAULT_ID_BYTES + 4 + 2 + KEYRING_MAX_EPOCHS * KEYRING_ENTRY_BYTES; // 2388
export const MAX_EPOCH = 0xffffffff;

/** Statement/AAD value grammar; user ids appear verbatim in canonical bytes. */
export const ID_VALUE_RE = /^[A-Za-z0-9_.:-]*$/;

/** A non-empty AAD identifier (session, owner, request ids): ID_VALUE_RE, at most 256 chars. */
export function isValidAadId(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= 256 && ID_VALUE_RE.test(value);
}

/**
 * A per-epoch HKDF base key (non-extractable, usage `deriveKey`) for the PTY v2
 * per-stream subkeys, or a pending import of one. WebCrypto cannot use an AES-GCM key
 * as HKDF input, so the epoch key is imported a second time for this purpose.
 */
export type PtyBaseKey = CryptoKey | Promise<CryptoKey | null>;

export interface VaultKeyring {
  readonly userId: string;
  /** The vault this keyring belongs to (16 hex; `vaultIdFor(root_sign_pub)`). */
  readonly vaultId: string;
  readonly currentEpoch: number;
  readonly keys: ReadonlyMap<number, CryptoKey>;
  /** PTY v2 HKDF base keys by epoch. Absent epoch = PTY traffic for it is locked. */
  readonly ptyBaseKeys?: ReadonlyMap<number, PtyBaseKey>;
}

export interface KeyringEntryBytes {
  epoch: number;
  key: Uint8Array;
}

export interface ParsedKeyringBytes {
  userId: string;
  vaultId: string;
  currentEpoch: number;
  entries: KeyringEntryBytes[];
}

export class KeyringFormatError extends Error {
  constructor(reason: string) {
    super(`Invalid vault keyring: ${reason}`);
    this.name = 'KeyringFormatError';
  }
}

/** vault id = first 8 bytes of SHA-256 of the root's raw signing key, as 16 hex. */
export async function vaultIdFor(rootSignPubHex: string): Promise<string> {
  if (typeof rootSignPubHex !== 'string' || !/^04[0-9a-f]{128}$/.test(rootSignPubHex)) throw new KeyringFormatError('root key');
  const raw = new Uint8Array(65);
  for (let i = 0; i < 65; i++) raw[i] = parseInt(rootSignPubHex.slice(2 * i, 2 * i + 2), 16);
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', raw as unknown as BufferSource));
  return Array.from(digest.subarray(0, VAULT_ID_BYTES), (b) => b.toString(16).padStart(2, '0')).join('');
}

function validateParsed(userId: string, vaultId: string, currentEpoch: number, entries: readonly { epoch: number }[]): void {
  if (userId.length < 1 || userId.length > KEYRING_MAX_USER_ID) throw new KeyringFormatError('user_id length');
  if (!ID_VALUE_RE.test(userId)) throw new KeyringFormatError('user_id characters');
  if (!VAULT_ID_RE.test(vaultId) || vaultId === '0'.repeat(16)) throw new KeyringFormatError('vault id');
  if (entries.length < 1 || entries.length > KEYRING_MAX_EPOCHS) throw new KeyringFormatError('entry count');
  let prev = 0;
  for (const { epoch } of entries) {
    if (!Number.isInteger(epoch) || epoch < 1 || epoch > MAX_EPOCH) throw new KeyringFormatError('epoch range');
    if (epoch <= prev) throw new KeyringFormatError('epochs must be strictly ascending');
    prev = epoch;
  }
  // Sealing always uses the newest key, so the current epoch must be the newest entry.
  if (currentEpoch !== entries[entries.length - 1].epoch) throw new KeyringFormatError('current epoch is not the newest entry');
}

/**
 * Decode HKR2 bytes. The returned entry keys are COPIES the caller must zero;
 * `bytes` itself is not modified.
 */
export function parseKeyringBytes(bytes: Uint8Array, expectedUserId?: string): ParsedKeyringBytes {
  if (bytes.length < 6 || bytes.length > KEYRING_MAX_BYTES) throw new KeyringFormatError('length');
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const magic = String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3]);
  if (magic !== KEYRING_MAGIC) throw new KeyringFormatError('magic');
  const uidLen = view.getUint16(4);
  if (uidLen < 1 || uidLen > KEYRING_MAX_USER_ID) throw new KeyringFormatError('user_id length');
  let off = 6;
  if (bytes.length < off + uidLen + VAULT_ID_BYTES + 6) throw new KeyringFormatError('truncated');
  let userId = '';
  for (let i = 0; i < uidLen; i++) userId += String.fromCharCode(bytes[off + i]);
  off += uidLen;
  let vaultId = '';
  for (let i = 0; i < VAULT_ID_BYTES; i++) vaultId += bytes[off + i].toString(16).padStart(2, '0');
  off += VAULT_ID_BYTES;
  const currentEpoch = view.getUint32(off);
  off += 4;
  const count = view.getUint16(off);
  off += 2;
  if (count < 1 || count > KEYRING_MAX_EPOCHS) throw new KeyringFormatError('entry count');
  if (bytes.length !== off + count * KEYRING_ENTRY_BYTES) throw new KeyringFormatError('length does not match entry count');
  const entries: KeyringEntryBytes[] = [];
  for (let i = 0; i < count; i++) {
    entries.push({ epoch: view.getUint32(off), key: bytes.slice(off + 4, off + KEYRING_ENTRY_BYTES) });
    off += KEYRING_ENTRY_BYTES;
  }
  try {
    validateParsed(userId, vaultId, currentEpoch, entries);
    if (expectedUserId !== undefined && expectedUserId !== '' && userId !== expectedUserId) {
      throw new KeyringFormatError('keyring belongs to a different user');
    }
  } catch (err) {
    for (const e of entries) e.key.fill(0);
    throw err;
  }
  return { userId, vaultId, currentEpoch, entries };
}

/** Encode HKR2 bytes. The caller owns (and must zero) the result. */
export function serializeKeyringBytes(parsed: ParsedKeyringBytes): Uint8Array {
  validateParsed(parsed.userId, parsed.vaultId, parsed.currentEpoch, parsed.entries);
  for (const e of parsed.entries) {
    if (e.key.length !== KEYRING_KEY_BYTES) throw new KeyringFormatError('key length');
  }
  const uid = parsed.userId;
  const out = new Uint8Array(4 + 2 + uid.length + VAULT_ID_BYTES + 4 + 2 + parsed.entries.length * KEYRING_ENTRY_BYTES);
  const view = new DataView(out.buffer);
  for (let i = 0; i < 4; i++) out[i] = KEYRING_MAGIC.charCodeAt(i);
  view.setUint16(4, uid.length);
  let off = 6;
  for (let i = 0; i < uid.length; i++) out[off + i] = uid.charCodeAt(i);
  off += uid.length;
  for (let i = 0; i < VAULT_ID_BYTES; i++) out[off + i] = parseInt(parsed.vaultId.slice(2 * i, 2 * i + 2), 16);
  off += VAULT_ID_BYTES;
  view.setUint32(off, parsed.currentEpoch);
  off += 4;
  view.setUint16(off, parsed.entries.length);
  off += 2;
  for (const e of parsed.entries) {
    view.setUint32(off, e.epoch);
    out.set(e.key, off + 4);
    off += KEYRING_ENTRY_BYTES;
  }
  return out;
}

async function importEpochKey(raw: Uint8Array): Promise<CryptoKey> {
  return crypto.subtle.importKey('raw', raw as unknown as BufferSource, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}

/** Import raw epoch-key bytes as the non-extractable HKDF base key for PTY v2 subkeys. */
export async function importPtyBaseKey(raw: Uint8Array): Promise<CryptoKey> {
  if (raw.length !== KEYRING_KEY_BYTES) throw new KeyringFormatError('key length');
  return crypto.subtle.importKey('raw', raw as unknown as BufferSource, 'HKDF', false, ['deriveKey']);
}

/**
 * Import HKR2 bytes as a keyring of non-extractable keys. `bytes` and every
 * intermediate copy are zeroed before this returns, whether it succeeds or throws.
 */
export async function importKeyring(bytes: Uint8Array, expectedUserId?: string): Promise<VaultKeyring> {
  let parsed: ParsedKeyringBytes | null = null;
  try {
    parsed = parseKeyringBytes(bytes, expectedUserId);
    const keys = new Map<number, CryptoKey>();
    const ptyBaseKeys = new Map<number, PtyBaseKey>();
    for (const e of parsed.entries) {
      keys.set(e.epoch, await importEpochKey(e.key));
      ptyBaseKeys.set(e.epoch, await importPtyBaseKey(e.key));
    }
    return Object.freeze({ userId: parsed.userId, vaultId: parsed.vaultId, currentEpoch: parsed.currentEpoch, keys, ptyBaseKeys });
  } finally {
    bytes.fill(0);
    if (parsed) for (const e of parsed.entries) e.key.fill(0);
  }
}

/** The key for `epoch`, or null when this keyring does not hold it. */
export function keyFor(keyring: VaultKeyring | null | undefined, epoch: number): CryptoKey | null {
  if (!keyring) return null;
  return keyring.keys.get(epoch) ?? null;
}

export function currentKey(keyring: VaultKeyring): CryptoKey {
  const key = keyring.keys.get(keyring.currentEpoch);
  if (!key) throw new KeyringFormatError('current epoch key missing');
  return key;
}

export function isVaultKeyring(value: unknown): value is VaultKeyring {
  return Boolean(value)
    && typeof value === 'object'
    && typeof (value as VaultKeyring).currentEpoch === 'number'
    && typeof (value as VaultKeyring).vaultId === 'string'
    && (value as VaultKeyring).keys instanceof Map;
}

/** Build a keyring around already-imported keys (validates the epoch layout). */
export function keyringFromKeys(userId: string, vaultId: string, currentEpoch: number, keys: Map<number, CryptoKey>): VaultKeyring {
  const epochs = Array.from(keys.keys()).sort((a, b) => a - b);
  validateParsed(userId, vaultId, currentEpoch, epochs.map((epoch) => ({ epoch })));
  return Object.freeze({ userId, vaultId, currentEpoch, keys: new Map(keys) });
}
