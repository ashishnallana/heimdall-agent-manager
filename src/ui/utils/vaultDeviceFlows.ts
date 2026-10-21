// Builders for the signed vault-directory mutations (docs/plans/passwordless-vault.md
// §1 "Signed statements", §2 P2 endpoints). Pure protocol: no I/O, no Redux. Every
// builder takes a VERIFIED chain (vaultDirectoryVerify) and refuses to sign about,
// or wrap to, anything the chain does not vouch for.

import { deviceIdFor, deviceSubject, fingerprintFor, labelB64, labelFromB64, signDeviceText, type DeviceIdentity } from './deviceIdentity.ts';
import { nextLogSlot, parseStatement, remainingApprovers, wrapRecipients, type VerifiedChain, type VerifiedDevice } from './vaultDirectoryVerify.ts';
import { pairApproveMac, pairBridgePayload, pairKeyMac, verifyPairKeyMac, type PairKeys } from './vaultPairing.ts';
import { epochCommitHex, sealKeyringWrap, type SignedKeyringWrap } from './vaultKeyringWrap.ts';
import { genesisKeyringBytes, nextEpochKeyringBytes } from './vaultKeyringSession.ts';
import { vaultIdFor } from './vaultKeyring.ts';
import {
  SIGN_ALG_ECDSA_P256_SHA256,
  deviceKindFromId,
  kindPolicy,
  signAlgFromId,
  statementCanonical,
  wrapAlgFromId,
} from './vaultStatements.ts';
import type { BrowserApprovalBody, BrowserCodeInfo, BridgeCodeInfo, GenesisBody, RevokeBody, RotateBody } from '../api/endpoints/vaultDevices.ts';

const sig = async (identity: DeviceIdentity, text: string) => JSON.parse(await signDeviceText(identity, text));

export class FlowRefused extends Error {
  constructor(reason: string) {
    super(reason);
    this.name = 'FlowRefused';
  }
}

/** Self-signed `register` statement for this device. */
export async function buildRegistration(identity: DeviceIdentity, label: string, now = Date.now()): Promise<{ statement: string; signature: unknown }> {
  const statement = statementCanonical({
    ...deviceSubject(identity, label),
    type: 'register',
    user_id: identity.userId,
    issuer_device_id: identity.deviceId,
    issued_at_ms: String(now),
  });
  return { statement, signature: await sig(identity, statement) };
}

/**
 * Registration bound to this device's secret pairing code (plan §1 "Pairing"): the
 * hub gets the lookup and a key_mac over the register statement, never the code.
 */
export async function buildPairedRegistration(identity: DeviceIdentity, label: string, keys: PairKeys, now = Date.now()) {
  const reg = await buildRegistration(identity, label, now);
  return { ...reg, pairLookup: keys.lookup, pairKeyMac: await pairKeyMac(keys, 'browser', reg.statement) };
}

/**
 * Genesis body for the first device: a fresh epoch-1 keyring, self-wrapped at version 1,
 * plus the self-signed genesis (log seq 1, introduces epoch 1). The keyring bytes are
 * zeroed here.
 */
export async function buildGenesis(identity: DeviceIdentity, label: string, now = Date.now()): Promise<GenesisBody> {
  const userId = identity.userId;
  // The genesis device is the root: the vault id is derived from its signing key.
  const kr = genesisKeyringBytes(userId, await vaultIdFor(identity.signPub));
  try {
    const commit = await epochCommitHex(kr, userId, 1);
    const wrap = await sealKeyringWrap(identity, userId, { device_id: identity.deviceId, ecdh_public_key: identity.ecdhPub, wrap_alg: identity.wrapAlg }, 1, kr);
    const ts = String(now);
    const genesis = statementCanonical({
      ...deviceSubject(identity, label), type: 'genesis', user_id: userId, seq: '1', prev_hash: '', issuer_device_id: identity.deviceId,
      issued_at_ms: ts, epoch: '1', epoch_commit: commit, wrap_sha256: wrap.sha,
    });
    return { genesis_statement: genesis, signature: await sig(identity, genesis), wrap: wrap.json };
  } finally {
    kr.fill(0);
  }
}

function requireApprover(chain: VerifiedChain, identity: DeviceIdentity): VerifiedDevice {
  const me = chain.trusted.get(identity.deviceId);
  if (!me || !kindPolicy(me.kind).canApprove || me.sign_public_key !== identity.signPub) throw new FlowRefused('This device is not a chain-approved approver');
  return me;
}

/** A pending browser as its OWN self-signed register statement describes it. */
export interface PairedBrowser {
  device_id: string;
  sign_public_key: string;
  ecdh_public_key: string;
  sign_alg: string;
  wrap_alg: string;
  /** Label the device proposed (the approver may rename it). */
  label: string;
  fingerprint: string;
  register_statement: string;
}

/**
 * Hub-blind pairing (plan §1 "Pairing"): the hub served `info` for the lookup derived
 * from the code the user typed. Its pair_key_mac must verify under that code over the
 * device's register statement — proof the hub did not swap the device's keys — and
 * the statement must be a well-formed self-registration of a browser in `userId`.
 * Everything the approval names is taken from that statement, never from the row.
 */
export async function checkBrowserCodeInfo(info: BrowserCodeInfo, keys: PairKeys, userId: string): Promise<PairedBrowser> {
  if (info.kind !== 'browser') throw new FlowRefused('Not a browser pairing request');
  if (!(await verifyPairKeyMac(keys, 'browser', String(info.register_statement ?? ''), info.pair_key_mac))) {
    throw new FlowRefused('The pairing check failed: the code does not match this request, or the server changed the device keys. Nothing was approved.');
  }
  const st = parseStatement(info.register_statement);
  if (!st || st.type !== 'register' || st.user_id !== userId) throw new FlowRefused('The pairing request is not a registration for this account');
  if (deviceKindFromId(st.subject_kind) !== 'browser' || st.issuer_device_id !== st.subject_device_id) throw new FlowRefused('The pairing request is not a self-registered browser');
  if (!signAlgFromId(st.subject_sign_alg) || !wrapAlgFromId(st.subject_wrap_alg)) throw new FlowRefused('The device uses an unsupported algorithm');
  if (st.subject_device_id !== await deviceIdFor(st.subject_sign_pub)) throw new FlowRefused('The device id does not match its key');
  const fingerprint = await fingerprintFor(st.subject_sign_pub, st.subject_ecdh_pub);
  // The row is display metadata; a row that contradicts the MACed statement is refused.
  if (info.device_id !== st.subject_device_id || info.sign_public_key !== st.subject_sign_pub || info.ecdh_public_key !== st.subject_ecdh_pub) {
    throw new FlowRefused('The server described a different device than the one that registered');
  }
  return {
    device_id: st.subject_device_id, sign_public_key: st.subject_sign_pub, ecdh_public_key: st.subject_ecdh_pub,
    sign_alg: st.subject_sign_alg, wrap_alg: st.subject_wrap_alg, label: labelFromB64(st.subject_label_b64),
    fingerprint, register_statement: info.register_statement,
  };
}

/**
 * Approval statement + wrap of the current keyring for a pending browser, plus the
 * pair_mac the new device checks with its code before trusting the account root.
 */
export async function buildBrowserApproval(
  approver: DeviceIdentity,
  chain: VerifiedChain,
  device: PairedBrowser,
  keys: PairKeys,
  label: string,
  keyringBytes: Uint8Array,
  now = Date.now(),
): Promise<BrowserApprovalBody> {
  requireApprover(chain, approver);
  if (chain.trusted.has(device.device_id)) throw new FlowRefused('This device is already approved');
  if (chain.everApproved.has(device.device_id)) throw new FlowRefused('This device key was approved before and cannot be approved again');
  const slot = nextLogSlot(chain);
  const wrap = await sealKeyringWrap(approver, chain.userId, { device_id: device.device_id, ecdh_public_key: device.ecdh_public_key, wrap_alg: device.wrap_alg }, chain.version + 1, keyringBytes);
  if (wrap.json.current_epoch !== chain.currentEpoch) throw new FlowRefused('Keyring is not at the signed current epoch');
  const statement = statementCanonical({
    type: 'approve', user_id: chain.userId, ...slot, issuer_device_id: approver.deviceId, issued_at_ms: String(now),
    subject_device_id: device.device_id, subject_kind: 'browser', subject_sign_pub: device.sign_public_key, subject_ecdh_pub: device.ecdh_public_key,
    subject_sign_alg: device.sign_alg, subject_wrap_alg: device.wrap_alg, subject_label_b64: labelB64(label || 'browser'),
    epoch: String(chain.currentEpoch), epoch_commit: chain.commits.get(chain.currentEpoch) ?? '', wrap_sha256: wrap.sha,
  });
  return {
    pair_lookup: keys.lookup,
    pair_mac: await pairApproveMac(keys, statement, chain.rootSignPub),
    expected_version: chain.version, statement, signature: await sig(approver, statement), wrap: wrap.json,
  };
}

/**
 * Hub-blind pairing for a bridge: its pair_key_mac (made by `ham-bridge enroll` under
 * the code it printed) must verify over identity key | enrollment ECDH key | PKCE
 * challenge as the hub served them.
 */
export async function checkBridgeCodeInfo(info: BridgeCodeInfo, keys: PairKeys): Promise<void> {
  if (info.kind !== 'bridge' || info.is_bridge_enrollment !== true) throw new FlowRefused('Not a bridge pairing request');
  const identity = String(info.bridge_identity_public_key ?? '');
  const ecdh = String(info.bridge_public_key ?? '');
  const onRecord = String((info.hub_observed as Record<string, unknown> | undefined)?.bridge_public_key_on_record ?? '');
  if (onRecord !== ecdh) throw new FlowRefused('The server reported two different bridge keys');
  let payload: string;
  try {
    payload = pairBridgePayload(identity, ecdh, String(info.code_challenge ?? ''));
  } catch {
    throw new FlowRefused('The server sent a malformed bridge request');
  }
  if (!(await verifyPairKeyMac(keys, 'bridge', payload, info.pair_key_mac))) {
    throw new FlowRefused('The pairing check failed: the code does not match this bridge, or the server changed its keys. Nothing was approved.');
  }
}

/** Approval statement for a bridge identity key (`vault_approval` on /device/approve). No wrap. */
export async function buildBridgeApproval(approver: DeviceIdentity, chain: VerifiedChain, info: BridgeCodeInfo, label: string, now = Date.now()) {
  requireApprover(chain, approver);
  const identityPub = String(info.bridge_identity_public_key || '').trim();
  const subjectId = await deviceIdFor(identityPub); // throws on a malformed key
  if (chain.trusted.has(subjectId)) throw new FlowRefused('This bridge identity is already approved');
  if (chain.everApproved.has(subjectId)) throw new FlowRefused('This bridge identity was approved before and cannot be approved again');
  const statement = statementCanonical({
    type: 'approve', user_id: chain.userId, ...nextLogSlot(chain), issuer_device_id: approver.deviceId, issued_at_ms: String(now),
    subject_device_id: subjectId, subject_kind: 'bridge', subject_sign_pub: identityPub, subject_ecdh_pub: '',
    subject_sign_alg: SIGN_ALG_ECDSA_P256_SHA256, subject_wrap_alg: '', subject_label_b64: labelB64(label || 'bridge'),
    epoch: String(chain.currentEpoch), epoch_commit: chain.commits.get(chain.currentEpoch) ?? '',
  });
  return { subjectDeviceId: subjectId, statement, vault_approval: { expected_version: chain.version, statement, signature: await sig(approver, statement) } };
}

/**
 * Revocation of `targetId`: ONE signed `revoke` log op that names the target and
 * introduces epoch current+1 (so a revocation can never be split from its rotation).
 * Wraps go to EXACTLY the chain-trusted wrap recipients minus the target, at the
 * version the op creates. Returns the body and the next keyring bytes (caller zeroes).
 */
export async function buildRevocation(
  approver: DeviceIdentity,
  chain: VerifiedChain,
  targetId: string,
  currentKeyringBytes: Uint8Array,
  now = Date.now(),
): Promise<{ body: RevokeBody; nextKeyring: Uint8Array }> {
  requireApprover(chain, approver);
  if (targetId === approver.deviceId) throw new FlowRefused('This device cannot revoke itself');
  const target = chain.trusted.get(targetId);
  if (!target) throw new FlowRefused('That device is not approved');
  if (kindPolicy(target.kind).countsAsApprover && remainingApprovers(chain, targetId, approver.deviceId).length === 0) {
    throw new FlowRefused('Refusing to revoke the only other approver: create a recovery key first');
  }
  const next = nextEpochKeyringBytes(currentKeyringBytes, chain.userId);
  try {
    const epoch = chain.currentEpoch + 1;
    const commit = await epochCommitHex(next, chain.userId, epoch);
    const revoke = statementCanonical({
      type: 'revoke', user_id: chain.userId, ...nextLogSlot(chain), issuer_device_id: approver.deviceId, issued_at_ms: String(now),
      subject_device_id: target.device_id, subject_kind: target.kind, subject_sign_pub: target.sign_public_key, subject_ecdh_pub: target.ecdh_public_key,
      subject_sign_alg: target.sign_alg, subject_wrap_alg: target.wrap_alg, subject_label_b64: labelB64(target.label || target.kind),
      epoch: String(epoch), epoch_commit: commit,
    });
    const wraps: SignedKeyringWrap[] = [];
    for (const d of wrapRecipients(chain)) {
      if (d.device_id === targetId) continue;
      wraps.push((await sealKeyringWrap(approver, chain.userId, d, chain.version + 1, next)).json);
    }
    const body: RevokeBody = { expected_version: chain.version, revoke_statement: revoke, signature: await sig(approver, revoke), wraps };
    return { body, nextKeyring: next };
  } catch (err) {
    next.fill(0);
    throw err;
  }
}

/**
 * Explicit user-initiated rotation (POST /vault/directory/rotate): one signed
 * `rotate` log op with no subject, introducing epoch current+1, and wraps to EXACTLY
 * the chain-trusted wrap recipients. Returns the body and the next keyring bytes.
 */
export async function buildRotation(
  approver: DeviceIdentity,
  chain: VerifiedChain,
  currentKeyringBytes: Uint8Array,
  now = Date.now(),
): Promise<{ body: RotateBody; nextKeyring: Uint8Array }> {
  requireApprover(chain, approver);
  const next = nextEpochKeyringBytes(currentKeyringBytes, chain.userId);
  try {
    const epoch = chain.currentEpoch + 1;
    const commit = await epochCommitHex(next, chain.userId, epoch);
    const statement = statementCanonical({ type: 'rotate', user_id: chain.userId, ...nextLogSlot(chain), issuer_device_id: approver.deviceId, issued_at_ms: String(now), epoch: String(epoch), epoch_commit: commit });
    const wraps: SignedKeyringWrap[] = [];
    for (const d of wrapRecipients(chain)) wraps.push((await sealKeyringWrap(approver, chain.userId, d, chain.version + 1, next)).json);
    return { body: { expected_version: chain.version, statement, signature: await sig(approver, statement), wraps }, nextKeyring: next };
  } catch (err) {
    next.fill(0);
    throw err;
  }
}

export interface RotateDeps {
  fetchChain: () => Promise<VerifiedChain>;
  withKeyringBytes: <T>(chain: VerifiedChain, fn: (bytes: Uint8Array) => Promise<T>) => Promise<T>;
  post: (body: RotateBody) => Promise<{ directory_version: number }>;
  afterRotation?: () => Promise<void>;
  isConflict: (err: unknown) => boolean;
}

export type RotateOutcome = { kind: 'rotated'; epoch: number } | { kind: 'not-needed' };

/**
 * Rotate once (explicit user action). On a 409, re-fetch and re-verify; if the epoch
 * already advanced meanwhile (another device rotated or revoked), stop — never
 * rotate twice for one request.
 */
export async function rotateWithRetry(approver: DeviceIdentity, deps: RotateDeps): Promise<RotateOutcome> {
  let startEpoch = 0;
  for (let attempt = 0; attempt < 2; attempt++) {
    const chain = await deps.fetchChain();
    if (attempt === 0) startEpoch = chain.currentEpoch;
    else if (chain.currentEpoch > startEpoch) return { kind: 'not-needed' };
    let nextKeyring: Uint8Array | null = null;
    try {
      await deps.withKeyringBytes(chain, async (bytes) => {
        const built = await buildRotation(approver, chain, bytes);
        nextKeyring = built.nextKeyring;
        await deps.post(built.body);
      });
    } catch (err) {
      (nextKeyring as Uint8Array | null)?.fill(0);
      if (attempt === 0 && deps.isConflict(err)) continue;
      throw err;
    }
    (nextKeyring as Uint8Array | null)?.fill(0);
    if (deps.afterRotation) await deps.afterRotation();
    return { kind: 'rotated', epoch: chain.currentEpoch + 1 };
  }
  throw new FlowRefused('The directory kept changing; rotation not done');
}

export interface RevokeDeps {
  /** Fetch + verify the directory against the pins (throws on any failure). */
  fetchChain: () => Promise<VerifiedChain>;
  /** Transient current keyring bytes valid for `chain` (zeroed by the callee after fn). */
  withKeyringBytes: <T>(chain: VerifiedChain, fn: (bytes: Uint8Array) => Promise<T>) => Promise<T>;
  post: (targetId: string, body: RevokeBody) => Promise<{ directory_version: number }>;
  /** After a successful rotation (reinstall from the new self-wrap, re-unseal bridges). */
  afterRotation?: () => Promise<void>;
  isConflict: (err: unknown) => boolean;
}

export type RevokeOutcome = { kind: 'revoked'; version: number } | { kind: 'already-revoked' };

/**
 * Revoke with CAS: on a 409 version conflict, re-fetch and re-verify the directory
 * and retry ONCE. If the refetched chain shows the target already revoked, stop:
 * never rotate twice for one revoke.
 */
export async function revokeWithRetry(approver: DeviceIdentity, targetId: string, deps: RevokeDeps): Promise<RevokeOutcome> {
  for (let attempt = 0; attempt < 2; attempt++) {
    const chain = await deps.fetchChain();
    if (!chain.trusted.has(targetId)) {
      if (attempt > 0 || chain.revokedIds.has(targetId)) return { kind: 'already-revoked' };
      throw new FlowRefused('That device is not approved');
    }
    let posted: { directory_version: number } | null = null;
    let nextKeyring: Uint8Array | null = null;
    try {
      await deps.withKeyringBytes(chain, async (bytes) => {
        const built = await buildRevocation(approver, chain, targetId, bytes);
        nextKeyring = built.nextKeyring;
        posted = await deps.post(targetId, built.body);
      });
    } catch (err) {
      (nextKeyring as Uint8Array | null)?.fill(0);
      if (attempt === 0 && deps.isConflict(err)) continue;
      throw err;
    }
    (nextKeyring as Uint8Array | null)?.fill(0);
    if (deps.afterRotation) await deps.afterRotation();
    return { kind: 'revoked', version: (posted as { directory_version: number } | null)?.directory_version ?? chain.version + 1 };
  }
  throw new FlowRefused('The directory kept changing; try again');
}
