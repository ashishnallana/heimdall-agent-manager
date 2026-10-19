// Keyring wraps: sealing a keyring copy to a recipient device and opening one
// addressed to this device (docs/plans/passwordless-vault.md §1 "Keyring wrap").
//
//   ephemeral ECDH → HKDF-SHA256(32 zero bytes, "heimdall-keyring-wrap-v1") → AES-256-GCM
//   AAD = heimdall-keyring-wrap-v1|<user_id>|<recipient_device_id>|<directory_version>|<current_epoch>
//
// Every wrap is signed by its maker with a `wrap` statement over wrap_sha256. A
// received wrap is opened only after its signature verifies under a CHAIN-TRUSTED
// approver, and only when it names this device, the expected user and (optionally)
// directory version; the keyring inside must match the wrap's epoch and the signed
// epoch_commit. Raw keyring bytes are zeroed by the caller as soon as they are used.

import { parseKeyringBytes, type ParsedKeyringBytes } from './vaultKeyring.ts';
import {
  WRAP_ALG_ECDH_P256_HKDF_AES,
  WRAP_INFO,
  ecdhHkdfAesKey,
  epochCommit,
  kindPolicy,
  openKeyringWrap,
  signP256,
  signatureObjectText,
  statementCanonical,
  toLowerHex,
  verifySignature,
  wrapAad,
  wrapAlgFromId,
  wrapSha256,
  type KeyringWrap,
} from './vaultStatements.ts';
import type { VerifiedChain } from './vaultDirectoryVerify.ts';

const utf8 = new TextEncoder();

export interface WrapSigner {
  readonly deviceId: string;
  readonly signPrivateKey: CryptoKey;
}

export interface WrapRecipient {
  device_id: string;
  ecdh_public_key: string;
  wrap_alg?: string;
}

/** A wrap as stored on / served by the hub. */
export interface SignedKeyringWrap extends KeyringWrap {
  v: 1;
  signature: { alg: string; sig: string };
}

export class WrapRejectedError extends Error {
  constructor(reason: string) {
    super(`Keyring wrap refused: ${reason}`);
    this.name = 'WrapRejectedError';
  }
}

export async function exportPublicHex(key: CryptoKey): Promise<string> {
  return toLowerHex(new Uint8Array(await crypto.subtle.exportKey('raw', key)));
}

/** epoch_commit hex for `epoch` of HKR1 `bytes` (does not modify `bytes`). */
export async function epochCommitHex(bytes: Uint8Array, userId: string, epoch: number): Promise<string> {
  const parsed = parseKeyringBytes(bytes);
  try {
    const entry = parsed.entries.find((e) => e.epoch === epoch);
    if (!entry) throw new WrapRejectedError(`keyring has no epoch ${epoch}`);
    return toLowerHex(await epochCommit(entry.key, userId, epoch));
  } finally {
    for (const e of parsed.entries) e.key.fill(0);
  }
}

/** Constant-time comparison of two equal-length lowercase hex strings. */
export function hexEqualConstantTime(a: string, b: string): boolean {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Seal HKR1 `keyringBytes` (not modified) to `recipient` at `directoryVersion`, signed by `signer`. */
export async function sealKeyringWrap(
  signer: WrapSigner,
  userId: string,
  recipient: WrapRecipient,
  directoryVersion: number,
  keyringBytes: Uint8Array,
): Promise<{ sha: string; json: SignedKeyringWrap }> {
  if (recipient.wrap_alg !== undefined && recipient.wrap_alg !== '' && !wrapAlgFromId(recipient.wrap_alg)) {
    throw new WrapRejectedError('recipient uses an unsupported wrap algorithm');
  }
  const parsed = parseKeyringBytes(keyringBytes, userId);
  for (const e of parsed.entries) e.key.fill(0);
  const epoch = parsed.currentEpoch;
  const eph = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']) as CryptoKeyPair;
  const key = await ecdhHkdfAesKey(eph.privateKey, recipient.ecdh_public_key, WRAP_INFO, ['encrypt']);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: iv as unknown as BufferSource, additionalData: utf8.encode(wrapAad(userId, recipient.device_id, directoryVersion, epoch)) as unknown as BufferSource, tagLength: 128 },
    key,
    keyringBytes as unknown as BufferSource,
  ));
  const w: KeyringWrap = {
    alg: WRAP_ALG_ECDH_P256_HKDF_AES,
    recipient_device_id: recipient.device_id,
    directory_version: directoryVersion,
    current_epoch: epoch,
    ephemeral_public_key: await exportPublicHex(eph.publicKey),
    iv: toLowerHex(iv),
    ciphertext: toLowerHex(ct),
    wrapped_by_device_id: signer.deviceId,
  };
  const sha = await wrapSha256(w);
  const stmt = wrapStatement(userId, w, sha);
  const sig = JSON.parse(await signP256(signer.signPrivateKey, utf8.encode(stmt)));
  return { sha, json: { v: 1, ...w, signature: sig } };
}

function wrapStatement(userId: string, w: KeyringWrap, sha: string): string {
  return statementCanonical({
    type: 'wrap', user_id: userId, seq: String(w.directory_version), issuer_device_id: w.wrapped_by_device_id,
    subject_device_id: w.recipient_device_id, epoch: String(w.current_epoch), wrap_sha256: sha,
  });
}

export interface OpenWrapExpectation {
  userId: string;
  recipientDeviceId: string;
  recipientEcdhPrivate: CryptoKey;
  chain: VerifiedChain;
}

/**
 * Verify and open a wrap addressed to this device. Returns the parsed keyring (the
 * caller zeroes the entry keys). Refuses: wrong recipient, wrong version, a maker
 * (outside the current epoch's segment of the verified log), a maker that is not a chain-trusted approver, a bad wrap signature, an AAD mismatch, a
 * keyring for another user/epoch, or an epoch_commit that differs from the signed one.
 */
export async function openVerifiedWrap(wrapJson: unknown, exp: OpenWrapExpectation): Promise<ParsedKeyringBytes> {
  if (!wrapJson || typeof wrapJson !== 'object') throw new WrapRejectedError('missing wrap');
  const { v, signature, ...rest } = wrapJson as SignedKeyringWrap;
  const w = rest as KeyringWrap;
  if (v !== 1) throw new WrapRejectedError('unknown wrap version');
  if (w.recipient_device_id !== exp.recipientDeviceId) throw new WrapRejectedError('wrap names a different recipient');
  if (w.current_epoch !== exp.chain.currentEpoch) throw new WrapRejectedError('wrap epoch is not the signed current epoch');
  // A wrap is made by the log op that creates it (the approval of its recipient, or the
  // genesis/revoke/rotate that introduced the current epoch), so its directory_version
  // must lie within the current epoch's segment of the VERIFIED log: from the op that
  // introduced the current epoch up to the verified head.
  const epochStart = exp.chain.epochs.get(exp.chain.currentEpoch)?.seq ?? Number.POSITIVE_INFINITY;
  if (!Number.isSafeInteger(w.directory_version) || w.directory_version < epochStart || w.directory_version > exp.chain.version) {
    throw new WrapRejectedError('wrap names a directory version outside the current epoch of the verified log');
  }
  const maker = exp.chain.trusted.get(w.wrapped_by_device_id);
  if (!maker || !kindPolicy(maker.kind).canApprove) throw new WrapRejectedError('wrap made by a device that is not a chain-trusted approver');
  let sha: string;
  try { sha = await wrapSha256(w); } catch { throw new WrapRejectedError('malformed wrap'); }
  if (!(await verifySignature(maker.sign_alg, maker.sign_public_key, utf8.encode(wrapStatement(exp.userId, w, sha)), signatureObjectText(signature)))) {
    throw new WrapRejectedError('wrap signature does not verify');
  }
  let parsed: ParsedKeyringBytes;
  try {
    parsed = await openKeyringWrap(w, exp.userId, exp.recipientEcdhPrivate);
  } catch (err) {
    throw new WrapRejectedError(`cannot open (${(err as Error).message})`);
  }
  try {
    if (parsed.vaultId !== exp.chain.vaultId) throw new WrapRejectedError('the keyring belongs to another vault than the verified root');
    const cur = parsed.entries.find((e) => e.epoch === parsed.currentEpoch)!;
    const commit = toLowerHex(await epochCommit(cur.key, exp.userId, parsed.currentEpoch));
    const signed = exp.chain.commits.get(parsed.currentEpoch) ?? '';
    if (!hexEqualConstantTime(commit, signed)) throw new WrapRejectedError('epoch_commit does not match the signed epoch statement');
    // Every older epoch we hold a signed commit for must match too.
    for (const e of parsed.entries) {
      const s = exp.chain.commits.get(e.epoch);
      if (s && !hexEqualConstantTime(toLowerHex(await epochCommit(e.key, exp.userId, e.epoch)), s)) {
        throw new WrapRejectedError(`epoch_commit mismatch for epoch ${e.epoch}`);
      }
    }
    return parsed;
  } catch (err) {
    for (const e of parsed.entries) e.key.fill(0);
    throw err;
  }
}
