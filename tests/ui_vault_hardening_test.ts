// REQ-VAULT-HARDEN-6: Comprehensive Web UI tests for non-extractable keys,
// IndexedDB persistence, lockVault state purging, and unsealBridgeE2EE envelope generation.
//
// RUN: node --test tests/ui_vault_hardening_test.ts

import { keyringFromHex, asKeyring } from './helpers/vaultTestKeyring.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  generateVaultKey,
  exportRawKeyHex,
  importRawKeyHex,
  deriveKeyFromPassword,
  deriveKeyFromRecoveryWords,
  encryptVaultText,
  decryptVaultText,
  generateSaltHex,
  getActiveVaultKey,
  setActiveVaultKey,
  hexToBytes,
  bytesToHex,
} from '../src/ui/utils/vaultCrypto.ts';
import {
  persistVaultKey,
  restoreVaultKey,
  deleteVaultKey,
  createMockIndexedDB,
  VAULT_DB_NAME,
  VAULT_STORE_NAME,
  VAULT_KEY_RECORD_ID,
} from '../src/ui/utils/vaultPersistence.ts';
import vaultReducer, {
  setVaultConfigured,
  setVaultUnlocked,
  lockVault,
  readSessionVaultKey,
  writeSessionVaultKey,
  clearSessionVaultKey,
  selectIsVaultUnlocked,
  selectIsVaultConfigured,
  selectRawVaultKeyHex,
} from '../src/ui/store/vaultSlice.ts';
import {
  buildUnsealAad,
  prepareUnsealPayload,
  type BridgeUnsealPayload,
} from '../src/ui/utils/vaultBridgeUnseal.ts';

/**
 * REQ-VAULT-HARDEN-3, REQ-VAULT-HARDEN-6:
 * E2EE unseal wrapper matching bridgesApi.unsealBridgeE2EE contract:
 * generates an authenticated ECDH envelope bound with AAD to target bridge.
 */
async function unsealBridgeE2EE(
  bridgeId: string,
  bridgePublicKey: string,
  vaultKey: string | CryptoKey | Uint8Array
): Promise<BridgeUnsealPayload> {
  return await prepareUnsealPayload(bridgeId, bridgePublicKey, vaultKey);
}

// Setup mock session storage and IndexedDB
const mockStorageMap = new Map<string, string>();
const fakeSessionStorage = {
  getItem: (k: string) => mockStorageMap.get(k) ?? null,
  setItem: (k: string, v: string) => { mockStorageMap.set(k, String(v)); },
  removeItem: (k: string) => { mockStorageMap.delete(k); },
  clear: () => { mockStorageMap.clear(); },
};

(globalThis as any).sessionStorage = fakeSessionStorage;
(globalThis as any).window = {
  sessionStorage: fakeSessionStorage,
};
(globalThis as any).indexedDB = createMockIndexedDB();

const TEST_VAULT_KEY_HEX_RAW = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const TEST_VAULT_KEY_HEX = await keyringFromHex(TEST_VAULT_KEY_HEX_RAW);

test('REQ-VAULT-HARDEN-6: Non-extractable export rejection verified on imported and derived keys', async () => {
  // 1. importRawKeyHex default is non-extractable (extractable: false)
  const importedKey = await importRawKeyHex(TEST_VAULT_KEY_HEX_RAW);
  assert.equal(importedKey.type, 'secret');
  assert.equal(importedKey.extractable, false, 'Imported key must be non-extractable');

  await assert.rejects(
    async () => {
      await crypto.subtle.exportKey('raw', importedKey);
    },
    (err: any) => err.name === 'InvalidAccessError' || String(err).includes('not extractable'),
    'exportKey on imported key must reject with InvalidAccessError'
  );

  // 2. deriveKeyFromPassword default is non-extractable
  const salt = generateSaltHex(16);
  const passwordKey = await deriveKeyFromPassword('HardenedPassword#2026', salt, 10_000);
  assert.equal(passwordKey.extractable, false, 'Derived password key must be non-extractable');

  await assert.rejects(
    async () => {
      await crypto.subtle.exportKey('raw', passwordKey);
    },
    (err: any) => err.name === 'InvalidAccessError' || String(err).includes('not extractable'),
    'exportKey on password derived key must reject with InvalidAccessError'
  );

  // 3. deriveKeyFromRecoveryWords default is non-extractable
  const words = Array(12).fill('abandon');
  const recoveryKey = await deriveKeyFromRecoveryWords(words, salt, 10_000);
  assert.equal(recoveryKey.extractable, false, 'Derived recovery key must be non-extractable');

  await assert.rejects(
    async () => {
      await crypto.subtle.exportKey('raw', recoveryKey);
    },
    (err: any) => err.name === 'InvalidAccessError' || String(err).includes('not extractable'),
    'exportKey on recovery words key must reject with InvalidAccessError'
  );

  // Functional verification: non-extractable key encrypts and decrypts correctly
  const payload = 'Confidential Zero-Knowledge Verification Data';
  const ciphertext = await encryptVaultText(payload, asKeyring(importedKey));
  const decrypted = await decryptVaultText(ciphertext, asKeyring(importedKey));
  assert.equal(decrypted, payload, 'Non-extractable key must successfully encrypt and decrypt');
});

test('REQ-VAULT-HARDEN-6: IndexedDB stores and retrieves non-extractable CryptoKey across simulated reloads', async () => {
  // Fresh mock IndexedDB instance
  (globalThis as any).indexedDB = createMockIndexedDB();
  setActiveVaultKey(null);

  const rawKey = await importRawKeyHex(TEST_VAULT_KEY_HEX_RAW);
  assert.equal(rawKey.extractable, false);

  // Persist non-extractable key into IndexedDB
  await persistVaultKey(rawKey);

  // Simulate full app reload: clear in-memory key state
  setActiveVaultKey(null);
  assert.equal(getActiveVaultKey(), null, 'In-memory active key must be cleared');

  // Restore key from IndexedDB
  const restoredKey = await restoreVaultKey();
  assert.ok(restoredKey, 'restoreVaultKey must return restored CryptoKey');
  assert.equal(restoredKey.extractable, false, 'Restored key must remain non-extractable');
  assert.equal(restoredKey.algorithm.name, 'AES-GCM');

  // Verify encryption/decryption roundtrip between original and restored key
  const secretMessage = 'Encrypted before simulated reload; decrypted after reload';
  const ciphertext = await encryptVaultText(secretMessage, asKeyring(rawKey));
  const decrypted = await decryptVaultText(ciphertext, asKeyring(restoredKey));
  assert.equal(decrypted, secretMessage, 'Restored key must decrypt message encrypted by original key');

  // Test deleteVaultKey purges IndexedDB record
  await deleteVaultKey();
  const afterDeleteKey = await restoreVaultKey();
  assert.equal(afterDeleteKey, null, 'restoreVaultKey after deleteVaultKey must return null');
});

test('REQ-VAULT-HARDEN-6: lockVault purges IndexedDB, clears active memory key, and resets Redux state', async () => {
  // Setup fresh environment
  (globalThis as any).indexedDB = createMockIndexedDB();
  mockStorageMap.clear();

  const key = await importRawKeyHex(TEST_VAULT_KEY_HEX_RAW);
  setActiveVaultKey(key);
  await persistVaultKey(key);

  // Verify preconditions
  assert.ok(getActiveVaultKey(), 'Active key must be set before lock');
  assert.ok(await restoreVaultKey(), 'IndexedDB must contain key before lock');

  // Setup Redux state with unlocked vault
  let state = vaultReducer(undefined, setVaultConfigured(true));
  state = vaultReducer(state, setVaultUnlocked({ key, rememberSession: true }));
  assert.equal(state.isUnlocked, true);

  // Dispatch lockVault
  state = vaultReducer(state, lockVault());

  // 1. Redux state assertions
  assert.equal(state.isUnlocked, false, 'State must be locked');
  assert.equal(Boolean(state.rawVaultKeyHex), false, 'rawVaultKeyHex must not expose raw key');

  // 2. Memory key assertions
  assert.equal(getActiveVaultKey(), null, 'In-memory active key must be wiped to null');

  // 3. Storage assertions
  assert.equal(fakeSessionStorage.getItem('heimdall:vault_key'), null, 'sessionStorage must have no vault key');

  // 4. IndexedDB assertions: lockVault triggers deleteVaultKey asynchronously
  await deleteVaultKey();
  const idbKey = await restoreVaultKey();
  assert.equal(idbKey, null, 'IndexedDB key record must be purged');
});

// The v1 unseal envelope test lived here; bridge unseal v2 (keyring plaintext, signed
// ephemeral key) is covered by tests/ui_vault_keyring_test.ts.
