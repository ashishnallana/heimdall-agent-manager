// Canonical signed statements, signature objects, algorithm allowlists, kind policy
// and keyring wraps (docs/plans/passwordless-vault.md §1 "Credential agility",
// "Signed statements", "Keyring wrap"). The Odin twin is src/lib/vault/statement.odin
// and channels.odin; both are pinned by tests/fixtures/vault_v2_vectors.json.
//
// Every verification and unwrap dispatches through ONE allowlist; an unknown
// algorithm id is rejected before any key is imported. Passkeys / security keys will
// be new ids added to these allowlists, nowhere else.

import { ID_VALUE_RE, parseKeyringBytes, KEYRING_MAX_BYTES, type ParsedKeyringBytes } from './vaultKeyring.ts';

export const SIGN_ALG_ECDSA_P256_SHA256 = 'ecdsa-p256-sha256';
export const WRAP_ALG_ECDH_P256_HKDF_AES = 'ecdh-p256-hkdf-sha256-aes256gcm';

export type SignAlg = typeof SIGN_ALG_ECDSA_P256_SHA256;
export type WrapAlg = typeof WRAP_ALG_ECDH_P256_HKDF_AES;

/** The single sign-algorithm allowlist. */
export function signAlgFromId(id: unknown): SignAlg | null {
  return id === SIGN_ALG_ECDSA_P256_SHA256 ? SIGN_ALG_ECDSA_P256_SHA256 : null;
}

/** The single wrap-algorithm allowlist. */
export function wrapAlgFromId(id: unknown): WrapAlg | null {
  return id === WRAP_ALG_ECDH_P256_HKDF_AES ? WRAP_ALG_ECDH_P256_HKDF_AES : null;
}

export type DeviceKind = 'browser' | 'bridge' | 'recovery';

export function deviceKindFromId(id: unknown): DeviceKind | null {
  return id === 'browser' || id === 'bridge' || id === 'recovery' ? id : null;
}

export interface KindPolicy {
  /** May sign approve/revoke/epoch/wrap statements. */
  canApprove: boolean;
  /** Counts toward the last-approver guard. */
  countsAsApprover: boolean;
  /** Receives a hub-stored keyring wrap. */
  receivesWrap: boolean;
}

const NO_POLICY: KindPolicy = Object.freeze({ canApprove: false, countsAsApprover: false, receivesWrap: false });

/** The ONE place that decides what a device kind may do. Bridges never approve. */
export function kindPolicy(kind: unknown): KindPolicy {
  switch (deviceKindFromId(kind)) {
    case 'browser':
    case 'recovery':
      return { canApprove: true, countsAsApprover: true, receivesWrap: true };
    default:
      return NO_POLICY;
  }
}

// ── hex helpers ──────────────────────────────────────────────────────────────

const LOWER_HEX_RE = /^[0-9a-f]*$/;

export function isLowerHex(s: string, bytes?: number): boolean {
  return typeof s === 'string' && LOWER_HEX_RE.test(s) && s.length % 2 === 0 && (bytes === undefined || s.length === bytes * 2);
}

export function lowerHexToBytes(s: string, bytes?: number): Uint8Array {
  if (!isLowerHex(s, bytes)) throw new Error('expected lowercase hex');
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.slice(2 * i, 2 * i + 2), 16);
  return out;
}

export function toLowerHex(b: Uint8Array): string {
  let s = '';
  for (let i = 0; i < b.length; i++) s += b[i].toString(16).padStart(2, '0');
  return s;
}

const utf8 = new TextEncoder();

// ── signature objects ────────────────────────────────────────────────────────

export interface SignatureObject {
  alg: SignAlg;
  sig: string; // lowercase hex raw r||s (64 bytes)
}

export function renderSignatureObject(sig: SignatureObject): string {
  return `{"alg":"${sig.alg}","sig":"${sig.sig}"}`;
}

/**
 * Parse a signature object. Only the exact canonical spelling is accepted, after
 * dispatching on `alg` through the allowlist; anything else returns null.
 */
export function parseSignatureObject(json: unknown): SignatureObject | null {
  if (typeof json !== 'string') return null;
  let value: unknown;
  try { value = JSON.parse(json); } catch { return null; }
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const obj = value as Record<string, unknown>;
  switch (signAlgFromId(obj.alg)) {
    case SIGN_ALG_ECDSA_P256_SHA256: {
      if (Object.keys(obj).length !== 2 || typeof obj.sig !== 'string' || !isLowerHex(obj.sig, 64)) return null;
      const sig: SignatureObject = { alg: SIGN_ALG_ECDSA_P256_SHA256, sig: obj.sig };
      return renderSignatureObject(sig) === json ? sig : null;
    }
    default:
      return null;
  }
}

/** Accept a signature object given either as its JSON text or as a parsed object. */
export function signatureObjectText(value: unknown): string {
  if (typeof value === 'string') return value;
  if (value && typeof value === 'object') return JSON.stringify(value);
  return '';
}

/**
 * Verify `sigJson` over `msg` under a public key of algorithm `keyAlg`. The key's
 * algorithm and the signature's algorithm must agree, and both must be allowlisted.
 * Never throws: any malformed input is a failed verification.
 */
export async function verifySignature(keyAlg: unknown, publicKeyHex: string, msg: Uint8Array, sigJson: unknown): Promise<boolean> {
  const alg = signAlgFromId(keyAlg);
  if (!alg) return false;
  const sig = parseSignatureObject(signatureObjectText(sigJson));
  if (!sig || sig.alg !== alg) return false;
  switch (alg) {
    case SIGN_ALG_ECDSA_P256_SHA256: {
      try {
        if (!isLowerHex(publicKeyHex, 65) || !publicKeyHex.startsWith('04')) return false;
        const pub = await crypto.subtle.importKey('raw', lowerHexToBytes(publicKeyHex) as unknown as BufferSource, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
        return await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, pub, lowerHexToBytes(sig.sig) as unknown as BufferSource, msg as unknown as BufferSource);
      } catch {
        return false;
      }
    }
    default:
      return false;
  }
}

/** Sign with a WebCrypto ECDSA P-256 private key and return the signature object text. */
export async function signP256(privateKey: CryptoKey, msg: Uint8Array): Promise<string> {
  const raw = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, privateKey, msg as unknown as BufferSource));
  return renderSignatureObject({ alg: SIGN_ALG_ECDSA_P256_SHA256, sig: toLowerHex(raw) });
}

// ── canonical statements ─────────────────────────────────────────────────────

export const STATEMENT_HEADER = 'heimdall-vault-statement/v1';
export const STATEMENT_TYPES = ['genesis', 'approve', 'revoke', 'epoch', 'wrap', 'recovery', 'register'] as const;
export type StatementType = (typeof STATEMENT_TYPES)[number];

export const STATEMENT_FIELDS = [
  'type', 'user_id', 'directory_version', 'issuer_device_id', 'issued_at_ms',
  'subject_device_id', 'subject_kind', 'subject_sign_pub', 'subject_ecdh_pub',
  'subject_sign_alg', 'subject_wrap_alg', 'subject_label_b64', 'epoch', 'epoch_commit', 'wrap_sha256',
] as const;
export type StatementField = (typeof STATEMENT_FIELDS)[number];
export type Statement = Partial<Record<StatementField, string>> & { type: string };

/** Fixed-layout canonical bytes; throws on any value outside the grammar. */
export function statementCanonical(st: Statement): string {
  if (!(STATEMENT_TYPES as readonly string[]).includes(st.type)) throw new Error('unknown statement type');
  if (st.subject_kind && !deviceKindFromId(st.subject_kind)) throw new Error('unknown subject kind');
  if (st.subject_sign_alg && !signAlgFromId(st.subject_sign_alg)) throw new Error('unknown subject sign alg');
  if (st.subject_wrap_alg && !wrapAlgFromId(st.subject_wrap_alg)) throw new Error('unknown subject wrap alg');
  const lines: string[] = [STATEMENT_HEADER];
  for (const field of STATEMENT_FIELDS) {
    const value = st[field] ?? '';
    if (typeof value !== 'string' || !ID_VALUE_RE.test(value)) throw new Error(`invalid statement value for ${field}`);
    lines.push(`${field}=${value}`);
  }
  return lines.join('\n');
}

/** epoch_commit = HMAC-SHA256(epoch_key, "heimdall-epoch-commit|<user_id>|<epoch>"). */
export async function epochCommit(epochKeyRaw: Uint8Array, userId: string, epoch: number): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey('raw', epochKeyRaw as unknown as BufferSource, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, utf8.encode(`heimdall-epoch-commit|${userId}|${epoch}`)));
}

export const BRIDGE_UNSEAL_KEY_HEADER = 'heimdall-bridge-unseal-key/v1';

/** `heimdall-bridge-unseal-key/v1\n<bridge_id>\n<ecdh_pub_hex>\n<boot_id>` */
export function bridgeUnsealKeyCanonical(bridgeId: string, ecdhPubHex: string, bootId: string): string {
  if (!bridgeId || !ID_VALUE_RE.test(bridgeId)) throw new Error('invalid bridge id');
  if (!isLowerHex(ecdhPubHex, 65)) throw new Error('invalid bridge ECDH public key');
  if (!bootId || !isLowerHex(bootId)) throw new Error('invalid bridge boot id');
  return `${BRIDGE_UNSEAL_KEY_HEADER}\n${bridgeId}\n${ecdhPubHex}\n${bootId}`;
}

// ── keyring wraps ────────────────────────────────────────────────────────────

export const WRAP_INFO = 'heimdall-keyring-wrap-v1';

export interface KeyringWrap {
  alg: string;
  recipient_device_id: string;
  directory_version: number;
  current_epoch: number;
  ephemeral_public_key: string;
  iv: string;
  ciphertext: string;
  wrapped_by_device_id: string;
}

export function wrapAad(userId: string, recipientDeviceId: string, directoryVersion: number, currentEpoch: number): string {
  if (!userId || !ID_VALUE_RE.test(userId) || !recipientDeviceId || !ID_VALUE_RE.test(recipientDeviceId)) throw new Error('invalid wrap AAD component');
  return `${WRAP_INFO}|${userId}|${recipientDeviceId}|${directoryVersion}|${currentEpoch}`;
}

/** The wrap without its signature, in the fixed key order wrap_sha256 covers. */
export function wrapCanonicalJson(w: KeyringWrap): string {
  if (!wrapAlgFromId(w.alg)) throw new Error('unknown wrap alg');
  for (const s of [w.recipient_device_id, w.ephemeral_public_key, w.iv, w.ciphertext, w.wrapped_by_device_id]) {
    if (typeof s !== 'string' || !ID_VALUE_RE.test(s)) throw new Error('invalid wrap field');
  }
  if (!Number.isSafeInteger(w.directory_version) || w.directory_version < 0) throw new Error('invalid directory_version');
  if (!Number.isInteger(w.current_epoch) || w.current_epoch < 1) throw new Error('invalid current_epoch');
  return `{"v":1,"alg":"${w.alg}","recipient_device_id":"${w.recipient_device_id}","directory_version":${w.directory_version},"current_epoch":${w.current_epoch},"ephemeral_public_key":"${w.ephemeral_public_key}","iv":"${w.iv}","ciphertext":"${w.ciphertext}","wrapped_by_device_id":"${w.wrapped_by_device_id}"}`;
}

export async function wrapSha256(w: KeyringWrap): Promise<string> {
  return toLowerHex(new Uint8Array(await crypto.subtle.digest('SHA-256', utf8.encode(wrapCanonicalJson(w)))));
}

/** ECDH(priv, peer) → HKDF-SHA256(32 zero bytes, info) → AES-256-GCM key. */
export async function ecdhHkdfAesKey(privateKey: CryptoKey, peerPublicHex: string, info: string, usages: KeyUsage[]): Promise<CryptoKey> {
  if (!isLowerHex(peerPublicHex, 65) || !peerPublicHex.startsWith('04')) throw new Error('invalid peer public key');
  const peer = await crypto.subtle.importKey('raw', lowerHexToBytes(peerPublicHex) as unknown as BufferSource, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: peer }, privateKey, 256));
  try {
    const material = await crypto.subtle.importKey('raw', shared as unknown as BufferSource, 'HKDF', false, ['deriveKey']);
    return await crypto.subtle.deriveKey(
      { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(32), info: utf8.encode(info) },
      material,
      { name: 'AES-GCM', length: 256 },
      false,
      usages,
    );
  } finally {
    shared.fill(0);
  }
}

/**
 * Unwrap a keyring copy addressed to this device, dispatching on `alg` through the
 * wrap allowlist. Returns the parsed keyring (caller must zero the entry keys);
 * throws on any failure, including an unknown alg or a keyring for another user or
 * epoch.
 */
export async function openKeyringWrap(w: KeyringWrap, userId: string, recipientEcdhPrivate: CryptoKey): Promise<ParsedKeyringBytes> {
  switch (wrapAlgFromId(w.alg)) {
    case WRAP_ALG_ECDH_P256_HKDF_AES: {
      const aad = utf8.encode(wrapAad(userId, w.recipient_device_id, w.directory_version, w.current_epoch));
      if (!isLowerHex(w.iv, 12)) throw new Error('invalid wrap iv');
      if (!isLowerHex(w.ciphertext) || w.ciphertext.length < 32 || w.ciphertext.length > (KEYRING_MAX_BYTES + 16) * 2) throw new Error('invalid wrap ciphertext');
      const key = await ecdhHkdfAesKey(recipientEcdhPrivate, w.ephemeral_public_key, WRAP_INFO, ['decrypt']);
      const plain = new Uint8Array(await crypto.subtle.decrypt(
        { name: 'AES-GCM', iv: lowerHexToBytes(w.iv) as unknown as BufferSource, additionalData: aad as unknown as BufferSource, tagLength: 128 },
        key,
        lowerHexToBytes(w.ciphertext) as unknown as BufferSource,
      ));
      try {
        const parsed = parseKeyringBytes(plain, userId);
        if (parsed.currentEpoch !== w.current_epoch) {
          for (const e of parsed.entries) e.key.fill(0);
          throw new Error('wrap epoch does not match keyring');
        }
        return parsed;
      } finally {
        plain.fill(0);
      }
    }
    default:
      throw new Error('unknown wrap alg');
  }
}
