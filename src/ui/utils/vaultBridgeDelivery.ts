// Deliver the account keyring to a bridge (unseal v2) only through the verified chain
// (docs/plans/passwordless-vault.md §1 "Bridge keyring authentication", §2 P3).
//
// The identity key a bridge's ephemeral ECDH key must be signed by is the one the
// SIGNED directory approved for that bridge — the hub's copy is only cross-checked,
// never trusted on its own. The payload carries the chain proof the bridge verifies
// before installing anything. Keyring bytes are transient and zeroed here.

import { prepareUnsealPayload, type BridgeUnsealPayload, type BridgeUnsealResult, type BridgeUnsealTarget } from './vaultBridgeUnseal.ts';
import { buildBridgeChainProof, trustedBridgeById, type VerifiedChain } from './vaultDirectoryVerify.ts';

export interface BridgeDeliveryDeps {
  /** GET /bridges/{id}/public-key[?enrollment=1] as a target. */
  fetchTarget: (bridgeId: string, enrollment: boolean) => Promise<BridgeUnsealTarget>;
  /** POST /bridges/{id}/unseal. */
  dispatch: (bridgeId: string, payload: BridgeUnsealPayload) => Promise<BridgeUnsealResult>;
  /** Runs `fn` with transient HKR2 bytes at the chain's current epoch (zeroed afterwards). */
  withKeyringBytes: <T>(fn: (bytes: Uint8Array) => Promise<T>) => Promise<T>;
}

export interface BridgeDeliveryOptions {
  /** Deliver to the enrolling process of a pending enrollment. */
  enrollment?: boolean;
  /**
   * The identity key just approved for this bridge. Required to target the right identity
   * when a reused bridge id still has its old identity live (until the attach commits).
   */
  identityPublicKey?: string;
  /** The ephemeral key the operator saw; a different current key is refused. */
  expectedPublicKey?: string;
  /** Extra payload fields (e.g. `enrollment`, `expected_public_key`). */
  extra?: Record<string, unknown>;
}

export class BridgeDeliveryRefused extends Error {
  constructor(reason: string) {
    super(reason);
    this.name = 'BridgeDeliveryRefused';
  }
}

export async function deliverKeyringToBridge(
  bridgeId: string,
  chain: VerifiedChain,
  deps: BridgeDeliveryDeps,
  opts: BridgeDeliveryOptions = {},
): Promise<BridgeUnsealResult> {
  const identity = trustedBridgeById(chain, bridgeId, opts.identityPublicKey);
  if (!identity) throw new BridgeDeliveryRefused(`Bridge ${bridgeId} has no chain-approved identity; approve it on /device/add first`);
  const served = await deps.fetchTarget(bridgeId, Boolean(opts.enrollment));
  const servedIdentity = String(served.identityPublicKey || '').trim().toLowerCase();
  if (servedIdentity && servedIdentity !== identity.sign_public_key) {
    throw new BridgeDeliveryRefused(`Bridge ${bridgeId} presents an identity key that differs from the approved one; unseal refused`);
  }
  const expected = String(opts.expectedPublicKey || '').trim().toLowerCase();
  if (expected && String(served.publicKey || '').trim().toLowerCase() !== expected) {
    throw new BridgeDeliveryRefused(`Bridge ${bridgeId} now holds a different unseal key; reload and try again`);
  }
  const target: BridgeUnsealTarget = { ...served, identityPublicKey: identity.sign_public_key, identitySignAlg: identity.sign_alg };
  const proof = buildBridgeChainProof(chain, identity.device_id);
  const payload = await deps.withKeyringBytes((bytes) => prepareUnsealPayload(target, Uint8Array.from(bytes), proof));
  return deps.dispatch(bridgeId, { ...payload, ...(opts.extra ?? {}) } as BridgeUnsealPayload);
}

export interface BridgeFanoutResult {
  succeeded: string[];
  failed: Array<{ bridgeId: string; error: string }>;
}

/** Re-unseal every listed bridge; failures are reported, never hidden. */
export async function deliverKeyringToBridges(bridgeIds: readonly string[], chain: VerifiedChain, deps: BridgeDeliveryDeps): Promise<BridgeFanoutResult> {
  const result: BridgeFanoutResult = { succeeded: [], failed: [] };
  for (const id of bridgeIds) {
    try {
      await deliverKeyringToBridge(id, chain, deps);
      result.succeeded.push(id);
    } catch (err) {
      result.failed.push({ bridgeId: id, error: String((err as Error)?.message || err) });
    }
  }
  return result;
}
