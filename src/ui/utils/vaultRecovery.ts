// Opt-in recovery key (docs/plans/passwordless-vault.md §2 P4).
//
// 12 BIP-39 words carry 128 bits of entropy. HKDF-SHA256(entropy, salt
// "heimdall-recovery-v1", info "wrap") gives an AES-256-GCM key (no password stretching: the
// entropy is already full strength). The browser that creates the key generates a
// `recovery`-kind directory credential -- an ECDSA P-256 signing key and an ECDH
// P-256 wrap key, extractable ONLY for the moment their PKCS#8 bytes are sealed --
// and seals those bytes under the recovery key with
//   AAD "heimdall-recovery-v1|<user_id>|<device_id>"
// so the words of another account, or a blob moved to another device row, never
// open. The sealed plaintext also names the account root and the hash of the
// credential's own approval op: a restoring browser accepts the directory only if its
// genesis root is that root and the recovery credential's approval in the verified
// log is exactly that op (its prev_hash chain covers the whole log prefix), so a hub
// cannot present a forged log around the genuine recovery key (the same binding the
// pairing pair_mac gives a newly paired device).
//
// The credential is approved by a signed `approve` log op (POST
// /vault/devices/recovery), may approve, counts toward the last-approver guard and
// receives wraps like any wrap-capable device; it can never be the root.

import { deviceIdFor, fingerprintFor, labelB64, type DeviceIdentity } from './deviceIdentity.ts';
import { logEntryHash, SIGN_ALG_ECDSA_P256_SHA256, statementCanonical, toLowerHex, lowerHexToBytes, verifySignature, WRAP_ALG_ECDH_P256_HKDF_AES, signP256 } from './vaultStatements.ts';
import { nextLogSlot, trustedRecoveryKeys, type VerifiedChain, type VerifiedDevice } from './vaultDirectoryVerify.ts';
import { sealKeyringWrap } from './vaultKeyringWrap.ts';
import { bytesToBase64, base64ToBytes, recoveryWordsToEntropy } from './vaultCrypto.ts';
import type { RecoveryKeyBody } from '../api/endpoints/vaultDevices.ts';

export const RECOVERY_SALT = 'heimdall-recovery-v1';
export const RECOVERY_HKDF_INFO = 'wrap';
export const RECOVERY_BLOB_ALG = 'bip39-hkdf-sha256-aes256gcm';
const utf8 = new TextEncoder();

export class RecoveryKeyError extends Error {
  constructor(reason: string) {
    super(reason);
    this.name = 'RecoveryKeyError';
  }
}

/** What the blob seals (typed; JSON.stringify of this exact shape). */
interface RecoverySecret {
  v: 1;
  sign_pkcs8: string;
  ecdh_pkcs8: string;
  root_sign_pub: string;
  approval_hash: string;
}

/** The stored blob (field order is the hub's canonical form). */
interface RecoveryBlob {
  v: 1;
  alg: typeof RECOVERY_BLOB_ALG;
  iv: string;
  ciphertext: string;
}

export function recoveryAad(userId: string, deviceId: string): Uint8Array {
  return utf8.encode(`heimdall-recovery-v1|${userId}|${deviceId}`);
}

/** HKDF-SHA256(entropy, "heimdall-recovery-v1", "wrap") -> non-extractable AES-256-GCM key. */
export async function recoveryAesKey(entropy: Uint8Array): Promise<CryptoKey> {
  if (entropy.length !== 16) throw new RecoveryKeyError('recovery entropy must be 128 bits');
  const ikm = await crypto.subtle.importKey('raw', entropy as unknown as BufferSource, 'HKDF', false, ['deriveKey']);
  return crypto.subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: utf8.encode(RECOVERY_SALT) as unknown as BufferSource, info: utf8.encode(RECOVERY_HKDF_INFO) as unknown as BufferSource },
    ikm,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt'],
  );
}

async function sealSecret(entropy: Uint8Array, userId: string, deviceId: string, secret: RecoverySecret, iv?: Uint8Array): Promise<string> {
  const key = await recoveryAesKey(entropy);
  const nonce = iv ?? crypto.getRandomValues(new Uint8Array(12));
  const plain = utf8.encode(JSON.stringify(secret));
  try {
    const ct = new Uint8Array(await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: nonce as unknown as BufferSource, additionalData: recoveryAad(userId, deviceId) as unknown as BufferSource, tagLength: 128 },
      key,
      plain as unknown as BufferSource,
    ));
    const blob: RecoveryBlob = { v: 1, alg: RECOVERY_BLOB_ALG, iv: toLowerHex(nonce), ciphertext: toLowerHex(ct) };
    return JSON.stringify(blob);
  } finally {
    plain.fill(0);
  }
}

function parseBlob(text: unknown): RecoveryBlob {
  let b: Partial<RecoveryBlob>;
  try {
    b = JSON.parse(String(text ?? '')) as Partial<RecoveryBlob>;
  } catch {
    throw new RecoveryKeyError('The recovery key data is malformed');
  }
  if (b?.v !== 1 || b.alg !== RECOVERY_BLOB_ALG || typeof b.iv !== 'string' || !/^[0-9a-f]{24}$/.test(b.iv)
    || typeof b.ciphertext !== 'string' || !/^([0-9a-f]{2})+$/.test(b.ciphertext) || b.ciphertext.length < 32) {
    throw new RecoveryKeyError('The recovery key data is malformed');
  }
  return b as RecoveryBlob;
}

/** Open a blob; null when the words (or user/device binding) do not authenticate it. */
async function openSecret(entropy: Uint8Array, userId: string, deviceId: string, blobText: unknown): Promise<RecoverySecret | null> {
  const b = parseBlob(blobText);
  const key = await recoveryAesKey(entropy);
  let plain: Uint8Array;
  try {
    plain = new Uint8Array(await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: lowerHexToBytes(b.iv) as unknown as BufferSource, additionalData: recoveryAad(userId, deviceId) as unknown as BufferSource, tagLength: 128 },
      key,
      lowerHexToBytes(b.ciphertext) as unknown as BufferSource,
    ));
  } catch {
    return null;
  }
  try {
    const s = JSON.parse(new TextDecoder().decode(plain)) as Partial<RecoverySecret>;
    if (s?.v !== 1 || typeof s.sign_pkcs8 !== 'string' || typeof s.ecdh_pkcs8 !== 'string'
      || typeof s.root_sign_pub !== 'string' || typeof s.approval_hash !== 'string' || !/^[0-9a-f]{64}$/.test(s.approval_hash)) {
      throw new RecoveryKeyError('The recovery key data is malformed');
    }
    return s as RecoverySecret;
  } finally {
    plain.fill(0);
  }
}

/**
 * A directory-credential view of the recovery key, usable wherever the device flows
 * take an approver identity (signing statements, requests and wraps). Private keys
 * are NON-extractable.
 */
export interface RecoveryCredential {
  readonly userId: string;
  readonly deviceId: string;
  readonly kind: 'recovery';
  readonly signAlg: typeof SIGN_ALG_ECDSA_P256_SHA256;
  readonly wrapAlg: typeof WRAP_ALG_ECDH_P256_HKDF_AES;
  readonly signPrivateKey: CryptoKey;
  readonly ecdhPrivateKey: CryptoKey;
  readonly signPub: string;
  readonly ecdhPub: string;
  readonly fingerprint: string;
  readonly createdAt: number;
}

/** The credential as the approver-identity shape the device flows accept. */
export function asApproverIdentity(c: RecoveryCredential): DeviceIdentity {
  return c as unknown as DeviceIdentity;
}

export const RECOVERY_LABEL = 'Recovery key';

/**
 * Build the recovery credential for `entropy` (the 12 words the user wrote down and
 * re-entered): fresh key pairs, the approval op signed by `approver`, the keyring wrap
 * to the credential and the sealed blob. The private keys exist in extractable form
 * only inside this function. `keyringBytes` is not modified.
 */
export async function buildRecoveryKey(
  approver: DeviceIdentity,
  chain: VerifiedChain,
  keyringBytes: Uint8Array,
  entropy: Uint8Array,
  now = Date.now(),
  label = `${RECOVERY_LABEL} · ${new Date(now).toISOString().slice(0, 10)}`,
): Promise<{ body: RecoveryKeyBody; deviceId: string }> {
  const me = chain.trusted.get(approver.deviceId);
  if (!me || me.sign_public_key !== approver.signPub) throw new RecoveryKeyError('This device is not a chain-approved approver');
  const sign = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']) as CryptoKeyPair;
  const ecdh = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair;
  const signPub = toLowerHex(new Uint8Array(await crypto.subtle.exportKey('raw', sign.publicKey)));
  const ecdhPub = toLowerHex(new Uint8Array(await crypto.subtle.exportKey('raw', ecdh.publicKey)));
  const deviceId = await deviceIdFor(signPub);
  const signPkcs8 = new Uint8Array(await crypto.subtle.exportKey('pkcs8', sign.privateKey));
  const ecdhPkcs8 = new Uint8Array(await crypto.subtle.exportKey('pkcs8', ecdh.privateKey));
  try {
    const wrap = await sealKeyringWrap(approver, chain.userId, { device_id: deviceId, ecdh_public_key: ecdhPub, wrap_alg: WRAP_ALG_ECDH_P256_HKDF_AES }, chain.version + 1, keyringBytes);
    if (wrap.json.current_epoch !== chain.currentEpoch) throw new RecoveryKeyError('Keyring is not at the signed current epoch');
    const statement = statementCanonical({
      type: 'approve', user_id: chain.userId, ...nextLogSlot(chain), issuer_device_id: approver.deviceId, issued_at_ms: String(now),
      subject_device_id: deviceId, subject_kind: 'recovery', subject_sign_pub: signPub, subject_ecdh_pub: ecdhPub,
      subject_sign_alg: SIGN_ALG_ECDSA_P256_SHA256, subject_wrap_alg: WRAP_ALG_ECDH_P256_HKDF_AES, subject_label_b64: labelB64(label),
      epoch: String(chain.currentEpoch), epoch_commit: chain.commits.get(chain.currentEpoch) ?? '', wrap_sha256: wrap.sha,
    });
    const secret: RecoverySecret = {
      v: 1, sign_pkcs8: bytesToBase64(signPkcs8), ecdh_pkcs8: bytesToBase64(ecdhPkcs8),
      root_sign_pub: chain.rootSignPub, approval_hash: await logEntryHash(statement),
    };
    const recovery_blob = await sealSecret(entropy, chain.userId, deviceId, secret);
    secret.sign_pkcs8 = '';
    secret.ecdh_pkcs8 = '';
    const signature = JSON.parse(await signP256(approver.signPrivateKey, utf8.encode(statement)));
    return { deviceId, body: { expected_version: chain.version, statement, signature, wrap: wrap.json, recovery_blob } };
  } finally {
    signPkcs8.fill(0);
    ecdhPkcs8.fill(0);
  }
}

async function ecdhMatches(priv: CryptoKey, pubHex: string): Promise<boolean> {
  const eph = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']) as CryptoKeyPair;
  const pub = await crypto.subtle.importKey('raw', lowerHexToBytes(pubHex) as unknown as BufferSource, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const a = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: eph.publicKey }, priv, 256));
  const b = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: pub }, eph.privateKey, 256));
  let diff = a.length ^ b.length;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  a.fill(0);
  b.fill(0);
  return diff === 0;
}

async function credentialFrom(secret: RecoverySecret, dev: VerifiedDevice, userId: string): Promise<RecoveryCredential> {
  const signRaw = base64ToBytes(secret.sign_pkcs8);
  const ecdhRaw = base64ToBytes(secret.ecdh_pkcs8);
  try {
    const signPrivateKey = await crypto.subtle.importKey('pkcs8', signRaw as unknown as BufferSource, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
    const ecdhPrivateKey = await crypto.subtle.importKey('pkcs8', ecdhRaw as unknown as BufferSource, { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
    // The keys must be the ones the signed log approved for this credential.
    const probe = utf8.encode(`heimdall-recovery-v1|probe|${dev.device_id}`);
    if (!(await verifySignature(dev.sign_alg, dev.sign_public_key, probe, await signP256(signPrivateKey, probe)))) throw new RecoveryKeyError('The recovery key does not match its directory entry');
    if (!(await ecdhMatches(ecdhPrivateKey, dev.ecdh_public_key))) throw new RecoveryKeyError('The recovery key does not match its directory entry');
    return Object.freeze({
      userId, deviceId: dev.device_id, kind: 'recovery' as const,
      signAlg: SIGN_ALG_ECDSA_P256_SHA256, wrapAlg: WRAP_ALG_ECDH_P256_HKDF_AES,
      signPrivateKey, ecdhPrivateKey, signPub: dev.sign_public_key, ecdhPub: dev.ecdh_public_key,
      fingerprint: await fingerprintFor(dev.sign_public_key, dev.ecdh_public_key), createdAt: Date.now(),
    });
  } finally {
    signRaw.fill(0);
    ecdhRaw.fill(0);
  }
}

/**
 * Open the recovery credential the words belong to, against a directory verified
 * from genesis. Only chain-trusted (approved, not revoked) recovery credentials are
 * tried. The blob must name this chain's root and the credential's own approval op.
 * Wrong words, another account's words, a tampered blob and a revoked recovery key
 * all fail with a RecoveryKeyError; nothing is installed.
 */
export async function openRecoveryKey(words: string[], chain: VerifiedChain): Promise<RecoveryCredential> {
  let entropy: Uint8Array;
  try {
    entropy = recoveryWordsToEntropy(words);
  } catch {
    throw new RecoveryKeyError('These are not 12 valid recovery words (check the spelling and order)');
  }
  try {
    const candidates = trustedRecoveryKeys(chain).filter((d) => typeof d.row?.recovery_blob === 'string' && d.row.recovery_blob !== '');
    if (candidates.length === 0) throw new RecoveryKeyError('This account has no active recovery key');
    for (const dev of candidates) {
      let secret: RecoverySecret | null;
      try {
        secret = await openSecret(entropy, chain.userId, dev.device_id, dev.row.recovery_blob);
      } catch {
        continue; // a malformed blob is skipped (another candidate may open)
      }
      if (!secret) continue;
      try {
        if (secret.root_sign_pub !== chain.rootSignPub) throw new RecoveryKeyError('The recovery key belongs to another account root; nothing was restored');
        if (secret.approval_hash !== await logEntryHash(dev.approval_statement)) throw new RecoveryKeyError('The recovery key does not match its approval in the device log; nothing was restored');
        return await credentialFrom(secret, dev, chain.userId);
      } finally {
        secret.sign_pkcs8 = '';
        secret.ecdh_pkcs8 = '';
      }
    }
    throw new RecoveryKeyError('These words do not open this account\'s recovery key');
  } finally {
    entropy.fill(0);
  }
}

/** Test seam: seal a blob with a fixed iv (vectors / negative tests only). */
export const __test = { sealSecret, openSecret };
