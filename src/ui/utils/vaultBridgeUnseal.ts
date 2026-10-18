// REQ-VAULT-HARDEN-3, REQ-VAULT-HARDEN-8:
// Hub-blind E2EE bridge key wrapping and authenticated anti-replay unseal protocol.

// v2 only (docs/plans/passwordless-vault.md §1 "Bridge unseal v2"): the plaintext is the
// HKR1 keyring, HKDF info is `heimdall-bridge-unseal-v2`, and the AAD is
// `heimdall-bridge-unseal-v2|<bridge_id>|<timestamp>|<nonce>|<current_epoch>`. Before
// anything is encrypted, the bridge's ephemeral ECDH key must carry a valid signature by
// its identity key; otherwise nothing is sent.

import {
  bytesToHex,
  generateNonceHex,
  adapterKeyringBytesFromRawHex,
} from './vaultCrypto.ts';
import { parseKeyringBytes, isVaultKeyring, type VaultKeyring } from './vaultKeyring.ts';
import {
  SIGN_ALG_ECDSA_P256_SHA256,
  bridgeUnsealKeyCanonical,
  ecdhHkdfAesKey,
  isLowerHex,
  parseSignatureObject,
  signAlgFromId,
  signatureObjectText,
  verifySignature,
} from './vaultStatements.ts';

export const UNSEAL_V2_INFO = 'heimdall-bridge-unseal-v2';
export const UNSEAL_V2_FORMAT = 'keyring-v1';

export interface BridgeUnsealPayload {
  type: 'bridge_unseal';
  command_id?: string;
  bridge_id: string;
  timestamp: number;
  nonce: string;
  client_public_key: string;
  iv: string;
  tag: string;
  ciphertext: string;
  format: typeof UNSEAL_V2_FORMAT;
  current_epoch: number;
  /** Echo of the bridge's signature object over its ephemeral key. */
  unseal_key_signature: { alg: string; sig: string };
  bridge_identity_public_key: string;
  [extra: string]: unknown;
}

/**
 * What the hub reports about a bridge's unseal key. P1 trusts the identity key as
 * served by the hub; P3 pins it through the signed approval chain.
 */
export interface BridgeUnsealTarget {
  bridgeId: string;
  /** Ephemeral ECDH P-256 public key, 130 lowercase hex. */
  publicKey: string;
  bootId: string;
  /** Signature object (JSON text or parsed object) by the identity key. */
  unsealKeySignature: unknown;
  /** Persistent identity public key, 130 lowercase hex. */
  identityPublicKey: string;
  /** Identity key algorithm; defaults to the only allowlisted one. */
  identitySignAlg?: string;
}

export interface BridgeUnsealResult {
  type: string;
  command_id: string;
  ok: boolean;
  status?: string;
  error?: string;
}

export interface UnsealOptions {
  timestamp?: number;
  nonce?: string;
  commandId?: string;
  /** Test vectors only: fixed IV and client key pair. */
  iv?: Uint8Array;
  clientKeyPair?: CryptoKeyPair;
}

/** Discriminator for `VaultKeyNotExportableError`, stable across module instances. */
export const VAULT_KEY_NOT_EXPORTABLE = 'vault_key_not_exportable';

/**
 * A bridge unseal was asked to wrap a `CryptoKey` whose raw bytes cannot be read.
 *
 * This is the EXPECTED outcome for a hardened key (REQ-VAULT-HARDEN-1) and for any
 * key restored from IndexedDB, not a malfunction -- the unseal protocol has to
 * transmit the master key itself, so a handle that cannot yield its bytes is simply
 * not usable key material. The caller's job is to obtain the key from the operator
 * and pass it in; it must never degrade to a weaker payload (REQ-UNSEAL-4).
 *
 * `code` is checked rather than `instanceof` because callers reach this module
 * through a dynamic `import()` and must not depend on sharing one class identity.
 */
export class VaultKeyNotExportableError extends Error {
  readonly code = VAULT_KEY_NOT_EXPORTABLE;

  constructor() {
    super(
      'This browser holds the vault key as a non-extractable handle, which cannot be wrapped for a bridge. ' +
        'Re-enter your master password to unseal this bridge.',
    );
    this.name = 'VaultKeyNotExportableError';
  }
}

/** True when `err` is the not-exportable signal, across module instances. */
export function isVaultKeyNotExportableError(err: unknown): boolean {
  return Boolean(err) && (err as { code?: string }).code === VAULT_KEY_NOT_EXPORTABLE;
}

/**
 * What a completed unseal attempt actually did, as opposed to what the operator was
 * about to be told it did.
 *
 * REQ-UNSEAL-4/5: the UI must never report an unseal that did not happen. The case
 * that makes this worth a function rather than a chain of ternaries inline in the
 * panel is `targeted-bridge-missing`: the operator answers the password prompt raised
 * by ONE bridge row, and in the time they were typing that bridge left the list (the
 * poll refreshes it). Nothing is then attempted and nothing fails, so a "did anything
 * fail?" test sees a clean run and reports success for an unseal that was never built
 * or sent. That is a silent skip, which REQ-UNSEAL-4 forbids, so it is its own outcome
 * and the caller must say so explicitly.
 *
 * Lives here, not in the panel, for two reasons: it is unseal semantics rather than
 * presentation, and `node --test` cannot load `.tsx`, so a decision kept inline in the
 * component is a decision that cannot be tested at all.
 */
export type UnsealOutcome =
  /** The row the prompt was raised for is gone; nothing was attempted. */
  | { kind: 'targeted-bridge-missing' }
  /** At least one bridge took the payload. `count` is how many. */
  | { kind: 'unsealed'; count: number }
  /** Nothing succeeded and at least one bridge failed; the failures are reported. */
  | { kind: 'failed' }
  /** Nothing was targeted and nothing failed -- the vault is unlocked, nothing was sent. */
  | { kind: 'dispatched' };

export function resolveUnsealOutcome(args: {
  /** The bridge row that raised the prompt, or null when it came from the bulk control. */
  pendingUnsealBridgeId: string | null;
  /** Whether that bridge is still present in the list at submit time. */
  pendingBridgeFound: boolean;
  unsealedCount: number;
  failedCount: number;
}): UnsealOutcome {
  if (args.pendingUnsealBridgeId && !args.pendingBridgeFound) {
    return { kind: 'targeted-bridge-missing' };
  }
  if (args.unsealedCount > 0) return { kind: 'unsealed', count: args.unsealedCount };
  if (args.failedCount > 0) return { kind: 'failed' };
  return { kind: 'dispatched' };
}

/**
 * Whether `vaultKey` can actually produce the bytes an unseal payload needs.
 *
 * Callers use this to decide whether to prompt the operator BEFORE starting any
 * network work, so the rule lives here next to the code that enforces it rather
 * than being re-derived (and drifting) in each UI surface.
 */
export type UnsealKeyMaterial = string | CryptoKey | Uint8Array | VaultKeyring;

export function canUnsealWithKey(vaultKey: UnsealKeyMaterial | null | undefined): boolean {
  if (!vaultKey) return false;
  if (typeof vaultKey === 'string') return vaultKey.trim().length > 0;
  if (vaultKey instanceof Uint8Array) return vaultKey.length > 0;
  if (isVaultKeyring(vaultKey)) return false; // holds only non-extractable keys
  return vaultKey.extractable === true;
}

/** `heimdall-bridge-unseal-v2|<bridge_id>|<timestamp>|<nonce>|<current_epoch>` */
export function buildUnsealAad(bridgeId: string, timestamp: number, nonce: string, currentEpoch: number): Uint8Array {
  return new TextEncoder().encode(`${UNSEAL_V2_INFO}|${bridgeId}|${timestamp}|${nonce}|${currentEpoch}`);
}

/**
 * Verify that the bridge's ephemeral ECDH key is signed by its identity key. Throws
 * (and so prevents any unseal) on a missing, malformed, unknown-alg or invalid
 * signature.
 */
export async function verifyBridgeUnsealKey(target: BridgeUnsealTarget): Promise<void> {
  const publicKey = String(target.publicKey || '').trim().toLowerCase();
  const identity = String(target.identityPublicKey || '').trim().toLowerCase();
  const alg = signAlgFromId(target.identitySignAlg ?? SIGN_ALG_ECDSA_P256_SHA256);
  if (!alg) throw new Error('Bridge identity key uses an unsupported algorithm; unseal refused');
  if (!isLowerHex(publicKey, 65) || !publicKey.startsWith('04')) {
    throw new Error('Invalid bridge public key: expected 65-byte uncompressed P-256 point starting with 0x04');
  }
  if (!isLowerHex(identity, 65) || !identity.startsWith('04')) {
    throw new Error('Bridge identity key is missing or malformed; unseal refused');
  }
  const sigText = signatureObjectText(target.unsealKeySignature);
  if (!parseSignatureObject(sigText)) throw new Error('Bridge unseal key is unsigned or the signature is malformed; unseal refused');
  let canonical: string;
  try {
    canonical = bridgeUnsealKeyCanonical(target.bridgeId, publicKey, String(target.bootId || '').trim().toLowerCase());
  } catch (err) {
    throw new Error(`Bridge unseal key statement is malformed (${(err as Error).message}); unseal refused`);
  }
  const ok = await verifySignature(alg, identity, new TextEncoder().encode(canonical), sigText);
  if (!ok) throw new Error('Bridge unseal key signature does not verify under its identity key; unseal refused');
}

/**
 * P1-TEMPORARY ADAPTER (deleted in P3): turn whatever key material a caller holds into
 * HKR1 keyring bytes. Hex and extractable keys come from the password vault and
 * become `{session user, epoch 1}`; a Uint8Array is taken to already be HKR1. A
 * non-extractable key or keyring cannot be wrapped and raises
 * VaultKeyNotExportableError, never a weaker payload.
 */
export async function keyringBytesForUnseal(vaultKey: UnsealKeyMaterial): Promise<Uint8Array> {
  if (typeof vaultKey === 'string') return adapterKeyringBytesFromRawHex(vaultKey);
  if (vaultKey instanceof Uint8Array) return Uint8Array.from(vaultKey);
  if (isVaultKeyring(vaultKey) || !vaultKey.extractable) throw new VaultKeyNotExportableError();
  const raw = new Uint8Array(await crypto.subtle.exportKey('raw', vaultKey));
  try {
    return adapterKeyringBytesFromRawHex(bytesToHex(raw));
  } finally {
    raw.fill(0);
  }
}

/**
 * Wrap a keyring for one bridge (Hub-blind E2EE): verify its signed ephemeral key,
 * then ECDH (fresh client key) -> HKDF-SHA256 -> AES-256-GCM over the HKR1 bytes with
 * the v2 AAD. `keyringBytes` is zeroed before this returns.
 */
export async function prepareUnsealPayload(
  target: BridgeUnsealTarget,
  keyringBytes: Uint8Array,
  options?: UnsealOptions,
): Promise<BridgeUnsealPayload> {
  try {
    await verifyBridgeUnsealKey(target);
    const parsed = parseKeyringBytes(keyringBytes);
    for (const e of parsed.entries) e.key.fill(0);
    const currentEpoch = parsed.currentEpoch;

    const publicKey = target.publicKey.trim().toLowerCase();
    const clientKeyPair = options?.clientKeyPair ?? await crypto.subtle.generateKey(
      { name: 'ECDH', namedCurve: 'P-256' },
      false,
      ['deriveBits'],
    );
    const clientPublicKeyHex = bytesToHex(new Uint8Array(await crypto.subtle.exportKey('raw', clientKeyPair.publicKey)));
    const aesKey = await ecdhHkdfAesKey(clientKeyPair.privateKey, publicKey, UNSEAL_V2_INFO, ['encrypt']);

    const timestamp = options?.timestamp ?? Date.now();
    const nonce = options?.nonce ?? generateNonceHex(16);
    if (!isLowerHex(nonce) || nonce.length === 0) throw new Error('Invalid unseal nonce');
    const commandId = options?.commandId ?? `cmd_unseal_${Date.now()}`;
    const ivBytes = options?.iv ? Uint8Array.from(options.iv) : crypto.getRandomValues(new Uint8Array(12));
    if (ivBytes.length !== 12) throw new Error('Invalid unseal IV');

    const encryptedBytes = new Uint8Array(await crypto.subtle.encrypt(
      {
        name: 'AES-GCM',
        iv: ivBytes as unknown as BufferSource,
        additionalData: buildUnsealAad(target.bridgeId, timestamp, nonce, currentEpoch) as unknown as BufferSource,
        tagLength: 128,
      },
      aesKey,
      keyringBytes as unknown as BufferSource,
    ));
    const tagBytes = encryptedBytes.slice(encryptedBytes.length - 16);
    const ciphertextBytes = encryptedBytes.slice(0, encryptedBytes.length - 16);
    const sig = parseSignatureObject(signatureObjectText(target.unsealKeySignature))!;

    return {
      type: 'bridge_unseal',
      command_id: commandId,
      bridge_id: target.bridgeId,
      timestamp,
      nonce,
      client_public_key: clientPublicKeyHex,
      iv: bytesToHex(ivBytes),
      tag: bytesToHex(tagBytes),
      ciphertext: bytesToHex(ciphertextBytes),
      format: UNSEAL_V2_FORMAT,
      current_epoch: currentEpoch,
      unseal_key_signature: { alg: sig.alg, sig: sig.sig },
      bridge_identity_public_key: target.identityPublicKey.trim().toLowerCase(),
    };
  } finally {
    keyringBytes.fill(0);
  }
}

/** Build a target from a hub bridge / public-key record. */
export function bridgeUnsealTargetFromRecord(bridgeId: string, record: any): BridgeUnsealTarget {
  return {
    bridgeId,
    publicKey: String(record?.public_key || record?.bridge_public_key || ''),
    bootId: String(record?.unseal_boot_id || ''),
    unsealKeySignature: record?.unseal_key_signature ?? '',
    identityPublicKey: String(record?.bridge_identity_public_key || ''),
    identitySignAlg: record?.bridge_identity_sign_alg ? String(record.bridge_identity_sign_alg) : undefined,
  };
}

/**
 * Executes the full E2EE bridge unseal workflow from the Web UI (REQ-VAULT-HARDEN-3).
 */
export async function unsealBridgeE2EE(
  target: BridgeUnsealTarget,
  vaultKey: UnsealKeyMaterial,
  dispatchFn: (bridgeId: string, payload: BridgeUnsealPayload) => Promise<BridgeUnsealResult>,
  options?: UnsealOptions,
): Promise<BridgeUnsealResult> {
  const payload = await prepareUnsealPayload(target, await keyringBytesForUnseal(vaultKey), options);
  return await dispatchFn(target.bridgeId, payload);
}
