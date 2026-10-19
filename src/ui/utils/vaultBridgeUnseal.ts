// REQ-VAULT-HARDEN-3, REQ-VAULT-HARDEN-8:
// Hub-blind E2EE bridge key wrapping and authenticated anti-replay unseal protocol.

// v2 only (docs/plans/passwordless-vault.md §1 "Bridge unseal v2"): the plaintext is the
// HKR2 keyring, HKDF info is `heimdall-bridge-unseal-v2`, and the AAD is
// `heimdall-bridge-unseal-v2|<bridge_id>|<timestamp>|<nonce>|<current_epoch>`. Before
// anything is encrypted, the bridge's ephemeral ECDH key must carry a valid signature by
// its identity key; otherwise nothing is sent.

import { bytesToHex, generateNonceHex } from './vaultCrypto.ts';
import { parseKeyringBytes } from './vaultKeyring.ts';
import type { BridgeChainProof } from './vaultDirectoryVerify.ts';
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
  /**
   * Signed proof that the keyring comes from the account (plan §1 "Bridge keyring
   * authentication"): root to pin (first unseal) / to match (later), the signed
   * epoch statement for current_epoch, and its issuer's approval chain.
   */
  chain_proof: BridgeChainProof;
  [extra: string]: unknown;
}

/**
 * A bridge's current unseal key. `identityPublicKey` must be the identity key the
 * signed directory chain approved for this bridge, never the hub's copy alone
 * (see vaultBridgeDelivery.ts).
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
 * Wrap a keyring for one bridge (Hub-blind E2EE): verify its signed ephemeral key,
 * then ECDH (fresh client key) -> HKDF-SHA256 -> AES-256-GCM over the HKR2 bytes with
 * the v2 AAD. `keyringBytes` is zeroed before this returns.
 */
export async function prepareUnsealPayload(
  target: BridgeUnsealTarget,
  keyringBytes: Uint8Array,
  chainProof: BridgeChainProof,
  options?: UnsealOptions,
): Promise<BridgeUnsealPayload> {
  try {
    await verifyBridgeUnsealKey(target);
    if (!chainProof || chainProof.v !== 2 || !Array.isArray(chainProof.epochs)) throw new Error('Missing keyring chain proof; unseal refused');
    const parsed = parseKeyringBytes(keyringBytes, chainProof.user_id);
    for (const e of parsed.entries) e.key.fill(0);
    const currentEpoch = parsed.currentEpoch;
    // The bridge requires exactly one signed carrier per keyring epoch, in order.
    const carriers = parsed.entries.map((e) => chainProof.epochs.find((c) => c.epoch === e.epoch));
    if (carriers.some((c) => !c)) throw new Error('Chain proof does not attest every epoch in the keyring; unseal refused');
    chainProof = { ...chainProof, epochs: carriers as BridgeChainProof['epochs'] };

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
      chain_proof: chainProof,
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
