// Hermetic in-memory "hub" for the passwordless-vault UI tests: it holds a signed
// directory log, device rows, wraps and pairing records, built with the SAME
// production builders a browser uses (vaultDeviceFlows). Nothing here touches the
// network, IndexedDB or a real clock beyond Date.now() for issue times.
//
// The fake hub is deliberately dumb (it appends what it is given) so tests can also
// make it misbehave: forge ops, drop ops, inject rows, swap keys.

import {
  createDeviceIdentity,
  deviceIdFor,
  fingerprintFor,
  labelB64,
  memoryDeviceStore,
  signDeviceText,
  type DeviceIdentity,
  type DevicePins,
} from '../../src/ui/utils/deviceIdentity.ts';
import { pinsFromChain, verifyDirectory, type DirectoryDevice, type DirectoryLogEntry, type VaultDirectory, type VerifiedChain } from '../../src/ui/utils/vaultDirectoryVerify.ts';
import {
  buildBridgeApproval,
  buildBrowserApproval,
  buildGenesis,
  buildPairedRegistration,
  buildRevocation,
  checkBrowserCodeInfo,
} from '../../src/ui/utils/vaultDeviceFlows.ts';
import { derivePairKeys, generatePairCode, generatePairSalt, type PairContext, type PairKeys } from '../../src/ui/utils/vaultPairing.ts';
import { openVerifiedWrap, type SignedKeyringWrap } from '../../src/ui/utils/vaultKeyringWrap.ts';
import { serializeKeyringBytes } from '../../src/ui/utils/vaultKeyring.ts';
import {
  SIGN_ALG_ECDSA_P256_SHA256,
  bridgeUnsealKeyCanonical,
  logEntryHash,
  signP256,
  statementCanonical,
  toLowerHex,
  type Statement,
} from '../../src/ui/utils/vaultStatements.ts';
import { parseStatement } from '../../src/ui/utils/vaultDirectoryVerify.ts';

export const USER = 'usr_fixture';
/** The hub origin the fake hub's pairings bind (pairing stretch). */
export const FIXTURE_HUB_ORIGIN = 'https://hub.example.test:443';
/** The pairing-stretch context of a browser of `userId` with public salt `pairSalt`. */
export const browserPairCtx = (pairSalt: string, userId = USER): PairContext => ({ kind: 'browser', userId, hubOrigin: FIXTURE_HUB_ORIGIN, pairSalt });
const utf8 = new TextEncoder();

export async function newBrowser(userId = USER, kv = memoryDeviceStore()): Promise<DeviceIdentity> {
  return createDeviceIdentity(kv, userId);
}

export interface FakeBridge {
  bridgeId: string;
  deviceId: string;
  identityPub: string;
  identity: CryptoKeyPair;
  /** A signed unseal record (public-key endpoint) for a fresh ephemeral ECDH key. */
  unsealRecord(): Promise<Record<string, unknown>>;
}

interface RegisteredBrowser {
  statement: string;
  pair_key_mac: string;
  pair_salt: string;
  pair_hub_origin: string;
}

export class FakeHub {
  readonly userId: string;
  log: DirectoryLogEntry[] = [];
  rows = new Map<string, DirectoryDevice>();
  wraps = new Map<string, SignedKeyringWrap>();
  pairMacs = new Map<string, string>();
  registered = new Map<string, RegisteredBrowser>();
  retiredHints: string[] = [];
  currentEpoch = 0;
  rootDeviceId = '';
  headHash = '';

  constructor(userId = USER) {
    this.userId = userId;
  }

  get version(): number {
    return this.log.length;
  }

  /** The directory as the hub would serve it (a deep copy each time). */
  dir(): VaultDirectory {
    return JSON.parse(JSON.stringify({
      version: this.version,
      current_epoch: this.currentEpoch,
      root_device_id: this.rootDeviceId,
      head_hash: this.headHash,
      log: this.log,
      devices: [...this.rows.values()],
      retired_hints: this.retiredHints,
      reset: null,
    }));
  }

  chain(pins: DevicePins | null = null): Promise<VerifiedChain> {
    return verifyDirectory(this.dir(), this.userId, pins);
  }

  async pins(): Promise<DevicePins> {
    return pinsFromChain(await this.chain());
  }

  /** Append one signed op exactly as given (the hub does no checking here). */
  async append(statement: string, signature: unknown): Promise<void> {
    const st = parseStatement(statement);
    this.log.push({ seq: this.log.length + 1, statement, signature });
    this.headHash = await logEntryHash(statement);
    if (st && ['genesis', 'revoke', 'rotate'].includes(st.type)) this.currentEpoch = Number(st.epoch);
  }

  /** Recompute head/epoch from the (possibly tampered) log. */
  async rehash(): Promise<void> {
    const ops = this.log;
    this.log = [];
    this.currentEpoch = 0;
    for (const op of ops) await this.append(op.statement, op.signature);
    this.log.forEach((op, i) => { op.seq = ops[i].seq; });
  }

  row(id: string): DirectoryDevice {
    const r = this.rows.get(id);
    if (!r) throw new Error(`no row ${id}`);
    return r;
  }

  /** Raw HKR2 bytes of the current keyring, opened from `holder`'s wrap (caller zeroes). */
  async keyringBytes(holder: DeviceIdentity): Promise<Uint8Array> {
    const chain = await this.chain();
    const parsed = await openVerifiedWrap(this.wraps.get(holder.deviceId), {
      userId: this.userId, recipientDeviceId: holder.deviceId, recipientEcdhPrivate: holder.ecdhPrivateKey, chain,
    });
    try {
      return serializeKeyringBytes(parsed);
    } finally {
      for (const e of parsed.entries) e.key.fill(0);
    }
  }

  // ── honest mutations (built with the production builders) ─────────────────

  async genesis(root: DeviceIdentity, label = 'Root browser'): Promise<void> {
    const body = await buildGenesis(root, label);
    await this.append(body.genesis_statement, body.signature);
    this.rootDeviceId = root.deviceId;
    this.rows.set(root.deviceId, browserRow(root, 'approved', label));
    this.wraps.set(root.deviceId, body.wrap);
  }

  /** POST /vault/devices/register as the hub stores it (pending row + pairing lookup). */
  async register(statement: string, pairLookup: string, pairKeyMac: string, pairSalt: string, pairHubOrigin: string = FIXTURE_HUB_ORIGIN): Promise<{ device_id: string; fingerprint: string; status: string; code_expires_at: string }> {
    const st = parseStatement(statement)!;
    const fingerprint = await fingerprintFor(st.subject_sign_pub, st.subject_ecdh_pub);
    this.rows.set(st.subject_device_id, {
      device_id: st.subject_device_id, kind: 'browser', label: '', fingerprint, status: 'pending',
      sign_alg: st.subject_sign_alg, wrap_alg: st.subject_wrap_alg, sign_public_key: st.subject_sign_pub, ecdh_public_key: st.subject_ecdh_pub,
    });
    this.registered.set(pairLookup, { statement, pair_key_mac: pairKeyMac, pair_salt: pairSalt, pair_hub_origin: pairHubOrigin });
    return { device_id: st.subject_device_id, fingerprint, status: 'pending', code_expires_at: new Date(Date.now() + 600_000).toISOString() };
  }

  /** POST /device/verify {pair_lookup} for a pending browser. */
  codeInfo(lookup: string): any {
    const reg = this.registered.get(lookup);
    if (!reg) throw new Error('unknown pairing lookup');
    const st = parseStatement(reg.statement)!;
    const row = this.row(st.subject_device_id);
    return {
      kind: 'browser', device_id: row.device_id, device_kind: 'browser', fingerprint: row.fingerprint, label: '',
      sign_public_key: row.sign_public_key, ecdh_public_key: row.ecdh_public_key, sign_alg: row.sign_alg, wrap_alg: row.wrap_alg,
      register_statement: reg.statement, pair_key_mac: reg.pair_key_mac, pair_salt: reg.pair_salt, pair_hub_origin: reg.pair_hub_origin,
    };
  }

  /** The approver typed `code`: verify the pairing, sign the approval, wrap, commit. */
  async approveByCode(approver: DeviceIdentity, code: string, label = 'Browser'): Promise<{ deviceId: string; pairMac: string }> {
    // As the approval page does: stretch the code with each pending request's public
    // salt and the hub origin that request declared.
    let keys: PairKeys | null = null;
    for (const reg of this.registered.values()) {
      const k = await derivePairKeys(code, { ...browserPairCtx(reg.pair_salt, this.userId), hubOrigin: reg.pair_hub_origin });
      if (this.registered.has(k.lookup)) { keys = k; break; }
    }
    if (!keys) throw new Error('no pending request matches the code');
    const chain = await this.chain();
    const paired = await checkBrowserCodeInfo(this.codeInfo(keys.lookup), keys, this.userId);
    const kr = await this.keyringBytes(approver);
    try {
      const body = await buildBrowserApproval(approver, chain, paired, keys, label, kr);
      await this.append(body.statement, body.signature);
      const row = this.row(paired.device_id);
      Object.assign(row, { status: 'approved', label, approved_by_device_id: approver.deviceId });
      this.wraps.set(paired.device_id, body.wrap);
      this.pairMacs.set(paired.device_id, body.pair_mac);
      return { deviceId: paired.device_id, pairMac: body.pair_mac };
    } finally {
      kr.fill(0);
    }
  }

  /** Register + approve `device` in one go (a browser driven outside deviceVault). */
  async addBrowser(approver: DeviceIdentity, device: DeviceIdentity, label = 'Browser'): Promise<{ code: string; keys: PairKeys }> {
    const code = generatePairCode();
    const salt = generatePairSalt();
    const keys = await derivePairKeys(code, browserPairCtx(salt, this.userId));
    const reg = await buildPairedRegistration(device, label, keys);
    await this.register(reg.statement, reg.pairLookup, reg.pairKeyMac, salt);
    await this.approveByCode(approver, code, label);
    return { code, keys };
  }

  async addBridge(approver: DeviceIdentity, bridgeId: string, label = 'bridge'): Promise<FakeBridge> {
    const identity = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify']) as CryptoKeyPair;
    const identityPub = toLowerHex(new Uint8Array(await crypto.subtle.exportKey('raw', identity.publicKey)));
    const chain = await this.chain();
    const built = await buildBridgeApproval(approver, chain, { kind: 'bridge', bridge_identity_public_key: identityPub, pair_key_mac: '', code_challenge: '' }, label);
    await this.append(built.vault_approval.statement, built.vault_approval.signature);
    this.rows.set(built.subjectDeviceId, {
      device_id: built.subjectDeviceId, kind: 'bridge', label, status: 'approved', sign_alg: SIGN_ALG_ECDSA_P256_SHA256, wrap_alg: '',
      sign_public_key: identityPub, ecdh_public_key: '', bridge_id: bridgeId, approved_by_device_id: approver.deviceId,
    });
    return makeFakeBridge(bridgeId, built.subjectDeviceId, identityPub, identity);
  }

  async revoke(approver: DeviceIdentity, targetId: string): Promise<void> {
    const chain = await this.chain();
    const kr = await this.keyringBytes(approver);
    try {
      const { body, nextKeyring } = await buildRevocation(approver, chain, targetId, kr);
      nextKeyring.fill(0);
      await this.append(body.revoke_statement, body.signature);
      Object.assign(this.row(targetId), { status: 'revoked', revoked_by_device_id: approver.deviceId });
      this.wraps.delete(targetId);
      for (const w of body.wraps) this.wraps.set(w.recipient_device_id, w);
    } finally {
      kr.fill(0);
    }
  }

  // ── misbehaviour helpers ───────────────────────────────────────────────────

  /**
   * A log op with arbitrary fields, signed by `signer`, at the hub's next slot
   * (seq/prev_hash default to the honest values so only the chosen field is wrong).
   */
  async forgeOp(signer: { deviceId: string; signPrivateKey: CryptoKey }, fields: Statement): Promise<{ statement: string; signature: unknown }> {
    const statement = statementCanonical({
      user_id: this.userId, seq: String(this.version + 1), prev_hash: this.headHash, issuer_device_id: signer.deviceId,
      issued_at_ms: String(Date.now()), epoch: String(this.currentEpoch), ...fields,
    });
    return { statement, signature: JSON.parse(await signP256(signer.signPrivateKey, utf8.encode(statement))) };
  }

  /** The approval subject fields for `device`, as an approve op names them. */
  async subjectOf(device: DeviceIdentity, label = 'Browser'): Promise<Statement> {
    return {
      type: 'approve', subject_device_id: device.deviceId, subject_kind: 'browser', subject_sign_pub: device.signPub,
      subject_ecdh_pub: device.ecdhPub, subject_sign_alg: device.signAlg, subject_wrap_alg: device.wrapAlg,
      subject_label_b64: labelB64(label), epoch_commit: (await this.chain()).commits.get(this.currentEpoch) ?? '',
    };
  }
}

export function browserRow(identity: DeviceIdentity, status: string, label = 'Browser'): DirectoryDevice {
  return {
    device_id: identity.deviceId, kind: 'browser', label, fingerprint: identity.fingerprint, status,
    sign_alg: identity.signAlg, wrap_alg: identity.wrapAlg, sign_public_key: identity.signPub, ecdh_public_key: identity.ecdhPub,
  };
}

function makeFakeBridge(bridgeId: string, deviceId: string, identityPub: string, identity: CryptoKeyPair): FakeBridge {
  return {
    bridgeId, deviceId, identityPub, identity,
    async unsealRecord() {
      const eph = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']) as CryptoKeyPair;
      const ecdhPub = toLowerHex(new Uint8Array(await crypto.subtle.exportKey('raw', eph.publicKey)));
      const bootId = toLowerHex(crypto.getRandomValues(new Uint8Array(16)));
      const sig = await signP256(identity.privateKey, utf8.encode(bridgeUnsealKeyCanonical(bridgeId, ecdhPub, bootId)));
      return {
        bridge_id: bridgeId, public_key: ecdhPub, unseal_boot_id: bootId, unseal_key_signature: JSON.parse(sig),
        bridge_identity_public_key: identityPub, bridge_identity_sign_alg: SIGN_ALG_ECDSA_P256_SHA256,
      };
    },
  };
}

/** A fresh random P-256 signing key that no directory knows (an attacker's device). */
export async function strangerSigner(): Promise<{ deviceId: string; signPrivateKey: CryptoKey; signPub: string }> {
  const kp = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify']) as CryptoKeyPair;
  const signPub = toLowerHex(new Uint8Array(await crypto.subtle.exportKey('raw', kp.publicKey)));
  return { deviceId: await deviceIdFor(signPub), signPrivateKey: kp.privateKey, signPub };
}

export { signDeviceText };

/**
 * The vault API surface deviceVault uses, served from `hub`. `self` can be
 * overridden per test to make the hub lie about this device.
 */
export function hubApi(hub: FakeHub, overrides: Record<string, (...args: any[]) => Promise<any>> = {}): any {
  const api: Record<string, (...args: any[]) => Promise<any>> = {
    fetchVaultDirectory: async () => (hub.version ? hub.dir() : null),
    fetchVaultSelf: async (signed: { signer: { deviceId: string } }) => {
      const id = signed.signer.deviceId;
      const row = hub.rows.get(id);
      if (!row) return null;
      return { device_id: id, status: row.status, directory_version: hub.version, wrap: hub.wraps.get(id) ?? null, pair_mac: hub.pairMacs.get(id) ?? '' };
    },
    postVaultRegister: async (statement: string, _sig: unknown, lookup: string, mac: string, salt: string, origin: string) => hub.register(statement, lookup, mac, salt, origin),
    pairingHubOrigin: (() => FIXTURE_HUB_ORIGIN) as any,
    ...overrides,
  };
  const refuse = (name: string) => async () => { throw new Error(`unexpected vault API call in test: ${name}`); };
  return new Proxy(api, { get: (t, k: string) => t[k] ?? refuse(k) });
}

/** Records dispatched actions; `last(type)` is the payload of the latest of that type. */
export function recorder() {
  const actions: Array<{ type: string; payload?: any }> = [];
  const dispatch = (a: any) => { actions.push(a); return a; };
  const last = (type: string) => [...actions].reverse().find((a) => a.type === type)?.payload;
  return { actions, dispatch, last };
}
