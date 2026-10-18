// Test helper: present a raw 64-hex test key as the P1 single-epoch keyring {epoch 1}
// (the same shape the password-vault adapter produces), so suites that predate the
// keyring API can keep their fixed hex keys.
import { importKeyring, type VaultKeyring } from '../../src/ui/utils/vaultKeyring.ts';
import { adapterKeyringBytesFromRawHex } from '../../src/ui/utils/vaultCrypto.ts';

export const TEST_USER_ID = 'usr_test';

export async function keyringFromHex(hex: string, userId: string = TEST_USER_ID): Promise<VaultKeyring> {
  return importKeyring(adapterKeyringBytesFromRawHex(hex, userId));
}

/** Present a bare CryptoKey as the P1 epoch-1 keyring; keyrings and nullish pass through. */
export function asKeyring<T>(key: T): any {
  if (key && typeof key === 'object' && 'algorithm' in (key as object)) {
    return Object.freeze({ userId: TEST_USER_ID, currentEpoch: 1, keys: new Map([[1, key as unknown as CryptoKey]]) });
  }
  return key;
}

const hexOf = (b: ArrayBuffer | Uint8Array) => Buffer.from(b instanceof Uint8Array ? b : new Uint8Array(b)).toString('hex');

/**
 * A hub bridge / public-key record whose ephemeral ECDH key carries a valid identity
 * signature, as a v2 bridge advertises it. `ecdhPublicKeyHex` defaults to a fresh key.
 */
export async function signedUnsealRecord(bridgeId: string, ecdhPublicKeyHex?: string): Promise<Record<string, unknown>> {
  const identity = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  let ecdhPub = ecdhPublicKeyHex?.toLowerCase();
  if (!ecdhPub) {
    const pair = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
    ecdhPub = hexOf(await crypto.subtle.exportKey('raw', pair.publicKey));
  }
  const bootId = hexOf(crypto.getRandomValues(new Uint8Array(16)));
  const canonical = `heimdall-bridge-unseal-key/v1\n${bridgeId}\n${ecdhPub}\n${bootId}`;
  const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, identity.privateKey, new TextEncoder().encode(canonical)));
  return {
    bridge_id: bridgeId,
    public_key: ecdhPub,
    bridge_public_key: ecdhPub,
    unseal_boot_id: bootId,
    unseal_key_signature: { alg: 'ecdsa-p256-sha256', sig: hexOf(sig) },
    bridge_identity_public_key: hexOf(await crypto.subtle.exportKey('raw', identity.publicKey)),
    bridge_identity_sign_alg: 'ecdsa-p256-sha256',
  };
}
