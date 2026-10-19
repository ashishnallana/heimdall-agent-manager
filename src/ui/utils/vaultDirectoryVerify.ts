// Client-side verification of the account's vault device directory
// (docs/plans/passwordless-vault.md §2 P3 "vaultDirectoryVerify.ts", threat model §3).
//
// The hub is hostile for the directory's integrity: everything it serves is checked
// here before any key is wrapped to, trusted from, or unsealed for a device.
//
// Walk: genesis (self-signed root) → approvals / revocations / epochs in
// directory_version order. An approval is trusted only when its issuer was an
// approved, approver-capable device AT THAT VERSION (so approvals made after the
// approver was revoked are refused) and the statement matches the device row
// exactly. A device row without a valid approval is reported `untrusted` and never
// wrapped to. A bad genesis, revocation or epoch statement refuses the WHOLE
// directory: there is no partial trust in the key history. Fails closed: any parse
// or signature failure is a refusal, never a skip.

import { deviceIdFor, labelFromB64, checkAgainstPins, type DevicePins } from './deviceIdentity.ts';
import {
  STATEMENT_FIELDS,
  STATEMENT_HEADER,
  deviceKindFromId,
  kindPolicy,
  signAlgFromId,
  signatureObjectText,
  statementCanonical,
  verifySignature,
  wrapAlgFromId,
  type DeviceKind,
  type Statement,
} from './vaultStatements.ts';

const utf8 = new TextEncoder();

// ── wire shapes (GET /api/v1/vault/directory) ────────────────────────────────

export interface DirectoryDevice {
  device_id: string;
  kind: string;
  label?: string;
  fingerprint?: string;
  status: 'pending' | 'approved' | 'revoked' | string;
  sign_alg: string;
  wrap_alg: string;
  sign_public_key: string;
  ecdh_public_key: string;
  bridge_id?: string;
  approved_by_device_id?: string;
  approval_statement?: string;
  approval_signature?: unknown;
  revoked_by_device_id?: string;
  revocation_statement?: string;
  revocation_signature?: unknown;
  created_at?: string;
  approved_at?: string;
  revoked_at?: string;
  last_seen_at?: string;
}

export interface DirectoryEpoch {
  epoch: number;
  statement: string;
  signature: unknown;
}

/** Reset state reported by the hub (P2 fix: 72 h delayed reset). */
export interface DirectoryReset {
  requested_at?: string;
  due_at?: string;
  requested_by_device_id?: string;
}

export interface VaultDirectory {
  configured?: boolean;
  version: number;
  current_epoch: number;
  root_device_id: string;
  genesis: { statement: string; signature: unknown };
  devices: DirectoryDevice[];
  epochs: DirectoryEpoch[];
  reset?: DirectoryReset | null;
}

// ── statement parsing ────────────────────────────────────────────────────────

export type ParsedStatement = Record<(typeof STATEMENT_FIELDS)[number], string>;

/** Parse canonical statement text; null unless it re-renders byte-identically. */
export function parseStatement(text: unknown): ParsedStatement | null {
  if (typeof text !== 'string') return null;
  const lines = text.split('\n');
  if (lines[0] !== STATEMENT_HEADER || lines.length !== STATEMENT_FIELDS.length + 1) return null;
  const st: Record<string, string> = {};
  for (let i = 0; i < STATEMENT_FIELDS.length; i++) {
    const line = lines[i + 1];
    const eq = line.indexOf('=');
    if (eq < 0 || line.slice(0, eq) !== STATEMENT_FIELDS[i]) return null;
    st[STATEMENT_FIELDS[i]] = line.slice(eq + 1);
  }
  try {
    return statementCanonical(st as Statement) === text ? (st as ParsedStatement) : null;
  } catch {
    return null;
  }
}

// ── result ───────────────────────────────────────────────────────────────────

/** A chain-verified device. Every field comes from the SIGNED statement, not the row. */
export interface VerifiedDevice {
  device_id: string;
  kind: DeviceKind;
  sign_alg: string;
  wrap_alg: string;
  sign_public_key: string;
  ecdh_public_key: string;
  /** Label as signed into the approval (or genesis) statement. */
  label: string;
  /** Issuer of the approval; the root's own id for the root. */
  approved_by_device_id: string;
  approval_statement: string;
  approval_signature: string;
  approval_version: number;
  row: DirectoryDevice;
}

export interface EpochProof {
  epoch: number;
  statement: string;
  signature: string;
  issuer_device_id: string;
  epoch_commit: string;
}

export interface VerifiedChain {
  userId: string;
  rootDeviceId: string;
  rootSignPub: string;
  rootSignAlg: string;
  version: number;
  currentEpoch: number;
  genesis: { statement: string; signature: string };
  /** Approved now, chain-verified. */
  trusted: Map<string, VerifiedDevice>;
  /** Every device whose approval ever verified (revoked ones included); for issuer chains. */
  everApproved: Map<string, VerifiedDevice>;
  /** Rows the hub calls approved but whose approval does not verify. Never wrapped to. */
  untrusted: DirectoryDevice[];
  pending: DirectoryDevice[];
  revoked: DirectoryDevice[];
  /** epoch -> epoch_commit (hex), from signed epoch statements. */
  commits: Map<number, string>;
  epochs: Map<number, EpochProof>;
}

export class DirectoryVerificationError extends Error {
  constructor(reason: string) {
    super(`Vault directory does not verify: ${reason}`);
    this.name = 'DirectoryVerificationError';
  }
}

function fail(reason: string): never {
  throw new DirectoryVerificationError(reason);
}

function subjectMatchesRow(st: ParsedStatement, d: DirectoryDevice): boolean {
  return st.subject_device_id === d.device_id && st.subject_kind === d.kind && st.subject_sign_pub === d.sign_public_key
    && st.subject_ecdh_pub === (d.ecdh_public_key ?? '') && st.subject_sign_alg === d.sign_alg && st.subject_wrap_alg === (d.wrap_alg ?? '');
}

function subjectWellFormed(st: ParsedStatement): boolean {
  const kind = deviceKindFromId(st.subject_kind);
  if (!kind || !signAlgFromId(st.subject_sign_alg)) return false;
  if (kindPolicy(kind).receivesWrap) return Boolean(wrapAlgFromId(st.subject_wrap_alg)) && st.subject_ecdh_pub !== '';
  return st.subject_wrap_alg === '' && st.subject_ecdh_pub === '';
}

const isNat = (s: string) => /^(0|[1-9][0-9]{0,15})$/.test(s);
const COMMIT_RE = /^[0-9a-f]{64}$/;

function verified(st: ParsedStatement, row: DirectoryDevice, text: string, sig: string, version: number): VerifiedDevice {
  return {
    device_id: st.subject_device_id,
    kind: deviceKindFromId(st.subject_kind)!,
    sign_alg: st.subject_sign_alg,
    wrap_alg: st.subject_wrap_alg,
    sign_public_key: st.subject_sign_pub,
    ecdh_public_key: st.subject_ecdh_pub,
    label: labelFromB64(st.subject_label_b64),
    approved_by_device_id: st.issuer_device_id,
    approval_statement: text,
    approval_signature: sig,
    approval_version: version,
    row,
  };
}

type Op =
  | { op: 'approve'; st: ParsedStatement | null; text: string; sig: string; row: DirectoryDevice; v: number }
  | { op: 'revoke'; st: ParsedStatement | null; text: string; sig: string; row: DirectoryDevice; v: number }
  | { op: 'epoch'; st: ParsedStatement | null; text: string; sig: string; v: number };

const RANK = { approve: 0, revoke: 1, epoch: 2 } as const;

/**
 * Verify the whole directory for `userId`. `pins` (when present) must match the root
 * and must not be ahead of the served version/epoch. Throws DirectoryVerificationError
 * (or PinViolationError) on refusal.
 */
export async function verifyDirectory(dir: VaultDirectory, userId: string, pins: DevicePins | null = null): Promise<VerifiedChain> {
  if (!dir || typeof dir !== 'object' || !Array.isArray(dir.devices) || !Array.isArray(dir.epochs)) fail('malformed directory');
  if (!Number.isSafeInteger(dir.version) || dir.version < 1) fail('malformed directory version');

  // Genesis: self-issued by the root, epoch 1, version 0.
  const genesisText = dir.genesis?.statement;
  const genesisSig = signatureObjectText(dir.genesis?.signature);
  const g = parseStatement(genesisText);
  if (!g || g.type !== 'genesis' || g.user_id !== userId || g.directory_version !== '0' || g.epoch !== '1') fail('genesis malformed');
  if (g.issuer_device_id !== g.subject_device_id || g.subject_device_id !== dir.root_device_id) fail('genesis is not self-issued by the root');
  if (!subjectWellFormed(g) || !kindPolicy(g.subject_kind).canApprove) fail('root is not an approver-capable device');
  if (g.subject_device_id !== await deviceIdFor(g.subject_sign_pub)) fail('root id does not match its key');
  if (pins && (g.subject_sign_pub !== pins.root_sign_pub || g.subject_device_id !== pins.root_device_id)) fail('root differs from the pinned root');
  if (!(await verifySignature(g.subject_sign_alg, g.subject_sign_pub, utf8.encode(genesisText), genesisSig))) fail('genesis signature');

  const rootRow = dir.devices.find((d) => d.device_id === g.subject_device_id);
  if (!rootRow || !subjectMatchesRow(g, rootRow)) fail('root device row does not match genesis');
  const root = verified(g, rootRow, genesisText, genesisSig, 0);

  const trusted = new Map<string, VerifiedDevice>([[root.device_id, root]]);
  const everApproved = new Map<string, VerifiedDevice>([[root.device_id, root]]);
  const commits = new Map<number, string>();
  const epochs = new Map<number, EpochProof>();

  // Epoch 1: issued by the root at version 0 with the genesis commit.
  const e1 = dir.epochs.find((e) => e.epoch === 1);
  const e1st = parseStatement(e1?.statement);
  const e1sig = signatureObjectText(e1?.signature);
  if (!e1 || !e1st || e1st.type !== 'epoch' || e1st.epoch !== '1' || e1st.directory_version !== '0'
    || e1st.issuer_device_id !== root.device_id || e1st.user_id !== userId || !COMMIT_RE.test(e1st.epoch_commit)
    || e1st.epoch_commit !== g.epoch_commit) fail('epoch 1 statement');
  if (!(await verifySignature(root.sign_alg, root.sign_public_key, utf8.encode(e1.statement), e1sig))) fail('epoch 1 signature');
  commits.set(1, e1st.epoch_commit);
  epochs.set(1, { epoch: 1, statement: e1.statement, signature: e1sig, issuer_device_id: root.device_id, epoch_commit: e1st.epoch_commit });

  const ops: Op[] = [];
  const pending: DirectoryDevice[] = [];
  const revokedRows: DirectoryDevice[] = [];
  const seenIds = new Set<string>();
  for (const d of dir.devices) {
    if (seenIds.has(d.device_id)) fail(`duplicate device row ${d.device_id}`);
    seenIds.add(d.device_id);
    if (d.status === 'pending') { pending.push(d); continue; }
    if (d.device_id === root.device_id) {
      if (d.status === 'revoked') {
        const rs = parseStatement(d.revocation_statement);
        ops.push({ op: 'revoke', st: rs, text: d.revocation_statement ?? '', sig: signatureObjectText(d.revocation_signature), row: d, v: Number(rs?.directory_version ?? -1) });
      }
      continue;
    }
    const st = parseStatement(d.approval_statement);
    ops.push({ op: 'approve', st, text: d.approval_statement ?? '', sig: signatureObjectText(d.approval_signature), row: d, v: Number(st?.directory_version ?? -1) });
    if (d.status === 'revoked') {
      const rs = parseStatement(d.revocation_statement);
      ops.push({ op: 'revoke', st: rs, text: d.revocation_statement ?? '', sig: signatureObjectText(d.revocation_signature), row: d, v: Number(rs?.directory_version ?? -1) });
    }
  }
  for (const e of dir.epochs) {
    if (e.epoch === 1) continue;
    const st = parseStatement(e.statement);
    ops.push({ op: 'epoch', st, text: e.statement, sig: signatureObjectText(e.signature), v: Number(st?.directory_version ?? -1) });
  }
  ops.sort((a, b) => a.v - b.v || RANK[a.op] - RANK[b.op]);

  const untrusted: DirectoryDevice[] = [];
  let epoch = 1;
  let lastRevoke: { v: number; issuer: string; commit: string } | null = null;
  const usedVersions = new Set<number>();
  for (const o of ops) {
    const st = o.st;
    const issuer = st ? trusted.get(st.issuer_device_id) : undefined;
    const sigOk = Boolean(st && issuer && kindPolicy(issuer.kind).canApprove && st.user_id === userId && isNat(st.directory_version)
      && await verifySignature(issuer.sign_alg, issuer.sign_public_key, utf8.encode(o.text), o.sig));
    if (o.op === 'approve') {
      const ok = sigOk && st!.type === 'approve' && subjectWellFormed(st!) && subjectMatchesRow(st!, o.row)
        && st!.epoch === String(epoch) && st!.epoch_commit === commits.get(epoch)
        && o.v >= 1 && o.v < dir.version && !usedVersions.has(o.v)
        && o.row.device_id === await deviceIdFor(o.row.sign_public_key);
      if (!ok) {
        if (o.row.status === 'approved') untrusted.push(o.row);
        continue;
      }
      usedVersions.add(o.v);
      const vd = verified(st!, o.row, o.text, o.sig, o.v);
      trusted.set(vd.device_id, vd);
      everApproved.set(vd.device_id, vd);
    } else if (o.op === 'revoke') {
      if (!sigOk || st!.type !== 'revoke' || !subjectMatchesRow(st!, o.row) || !trusted.has(o.row.device_id)
        || st!.issuer_device_id === o.row.device_id || st!.epoch !== String(epoch + 1) || !COMMIT_RE.test(st!.epoch_commit)
        || o.v < 1 || o.v >= dir.version || usedVersions.has(o.v) || lastRevoke) {
        fail(`revocation of ${o.row.device_id}`);
      }
      usedVersions.add(o.v);
      trusted.delete(o.row.device_id);
      revokedRows.push(o.row);
      lastRevoke = { v: o.v, issuer: st!.issuer_device_id, commit: st!.epoch_commit };
    } else {
      if (!sigOk || st!.type !== 'epoch' || st!.epoch !== String(epoch + 1) || !COMMIT_RE.test(st!.epoch_commit)
        || !lastRevoke || lastRevoke.v !== o.v || lastRevoke.issuer !== st!.issuer_device_id || lastRevoke.commit !== st!.epoch_commit) {
        fail(`epoch statement ${st?.epoch ?? '?'}`);
      }
      epoch += 1;
      commits.set(epoch, st!.epoch_commit);
      epochs.set(epoch, { epoch, statement: o.text, signature: o.sig, issuer_device_id: st!.issuer_device_id, epoch_commit: st!.epoch_commit });
      lastRevoke = null;
    }
  }
  if (lastRevoke) fail('revocation without a new epoch');
  if (epoch !== dir.current_epoch) fail('current_epoch does not match the signed epochs');
  if (epochs.size !== dir.epochs.length) fail('unsigned or duplicate epoch rows');
  // Approved rows the chain could not reach (e.g. issuer never trusted) are untrusted.
  for (const d of dir.devices) {
    if (d.status === 'approved' && !trusted.has(d.device_id) && !untrusted.includes(d)) untrusted.push(d);
  }
  // The chain trusts a device the hub calls revoked/pending without a signed revocation: a hub lie.
  for (const [id, d] of trusted) if (d.row.status !== 'approved') fail(`device ${id} is trusted by the chain but not approved on the hub`);

  const chain: VerifiedChain = {
    userId,
    rootDeviceId: root.device_id,
    rootSignPub: root.sign_public_key,
    rootSignAlg: root.sign_alg,
    version: dir.version,
    currentEpoch: epoch,
    genesis: { statement: genesisText, signature: genesisSig },
    trusted,
    everApproved,
    untrusted,
    pending,
    revoked: revokedRows,
    commits,
    epochs,
  };
  checkAgainstPins(pins, pinsFromChain(chain));
  return chain;
}

export function pinsFromChain(chain: VerifiedChain): DevicePins {
  return {
    root_device_id: chain.rootDeviceId,
    root_sign_pub: chain.rootSignPub,
    max_directory_version: chain.version,
    max_epoch: chain.currentEpoch,
  };
}

/** Devices that receive a hub-stored keyring wrap (browsers, recovery). Never bridges. */
export function wrapRecipients(chain: VerifiedChain): VerifiedDevice[] {
  return [...chain.trusted.values()].filter((d) => kindPolicy(d.kind).receivesWrap);
}

/** Approver-capable devices that remain after removing `excludeId`. */
export function remainingApprovers(chain: VerifiedChain, excludeId: string): VerifiedDevice[] {
  return [...chain.trusted.values()].filter((d) => d.device_id !== excludeId && kindPolicy(d.kind).countsAsApprover);
}

// ── chain proof for bridges ──────────────────────────────────────────────────

/** One link of an issuer's approval chain, root-first. */
export interface ChainProofLink {
  device_id: string;
  kind: string;
  sign_alg: string;
  sign_public_key: string;
  approval_statement: string;
  approval_signature: string;
}

/**
 * What a bridge needs to authenticate a keyring it is unsealed with
 * (plan §1 "Bridge keyring authentication"). Public, signed data only.
 * The bridge pins `root_sign_pub` at its FIRST unseal (the enrollment approval) and
 * afterwards requires every proof to chain to that pin.
 */
export interface BridgeChainProof {
  v: 1;
  user_id: string;
  root_device_id: string;
  root_sign_alg: string;
  root_sign_pub: string;
  genesis: { statement: string; signature: string };
  /** Signed epoch statement for `current_epoch` (carries epoch_commit). */
  epoch: { epoch: number; statement: string; signature: string };
  /** Approval chain of the epoch statement's issuer, root excluded, root-first order. */
  issuer_chain: ChainProofLink[];
  /** The approval of the receiving bridge's own identity key, with its issuer's chain (root-first, root excluded). */
  subject_approval: { statement: string; signature: string; issuer_chain: ChainProofLink[] };
}

export function issuerChain(chain: VerifiedChain, deviceId: string): ChainProofLink[] {
  const links: ChainProofLink[] = [];
  const seen = new Set<string>();
  let cur = chain.everApproved.get(deviceId);
  while (cur && cur.device_id !== chain.rootDeviceId) {
    if (seen.has(cur.device_id)) fail('approval cycle');
    seen.add(cur.device_id);
    links.push({
      device_id: cur.device_id,
      kind: cur.kind,
      sign_alg: cur.sign_alg,
      sign_public_key: cur.sign_public_key,
      approval_statement: cur.approval_statement,
      approval_signature: cur.approval_signature,
    });
    cur = chain.everApproved.get(cur.approved_by_device_id);
  }
  if (!cur) fail(`issuer ${deviceId} has no approval chain to the root`);
  return links.reverse();
}

/** Build the proof for unsealing `bridgeDeviceId` at the chain's current epoch. */
export function buildBridgeChainProof(chain: VerifiedChain, bridgeDeviceId: string): BridgeChainProof {
  const bridge = chain.trusted.get(bridgeDeviceId);
  if (!bridge || bridge.kind !== 'bridge') fail('the bridge identity is not chain-approved');
  const ep = chain.epochs.get(chain.currentEpoch);
  if (!ep) fail('no signed statement for the current epoch');
  const issuer = chain.everApproved.get(ep.issuer_device_id);
  if (!issuer || !kindPolicy(issuer.kind).canApprove) fail('epoch issuer is not an approver');
  return {
    v: 1,
    user_id: chain.userId,
    root_device_id: chain.rootDeviceId,
    root_sign_alg: chain.rootSignAlg,
    root_sign_pub: chain.rootSignPub,
    genesis: { ...chain.genesis },
    epoch: { epoch: ep.epoch, statement: ep.statement, signature: ep.signature },
    issuer_chain: issuerChain(chain, ep.issuer_device_id),
    subject_approval: {
      statement: bridge.approval_statement,
      signature: bridge.approval_signature,
      issuer_chain: issuerChain(chain, bridge.approved_by_device_id),
    },
  };
}

// ── reference verifier for the bridge side ──────────────────────────────────
//
// The Odin bridge implements the same checks (src/bridge); this TS twin documents
// them precisely and drives the simulated bridge in the e2e and the unit tests.

export interface BridgeProofContext {
  /** The bridge's enrolled owner. */
  ownerUserId: string;
  /** The bridge's own persistent identity public key. */
  bridgeIdentityPub: string;
  /** The root pinned at enrollment; null only for the FIRST (enrollment) unseal. */
  pinnedRootSignPub: string | null;
}

async function verifyLinks(links: ChainProofLink[], root: { id: string; alg: string; pub: string }, userId: string): Promise<{ id: string; alg: string; pub: string }> {
  let prev = root;
  for (const link of links) {
    const st = parseStatement(link.approval_statement);
    if (!st || st.type !== 'approve' || st.user_id !== userId || st.issuer_device_id !== prev.id) fail('issuer chain link');
    if (st.subject_device_id !== link.device_id || st.subject_sign_pub !== link.sign_public_key || st.subject_kind !== link.kind || st.subject_sign_alg !== link.sign_alg) fail('issuer chain link subject');
    if (!kindPolicy(link.kind).canApprove) fail('issuer chain contains a non-approver');
    if (link.device_id !== await deviceIdFor(link.sign_public_key)) fail('issuer chain link id');
    if (!(await verifySignature(prev.alg, prev.pub, utf8.encode(link.approval_statement), link.approval_signature))) fail('issuer chain signature');
    prev = { id: link.device_id, alg: link.sign_alg, pub: link.sign_public_key };
  }
  return prev;
}

/**
 * Bridge-side verification of an unseal v2 chain proof against the opened keyring's
 * current epoch commit (`currentEpochCommitHex` = HMAC(epoch key, ...) computed by the
 * bridge from the decrypted keyring). Returns the root to pin. Throws on any failure.
 */
export async function verifyBridgeChainProof(proof: BridgeChainProof, currentEpoch: number, currentEpochCommitHex: string, ctx: BridgeProofContext): Promise<string> {
  if (!proof || proof.v !== 1 || proof.user_id !== ctx.ownerUserId) fail('chain proof version/user');
  if (ctx.pinnedRootSignPub !== null && proof.root_sign_pub !== ctx.pinnedRootSignPub) fail('chain proof root differs from the pinned root');
  if (!signAlgFromId(proof.root_sign_alg) || proof.root_device_id !== await deviceIdFor(proof.root_sign_pub)) fail('chain proof root');
  const g = parseStatement(proof.genesis?.statement);
  if (!g || g.type !== 'genesis' || g.user_id !== proof.user_id || g.issuer_device_id !== proof.root_device_id || g.subject_device_id !== proof.root_device_id
    || g.subject_sign_pub !== proof.root_sign_pub || g.subject_sign_alg !== proof.root_sign_alg) fail('chain proof genesis');
  if (!(await verifySignature(proof.root_sign_alg, proof.root_sign_pub, utf8.encode(proof.genesis.statement), proof.genesis.signature))) fail('chain proof genesis signature');
  const root = { id: proof.root_device_id, alg: proof.root_sign_alg, pub: proof.root_sign_pub };

  const issuer = await verifyLinks(proof.issuer_chain ?? [], root, proof.user_id);
  const e = parseStatement(proof.epoch?.statement);
  if (!e || e.type !== 'epoch' || e.user_id !== proof.user_id || e.epoch !== String(currentEpoch) || proof.epoch.epoch !== currentEpoch || e.issuer_device_id !== issuer.id) fail('chain proof epoch statement');
  if (!(await verifySignature(issuer.alg, issuer.pub, utf8.encode(proof.epoch.statement), proof.epoch.signature))) fail('chain proof epoch signature');
  if (!COMMIT_RE.test(currentEpochCommitHex) || e.epoch_commit.length !== currentEpochCommitHex.length) fail('chain proof epoch_commit');
  let diff = 0;
  for (let i = 0; i < e.epoch_commit.length; i++) diff |= e.epoch_commit.charCodeAt(i) ^ currentEpochCommitHex.charCodeAt(i);
  if (diff !== 0) fail('epoch_commit does not match the keyring');

  const sa = proof.subject_approval;
  const approver = await verifyLinks(sa?.issuer_chain ?? [], root, proof.user_id);
  const s = parseStatement(sa?.statement);
  if (!s || s.type !== 'approve' || s.user_id !== proof.user_id || s.issuer_device_id !== approver.id || s.subject_kind !== 'bridge'
    || s.subject_sign_pub !== ctx.bridgeIdentityPub || s.subject_device_id !== await deviceIdFor(ctx.bridgeIdentityPub)) fail('chain proof bridge approval');
  if (!(await verifySignature(approver.alg, approver.pub, utf8.encode(sa.statement), sa.signature))) fail('chain proof bridge approval signature');
  return proof.root_sign_pub;
}

/** Find the chain-trusted bridge identity bound to hub `bridge_id`. */
export function trustedBridgeById(chain: VerifiedChain, bridgeId: string): VerifiedDevice | null {
  for (const d of chain.trusted.values()) if (d.kind === 'bridge' && d.row.bridge_id === bridgeId) return d;
  return null;
}
