// Client-side verification of the account's vault device directory
// (docs/plans/passwordless-vault.md §1 "Directory log", §2 P3, threat model §3).
//
// The hub is hostile for the directory's integrity: everything it serves is checked
// here before any key is wrapped to, trusted from, or unsealed for a device.
//
// The directory IS its signed log: one op per version, seq 1..version, each naming
// the previous op's hash (prev_hash = SHA-256 of its canonical statement). The walk
// starts at the self-signed genesis (seq 1, epoch 1) and replays every op in order:
//   approve  – issuer trusted AT THAT POINT (approved earlier, not yet revoked) and
//              approver-capable; subject new; names the current epoch and its commit.
//   revoke   – issuer trusted; subject currently trusted (fields equal); introduces
//              epoch current+1 with its commit. Revocation and rotation are one op.
//   rotate   – issuer trusted; no subject; introduces epoch current+1.
// Any gap, reordering, broken hash link, unknown type or bad signature refuses the
// WHOLE directory: there is no partial trust. Device rows are only display metadata
// (labels, bridge ids, last seen) and the pending list; a row that contradicts the
// log (a trusted device the hub calls revoked or omits) refuses the directory, an
// approved row the log does not vouch for is reported `untrusted` and never wrapped to.
//
// Pins: this device remembers the root and the verified head (seq + hash). A
// directory whose log does not EXTEND that head (shorter, or a different op at the
// pinned seq) is refused as a rollback / fork.

import { deviceIdFor, labelFromB64, checkAgainstPins, PinViolationError, type DevicePins } from './deviceIdentity.ts';
import { vaultIdFor } from './vaultKeyring.ts';
import {
  STATEMENT_FIELDS,
  STATEMENT_HEADER,
  deviceKindFromId,
  kindPolicy,
  logEntryHash,
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
  revoked_by_device_id?: string;
  created_at?: string;
  approved_at?: string;
  revoked_at?: string;
  last_seen_at?: string;
  /** Hub retirement hint (never trusted on its own). */
  retired_at?: string;
}

/** One signed directory log op. */
export interface DirectoryLogEntry {
  seq: number;
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
  head_hash: string;
  log: DirectoryLogEntry[];
  devices: DirectoryDevice[];
  reset?: DirectoryReset | null;
  /** Hub hints: identities it retired without a signed revocation. Untrusted input. */
  retired_hints?: string[];
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

/** A chain-verified device. Every field comes from the SIGNED log, not the row. */
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
  /** Log seq of the approval (1 for the root's genesis). */
  approval_seq: number;
  row: DirectoryDevice;
}

/** The log op that introduced an epoch (genesis, revoke or rotate). */
export interface EpochProof {
  epoch: number;
  seq: number;
  type: 'genesis' | 'revoke' | 'rotate';
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
  /** The vault id (SHA-256(root_sign_pub)[:8], 16 hex): every keyring of this account names it. */
  vaultId: string;
  version: number;
  /** Entry hash of the op at seq = version. */
  headHash: string;
  /** Entry hash of every op, index seq-1. */
  logHashes: string[];
  currentEpoch: number;
  genesis: { statement: string; signature: string };
  /** Approved now, chain-verified. */
  trusted: Map<string, VerifiedDevice>;
  /** Every device whose approval ever verified (revoked ones included); for issuer chains. */
  everApproved: Map<string, VerifiedDevice>;
  /** Ids the log revoked (signed). */
  revokedIds: Set<string>;
  /** Rows the hub calls approved/revoked that the log does not vouch for. Never wrapped to. */
  untrusted: DirectoryDevice[];
  pending: DirectoryDevice[];
  /** Rows of devices the signed log revoked. */
  revoked: DirectoryDevice[];
  /** epoch -> epoch_commit (hex), from the signed epoch-introducing ops. */
  commits: Map<number, string>;
  epochs: Map<number, EpochProof>;
  /** Hub retirement hints that name a currently trusted BRIDGE (the only kind the hub retires). */
  retiredHints: string[];
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

function subjectMatchesRow(d: VerifiedDevice, row: DirectoryDevice): boolean {
  return row.device_id === d.device_id && row.kind === d.kind && row.sign_public_key === d.sign_public_key
    && (row.ecdh_public_key ?? '') === d.ecdh_public_key && row.sign_alg === d.sign_alg && (row.wrap_alg ?? '') === d.wrap_alg;
}

function subjectWellFormed(st: ParsedStatement): boolean {
  const kind = deviceKindFromId(st.subject_kind);
  if (!kind || !signAlgFromId(st.subject_sign_alg)) return false;
  if (kindPolicy(kind).receivesWrap) return Boolean(wrapAlgFromId(st.subject_wrap_alg)) && st.subject_ecdh_pub !== '';
  return st.subject_wrap_alg === '' && st.subject_ecdh_pub === '';
}

function subjectEmpty(st: ParsedStatement): boolean {
  return !st.subject_device_id && !st.subject_kind && !st.subject_sign_pub && !st.subject_ecdh_pub
    && !st.subject_sign_alg && !st.subject_wrap_alg && !st.subject_label_b64;
}

function sameSubject(st: ParsedStatement, d: Omit<VerifiedDevice, 'row'>): boolean {
  return st.subject_device_id === d.device_id && st.subject_kind === d.kind && st.subject_sign_pub === d.sign_public_key
    && st.subject_ecdh_pub === d.ecdh_public_key && st.subject_sign_alg === d.sign_alg && st.subject_wrap_alg === d.wrap_alg;
}

const COMMIT_RE = /^[0-9a-f]{64}$/;
const DECIMAL_RE = /^[1-9][0-9]{0,15}$/;

function verifiedFrom(st: ParsedStatement, text: string, sig: string, seq: number): Omit<VerifiedDevice, 'row'> {
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
    approval_seq: seq,
  };
}

const PLACEHOLDER_ROW = (id: string): DirectoryDevice => ({ device_id: id, kind: '', status: 'unknown', sign_alg: '', wrap_alg: '', sign_public_key: '', ecdh_public_key: '' });

/**
 * Verify the whole directory log for `userId`. `pins` (when present) must match the
 * root, and the log must extend the pinned head. Throws DirectoryVerificationError
 * (or PinViolationError) on refusal.
 */
export async function verifyDirectory(dir: VaultDirectory, userId: string, pins: DevicePins | null = null): Promise<VerifiedChain> {
  if (!dir || typeof dir !== 'object' || !Array.isArray(dir.devices) || !Array.isArray(dir.log)) fail('malformed directory');
  if (!Number.isSafeInteger(dir.version) || dir.version < 1) fail('malformed directory version');
  if (dir.log.length !== dir.version) fail(`the log has ${dir.log.length} ops for version ${dir.version}`);

  type Signed = Omit<VerifiedDevice, 'row'>;
  const trusted = new Map<string, Signed>();
  const everApproved = new Map<string, Signed>();
  const revokedIds = new Set<string>();
  const commits = new Map<number, string>();
  const epochs = new Map<number, EpochProof>();
  const logHashes: string[] = [];
  let root: Signed | null = null;
  let genesis = { statement: '', signature: '' };
  let epoch = 0;
  let prev = '';

  for (let i = 0; i < dir.log.length; i++) {
    const seq = i + 1;
    const entry = dir.log[i];
    if (!entry || entry.seq !== seq) fail(`log op ${seq} is missing or out of order`);
    const text = entry.statement;
    const sig = signatureObjectText(entry.signature);
    const st = parseStatement(text);
    if (!st) fail(`log op ${seq} is not canonical`);
    if (st.seq !== String(seq) || st.prev_hash !== prev) fail(`log op ${seq} is not linked to the previous op`);
    if (st.user_id !== userId) fail(`log op ${seq} is for another account`);
    if (!DECIMAL_RE.test(st.issued_at_ms)) fail(`log op ${seq} has no issue time`);

    if (seq === 1) {
      // Genesis: self-issued by the root, introduces epoch 1.
      if (st.type !== 'genesis' || st.epoch !== '1' || !COMMIT_RE.test(st.epoch_commit)) fail('genesis malformed');
      if (st.issuer_device_id !== st.subject_device_id || st.subject_device_id !== dir.root_device_id) fail('genesis is not self-issued by the root');
      if (!subjectWellFormed(st) || !kindPolicy(st.subject_kind).canApprove) fail('root is not an approver-capable device');
      if (st.subject_device_id !== await deviceIdFor(st.subject_sign_pub)) fail('root id does not match its key');
      if (pins && (st.subject_sign_pub !== pins.root_sign_pub || st.subject_device_id !== pins.root_device_id)) {
        throw new PinViolationError('the account root differs from the pinned root');
      }
      if (!(await verifySignature(st.subject_sign_alg, st.subject_sign_pub, utf8.encode(text), sig))) fail('genesis signature');
      root = verifiedFrom(st, text, sig, 1);
      trusted.set(root.device_id, root);
      everApproved.set(root.device_id, root);
      genesis = { statement: text, signature: sig };
      epoch = 1;
      commits.set(1, st.epoch_commit);
      epochs.set(1, { epoch: 1, seq: 1, type: 'genesis', statement: text, signature: sig, issuer_device_id: root.device_id, epoch_commit: st.epoch_commit });
    } else {
      const issuer = trusted.get(st.issuer_device_id);
      if (!issuer || !kindPolicy(issuer.kind).canApprove) fail(`log op ${seq} is signed by a device that was not a trusted approver at that point`);
      if (!(await verifySignature(issuer.sign_alg, issuer.sign_public_key, utf8.encode(text), sig))) fail(`log op ${seq} signature`);
      switch (st.type) {
        case 'approve': {
          if (!subjectWellFormed(st) || st.subject_device_id !== await deviceIdFor(st.subject_sign_pub)) fail(`log op ${seq}: malformed approval subject`);
          if (everApproved.has(st.subject_device_id)) fail(`log op ${seq} re-approves ${st.subject_device_id}`);
          if (st.epoch !== String(epoch) || st.epoch_commit !== commits.get(epoch)) fail(`log op ${seq}: approval does not name the current epoch`);
          if (labelFromB64(st.subject_label_b64) === '') fail(`log op ${seq}: invalid label`);
          const d = verifiedFrom(st, text, sig, seq);
          trusted.set(d.device_id, d);
          everApproved.set(d.device_id, d);
          break;
        }
        case 'revoke':
        case 'rotate': {
          if (st.type === 'revoke') {
            const target = trusted.get(st.subject_device_id);
            if (!target || !sameSubject(st, target)) fail(`log op ${seq} revokes a device that is not trusted`);
            if (target.device_id === issuer.device_id) fail(`log op ${seq} is a self-revocation`);
            trusted.delete(target.device_id);
            revokedIds.add(target.device_id);
          } else if (!subjectEmpty(st)) {
            fail(`log op ${seq}: a rotation names no subject`);
          }
          if (st.epoch !== String(epoch + 1) || !COMMIT_RE.test(st.epoch_commit) || st.wrap_sha256 !== '') fail(`log op ${seq}: must introduce epoch ${epoch + 1}`);
          epoch += 1;
          commits.set(epoch, st.epoch_commit);
          epochs.set(epoch, { epoch, seq, type: st.type, statement: text, signature: sig, issuer_device_id: issuer.device_id, epoch_commit: st.epoch_commit });
          break;
        }
        default:
          fail(`log op ${seq} has type ${st.type}`);
      }
    }
    prev = await logEntryHash(text);
    logHashes.push(prev);
  }
  if (!root) fail('empty log');
  if (dir.head_hash !== prev) fail('head_hash does not match the log');
  if (dir.current_epoch !== epoch) fail('current_epoch does not match the signed log');

  // Pins: the log must EXTEND the pinned head (same op at the pinned seq).
  if (pins) {
    if (dir.version < pins.head_seq) throw new PinViolationError('directory log rolled back');
    if (logHashes[pins.head_seq - 1] !== pins.head_hash) throw new PinViolationError('directory log forked from the pinned head');
  }

  // Rows: display metadata and pending devices, cross-checked against the log.
  const rows = new Map<string, DirectoryDevice>();
  for (const d of dir.devices) {
    if (!d || typeof d.device_id !== 'string') fail('malformed device row');
    if (rows.has(d.device_id)) fail(`duplicate device row ${d.device_id}`);
    rows.set(d.device_id, d);
  }
  const trustedOut = new Map<string, VerifiedDevice>();
  for (const [id, d] of trusted) {
    const row = rows.get(id);
    if (!row || row.status !== 'approved' || !subjectMatchesRow({ ...d, row: row } as VerifiedDevice, row)) {
      fail(`device ${id} is trusted by the log but not approved on the hub`);
    }
    trustedOut.set(id, { ...d, row });
  }
  const everOut = new Map<string, VerifiedDevice>();
  for (const [id, d] of everApproved) everOut.set(id, trustedOut.get(id) ?? { ...d, row: rows.get(id) ?? PLACEHOLDER_ROW(id) });
  const untrusted: DirectoryDevice[] = [];
  const pending: DirectoryDevice[] = [];
  const revoked: DirectoryDevice[] = [];
  for (const d of dir.devices) {
    if (d.status === 'pending') {
      if (everApproved.has(d.device_id)) fail(`device ${d.device_id} is in the log but listed as pending`);
      pending.push(d);
    } else if (revokedIds.has(d.device_id)) {
      revoked.push(d);
    } else if (!trusted.has(d.device_id)) {
      untrusted.push(d);
    }
  }
  const hints = Array.isArray(dir.retired_hints) ? dir.retired_hints : [];
  const retiredHints = [...new Set(hints.filter((id) => typeof id === 'string' && trustedOut.get(id)?.kind === 'bridge'))];

  const chain: VerifiedChain = {
    userId,
    rootDeviceId: root.device_id,
    rootSignPub: root.sign_public_key,
    rootSignAlg: root.sign_alg,
    vaultId: await vaultIdFor(root.sign_public_key),
    version: dir.version,
    headHash: prev,
    logHashes,
    currentEpoch: epoch,
    genesis,
    trusted: trustedOut,
    everApproved: everOut,
    revokedIds,
    untrusted,
    pending,
    revoked,
    commits,
    epochs,
    retiredHints,
  };
  checkAgainstPins(pins, pinsFromChain(chain));
  return chain;
}

export function pinsFromChain(chain: VerifiedChain): DevicePins {
  return {
    root_device_id: chain.rootDeviceId,
    root_sign_pub: chain.rootSignPub,
    head_seq: chain.version,
    head_hash: chain.headHash,
    max_epoch: chain.currentEpoch,
  };
}

/** The log slot the next signed op takes: seq = version + 1, prev_hash = head. */
export function nextLogSlot(chain: VerifiedChain): { seq: string; prev_hash: string } {
  return { seq: String(chain.version + 1), prev_hash: chain.headHash };
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

/** The signed log op that introduced `epoch`, with its issuer's approval chain. */
export interface ChainProofEpoch {
  epoch: number;
  statement: string;
  signature: string;
  issuer_chain: ChainProofLink[];
}

/**
 * What a bridge needs to authenticate a keyring it is unsealed with
 * (plan §1 "Bridge keyring authentication"). Public, signed data only.
 * The bridge pins `root_sign_pub` at its FIRST unseal (the enrollment approval) and
 * afterwards requires every proof to chain to that pin.
 */
export interface BridgeChainProof {
  v: 2;
  user_id: string;
  root_device_id: string;
  root_sign_alg: string;
  root_sign_pub: string;
  genesis: { statement: string; signature: string };
  /** One carrier per keyring epoch, ascending (prepareUnsealPayload trims to the keyring). */
  epochs: ChainProofEpoch[];
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

/** Build the proof for unsealing `bridgeDeviceId` with the chain's keyring. */
export function buildBridgeChainProof(chain: VerifiedChain, bridgeDeviceId: string): BridgeChainProof {
  const bridge = chain.trusted.get(bridgeDeviceId);
  if (!bridge || bridge.kind !== 'bridge') fail('the bridge identity is not chain-approved');
  if (chain.retiredHints.includes(bridgeDeviceId)) fail('the bridge identity was retired; it is not given keys');
  const carriers: ChainProofEpoch[] = [];
  for (let e = 1; e <= chain.currentEpoch; e++) {
    const ep = chain.epochs.get(e);
    if (!ep) fail(`no signed op for epoch ${e}`);
    const issuer = chain.everApproved.get(ep.issuer_device_id);
    if (!issuer || !kindPolicy(issuer.kind).canApprove) fail('epoch issuer is not an approver');
    carriers.push({ epoch: e, statement: ep.statement, signature: ep.signature, issuer_chain: issuerChain(chain, ep.issuer_device_id) });
  }
  return {
    v: 2,
    user_id: chain.userId,
    root_device_id: chain.rootDeviceId,
    root_sign_alg: chain.rootSignAlg,
    root_sign_pub: chain.rootSignPub,
    genesis: { ...chain.genesis },
    epochs: carriers,
    subject_approval: {
      statement: bridge.approval_statement,
      signature: bridge.approval_signature,
      issuer_chain: issuerChain(chain, bridge.approved_by_device_id),
    },
  };
}

// ── reference verifier for the bridge side ──────────────────────────────────
//
// The Odin bridge implements the same checks (src/lib/vault/bridge_chain.odin); this
// TS twin documents them and drives the simulated bridge in the e2e and unit tests.

export interface BridgeProofContext {
  /** The bridge's enrolled owner. */
  ownerUserId: string;
  /** The bridge's own persistent identity public key. */
  bridgeIdentityPub: string;
  /** The root pinned at enrollment; null only for the FIRST (enrollment) unseal. */
  pinnedRootSignPub: string | null;
  /** The opened keyring's vault id: must be the proof root's (a reset vault's keyring never passes). */
  keyringVaultId: string;
}

interface Signer { id: string; alg: string; pub: string; seq: number }

async function verifyLinks(links: ChainProofLink[], root: Signer, userId: string): Promise<Signer> {
  if (!Array.isArray(links) || links.length > 16) fail('issuer chain malformed');
  let prev = root;
  for (const link of links) {
    const st = parseStatement(link.approval_statement);
    if (!st || st.type !== 'approve' || st.user_id !== userId || st.issuer_device_id !== prev.id) fail('issuer chain link');
    const seq = Number(st.seq);
    if (!DECIMAL_RE.test(st.seq) || seq <= prev.seq) fail('issuer chain link order');
    if (st.subject_device_id !== link.device_id || st.subject_sign_pub !== link.sign_public_key || st.subject_kind !== link.kind || st.subject_sign_alg !== link.sign_alg) fail('issuer chain link subject');
    if (!kindPolicy(link.kind).canApprove) fail('issuer chain contains a non-approver');
    if (link.device_id !== await deviceIdFor(link.sign_public_key)) fail('issuer chain link id');
    if (!(await verifySignature(prev.alg, prev.pub, utf8.encode(link.approval_statement), link.approval_signature))) fail('issuer chain signature');
    prev = { id: link.device_id, alg: link.sign_alg, pub: link.sign_public_key, seq };
  }
  return prev;
}

function hexEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/**
 * Bridge-side verification of an unseal v2 chain proof against the opened keyring:
 * `keyringCommits` lists, in keyring order, every entry's epoch and the HMAC commit
 * the bridge computed from that epoch's key. Returns the root to pin. Throws on any
 * failure.
 */
export async function verifyBridgeChainProof(proof: BridgeChainProof, keyringCommits: Array<{ epoch: number; commit: string }>, ctx: BridgeProofContext): Promise<string> {
  if (!proof || proof.v !== 2 || proof.user_id !== ctx.ownerUserId) fail('chain proof version/user');
  if (ctx.pinnedRootSignPub !== null && proof.root_sign_pub !== ctx.pinnedRootSignPub) fail('chain proof root differs from the pinned root');
  if (!signAlgFromId(proof.root_sign_alg) || proof.root_device_id !== await deviceIdFor(proof.root_sign_pub)) fail('chain proof root');
  if (ctx.keyringVaultId !== await vaultIdFor(proof.root_sign_pub)) fail('the keyring belongs to another vault than the proof root');
  const g = parseStatement(proof.genesis?.statement);
  if (!g || g.type !== 'genesis' || g.seq !== '1' || g.prev_hash !== '' || g.user_id !== proof.user_id || g.issuer_device_id !== proof.root_device_id
    || g.subject_device_id !== proof.root_device_id || g.subject_sign_pub !== proof.root_sign_pub || g.subject_sign_alg !== proof.root_sign_alg) fail('chain proof genesis');
  if (!(await verifySignature(proof.root_sign_alg, proof.root_sign_pub, utf8.encode(proof.genesis.statement), proof.genesis.signature))) fail('chain proof genesis signature');
  const root: Signer = { id: proof.root_device_id, alg: proof.root_sign_alg, pub: proof.root_sign_pub, seq: 1 };

  if (!Array.isArray(proof.epochs) || proof.epochs.length !== keyringCommits.length || keyringCommits.length === 0) fail('chain proof epochs do not match the keyring');
  let lastSeq = 0;
  for (let i = 0; i < keyringCommits.length; i++) {
    const want = keyringCommits[i];
    const c = proof.epochs[i];
    if (!c || c.epoch !== want.epoch) fail('chain proof epoch order');
    const e = parseStatement(c.statement);
    if (!e || !['genesis', 'revoke', 'rotate'].includes(e.type) || e.user_id !== proof.user_id || e.epoch !== String(want.epoch)) fail('chain proof epoch statement');
    if ((e.type === 'genesis') !== (want.epoch === 1)) fail('chain proof epoch 1 must be the genesis');
    const issuer = await verifyLinks(c.issuer_chain ?? [], root, proof.user_id);
    if (e.issuer_device_id !== issuer.id) fail('chain proof epoch issuer');
    const seq = Number(e.seq);
    if (!DECIMAL_RE.test(e.seq)) fail('chain proof epoch seq');
    if (e.type === 'genesis' ? (seq !== 1 || e.prev_hash !== '' || issuer.id !== root.id) : seq <= issuer.seq) fail('chain proof epoch order');
    if (seq <= lastSeq) fail('chain proof epochs out of order');
    lastSeq = seq;
    if (!(await verifySignature(issuer.alg, issuer.pub, utf8.encode(c.statement), c.signature))) fail('chain proof epoch signature');
    if (!COMMIT_RE.test(want.commit) || !hexEqual(e.epoch_commit, want.commit)) fail('epoch_commit does not match the keyring');
  }

  const sa = proof.subject_approval;
  const approver = await verifyLinks(sa?.issuer_chain ?? [], root, proof.user_id);
  const s = parseStatement(sa?.statement);
  if (!s || s.type !== 'approve' || s.user_id !== proof.user_id || s.issuer_device_id !== approver.id || s.subject_kind !== 'bridge'
    || s.subject_sign_pub !== ctx.bridgeIdentityPub || s.subject_device_id !== await deviceIdFor(ctx.bridgeIdentityPub)) fail('chain proof bridge approval');
  if (!DECIMAL_RE.test(s.seq) || Number(s.seq) <= approver.seq) fail('chain proof bridge approval order');
  if (!(await verifySignature(approver.alg, approver.pub, utf8.encode(sa.statement), sa.signature))) fail('chain proof bridge approval signature');
  return proof.root_sign_pub;
}

/** Find the chain-trusted, non-retired bridge identity bound to hub `bridge_id`. */
export function trustedBridgeById(chain: VerifiedChain, bridgeId: string): VerifiedDevice | null {
  for (const d of chain.trusted.values()) {
    if (d.kind === 'bridge' && d.row.bridge_id === bridgeId && !chain.retiredHints.includes(d.device_id)) return d;
  }
  return null;
}
