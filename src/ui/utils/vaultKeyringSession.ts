// The device's keyring session (docs/plans/passwordless-vault.md §2 P3
// "vaultKeyringSession.ts").
//
// The hub stores one wrap of the account keyring per approved device. This module
// opens this device's wrap with its non-extractable ECDH key, checks it against the
// verified chain (signer, AAD, epoch_commit), and installs NON-EXTRACTABLE keys:
// one AES-GCM key per epoch, the PTY v2 HKDF base keys, and the current epoch's
// search key. Raw keyring bytes exist only inside `withKeyringBytes` (to re-wrap for
// another device or unseal a bridge) and are zeroed before it returns; between uses
// the session keeps only the wrap CIPHERTEXT, which needs this device's key to open.

import { importKeyring, serializeKeyringBytes, parseKeyringBytes, KEYRING_KEY_BYTES, KEYRING_MAX_EPOCHS, type ParsedKeyringBytes, type VaultKeyring } from './vaultKeyring.ts';
import { setActiveVaultKey } from './vaultCrypto.ts';
import { deriveTaskChainSearchKey, setActiveTaskChainSearchKey } from './taskChainSearchKey.ts';
import { openVerifiedWrap, type SignedKeyringWrap } from './vaultKeyringWrap.ts';
import type { VerifiedChain } from './vaultDirectoryVerify.ts';
import type { DeviceIdentity } from './deviceIdentity.ts';

interface SessionState {
  identity: DeviceIdentity;
  wrap: SignedKeyringWrap;
  chain: VerifiedChain;
  keyring: VaultKeyring;
}

let session: SessionState | null = null;
let generation = 0;
const sessionListeners = new Set<() => void>();
export function subscribeKeyringSession(listener: () => void): () => void {
  sessionListeners.add(listener);
  return () => { sessionListeners.delete(listener); };
}

/** Open `wrap` for `identity` against `chain`. Returned entry keys must be zeroed by the caller. */
export async function openDeviceWrap(identity: DeviceIdentity, wrap: unknown, chain: VerifiedChain): Promise<ParsedKeyringBytes> {
  return openVerifiedWrap(wrap, {
    userId: chain.userId,
    recipientDeviceId: identity.deviceId,
    recipientEcdhPrivate: identity.ecdhPrivateKey,
    chain,
  });
}

/**
 * Verify, unwrap and install this device's keyring. On any failure nothing is
 * installed (and a previously installed session is left as it was).
 */
export async function installKeyringFromWrap(identity: DeviceIdentity, wrap: unknown, chain: VerifiedChain): Promise<VaultKeyring> {
  if (identity.userId !== chain.userId) throw new Error('device identity belongs to another user');
  const parsed = await openDeviceWrap(identity, wrap, chain);
  let bytes: Uint8Array | null = null;
  let searchRaw: Uint8Array | null = null;
  try {
    bytes = serializeKeyringBytes(parsed);
    const cur = parsed.entries.find((e) => e.epoch === parsed.currentEpoch)!;
    searchRaw = Uint8Array.from(cur.key);
    const keyring = await importKeyring(bytes, chain.userId); // zeroes `bytes`
    const searchKey = await deriveTaskChainSearchKey(searchRaw, parsed.currentEpoch); // zeroes its copy
    generation += 1;
    session = { identity, wrap: wrap as SignedKeyringWrap, chain, keyring };
    for (const listener of sessionListeners) listener();
    setActiveVaultKey(keyring); // clears the previous search key
    setActiveTaskChainSearchKey(searchKey);
    return keyring;
  } finally {
    bytes?.fill(0);
    searchRaw?.fill(0);
    for (const e of parsed.entries) e.key.fill(0);
  }
}

/** Purge every installed key (revoked device, sign-out, reset). */
export function clearKeyringSession(): void {
  generation += 1;
  session = null;
  for (const listener of sessionListeners) listener();
  setActiveVaultKey(null);
}

export function getKeyringSession(): Readonly<SessionState> | null {
  return session;
}

/**
 * Run `fn` with the raw HKR2 bytes of the installed keyring, re-opened from the
 * stored wrap. The buffer is zeroed when `fn` settles; `fn` must not keep it.
 * `chain` (when given) is the freshly verified chain to check the wrap against.
 */
export async function withKeyringBytes<T>(fn: (bytes: Uint8Array) => Promise<T>, chain?: VerifiedChain): Promise<T> {
  const s = session;
  if (!s) throw new Error('Vault keyring unavailable');
  const parsed = await openDeviceWrap(s.identity, s.wrap, chain ?? s.chain);
  let bytes: Uint8Array | null = null;
  try {
    bytes = serializeKeyringBytes(parsed);
    return await fn(bytes);
  } finally {
    bytes?.fill(0);
    for (const e of parsed.entries) e.key.fill(0);
  }
}

/**
 * HKR2 bytes for the next epoch: every existing entry plus a fresh random key at
 * `current+1`. Refuses when the keyring is full (64 epochs). Caller zeroes the result;
 * `current` is not modified.
 */
export function nextEpochKeyringBytes(current: Uint8Array, userId: string): Uint8Array {
  const parsed = parseKeyringBytes(current, userId);
  try {
    if (parsed.entries.length >= KEYRING_MAX_EPOCHS) throw new Error('Keyring is full (64 epochs); a vault reset is required');
    const fresh = crypto.getRandomValues(new Uint8Array(KEYRING_KEY_BYTES));
    const next = parsed.currentEpoch + 1;
    try {
      return serializeKeyringBytes({ userId, vaultId: parsed.vaultId, currentEpoch: next, entries: [...parsed.entries, { epoch: next, key: fresh }] });
    } finally {
      fresh.fill(0);
    }
  } finally {
    for (const e of parsed.entries) e.key.fill(0);
  }
}

/** A brand-new epoch-1 keyring of vault `vaultId` for genesis. Caller zeroes the result. */
export function genesisKeyringBytes(userId: string, vaultId: string): Uint8Array {
  const key = crypto.getRandomValues(new Uint8Array(KEYRING_KEY_BYTES));
  try {
    return serializeKeyringBytes({ userId, vaultId, currentEpoch: 1, entries: [{ epoch: 1, key }] });
  } finally {
    key.fill(0);
  }
}
