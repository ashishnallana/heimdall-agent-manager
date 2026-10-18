// REQ-VAULT-HARDEN-1, REQ-VAULT-HARDEN-2:
// Comprehensive unit and contract tests for non-extractable WebCrypto keys
// and IndexedDB structured cloning persistence.
//
// RUN: node --test tests/ui_vault_persistence_test.ts

import { asKeyring } from './helpers/vaultTestKeyring.ts';
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
  VAULT_KEY_BYTES,
} from '../src/ui/utils/vaultCrypto.ts';
import {
  persistVaultKey,
  persistVaultKeys,
  restoreVaultKey,
  restoreVaultKeys,
  deleteVaultKey,
  createMockIndexedDB,
  VAULT_DB_NAME,
  VAULT_STORE_NAME,
  VAULT_KEY_RECORD_ID,
} from '../src/ui/utils/vaultPersistence.ts';
import { deriveTaskChainSearchKey } from '../src/ui/utils/taskChainSearch.ts';
import vaultReducer, {
  setVaultConfigured,
  setVaultUnlocked,
  lockVault,
  initializeVaultPersistence,
  setActiveVaultKey,
  setActiveBridgeVaultKeyMaterial,
  unlockVaultWithHex,
  getActiveTaskChainSearchKey,
  readSessionVaultKey,
  writeSessionVaultKey,
  clearSessionVaultKey,
  selectIsVaultUnlocked,
  selectIsVaultConfigured,
  selectRawVaultKeyHex,
  VAULT_SESSION_KEY,
} from '../src/ui/store/vaultSlice.ts';

// Setup mock storage and IndexedDB for testing environment
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

test('REQ-VAULT-HARDEN-1: WebCrypto keys imported and derived with extractable: false', async () => {
  const sampleKey = await generateVaultKey();
  const rawHex = await exportRawKeyHex(sampleKey);

  // 1. importRawKeyHex defaults to extractable: false
  const importedKey = await importRawKeyHex(rawHex);
  assert.equal(importedKey.type, 'secret');
  assert.equal(importedKey.extractable, false, 'Imported key must be non-extractable');

  // Calling exportKey throws InvalidAccessError
  await assert.rejects(async () => {
    await crypto.subtle.exportKey('raw', importedKey);
  }, (err: any) => err.name === 'InvalidAccessError' || String(err).includes('not extractable'));

  // 2. deriveKeyFromPassword defaults to extractable: false
  const salt = generateSaltHex(16);
  const derivedKey = await deriveKeyFromPassword('MasterPassword#2026', salt, 10_000);
  assert.equal(derivedKey.extractable, false, 'Derived password key must be non-extractable');

  await assert.rejects(async () => {
    await crypto.subtle.exportKey('raw', derivedKey);
  }, (err: any) => err.name === 'InvalidAccessError' || String(err).includes('not extractable'));

  // 3. deriveKeyFromRecoveryWords defaults to extractable: false
  const words = Array(12).fill('abandon');
  const recoveryKey = await deriveKeyFromRecoveryWords(words, salt, 10_000);
  assert.equal(recoveryKey.extractable, false, 'Derived recovery key must be non-extractable');

  await assert.rejects(async () => {
    await crypto.subtle.exportKey('raw', recoveryKey);
  }, (err: any) => err.name === 'InvalidAccessError' || String(err).includes('not extractable'));

  // Non-extractable key encrypts and decrypts correctly
  const plaintext = 'Zero-Trust Confidential Data Payload';
  const ciphertext = await encryptVaultText(plaintext, asKeyring(importedKey));
  const decrypted = await decryptVaultText(ciphertext, asKeyring(importedKey));
  assert.equal(decrypted, plaintext, 'Non-extractable key must round-trip encryption/decryption successfully');
});

test('REQ-VAULT-HARDEN-1: sessionStorage never stores raw vault key string', async () => {
  mockStorageMap.clear();

  const sampleKeyHex = 'e'.repeat(64);

  // writeSessionVaultKey is a no-op that does NOT populate sessionStorage
  writeSessionVaultKey(sampleKeyHex);
  assert.equal(fakeSessionStorage.getItem(VAULT_SESSION_KEY), null, 'sessionStorage must not contain raw key');
  assert.equal(readSessionVaultKey(), null, 'readSessionVaultKey must return null');

  // Unlocking does not touch sessionStorage
  let state = vaultReducer(undefined, { type: '@@INIT' });
  state = vaultReducer(state, setVaultUnlocked({ rawVaultKeyHex: sampleKeyHex, rememberSession: true }));
  assert.equal(fakeSessionStorage.getItem(VAULT_SESSION_KEY), null);
  assert.equal(readSessionVaultKey(), null);

  // Locking ensures any legacy key is cleared
  state = vaultReducer(state, lockVault());
  assert.equal(fakeSessionStorage.getItem(VAULT_SESSION_KEY), null);
});

test('REQ-VAULT-HARDEN-2: IndexedDB structured cloning stores, restores, and deletes non-extractable CryptoKey', async () => {
  (globalThis as any).indexedDB = createMockIndexedDB();
  setActiveVaultKey(null);

  const sampleKey = await generateVaultKey();
  const rawHex = await exportRawKeyHex(sampleKey);
  const nonExtractableKey = await importRawKeyHex(rawHex);

  // 1. Persist non-extractable key directly into IndexedDB
  await persistVaultKey(nonExtractableKey);

  // 2. Restore non-extractable CryptoKey from IndexedDB
  const restoredKey = await restoreVaultKey();
  assert.ok(restoredKey, 'Restored key must not be null');
  assert.equal(restoredKey.type, 'secret');
  assert.equal(restoredKey.extractable, false, 'Restored key must remain non-extractable');

  // Verify calling exportKey on restored key throws InvalidAccessError
  await assert.rejects(async () => {
    await crypto.subtle.exportKey('raw', restoredKey);
  }, (err: any) => err.name === 'InvalidAccessError' || String(err).includes('not extractable'));

  // 3. Restored key decrypts data encrypted by original key
  const secretText = 'Project architectural secrets';
  const cipher = await encryptVaultText(secretText, asKeyring(nonExtractableKey));
  const plain = await decryptVaultText(cipher, asKeyring(restoredKey));
  assert.equal(plain, secretText, 'Restored key must decrypt original ciphertext');

  // 4. initializeVaultPersistence integration test
  let dispatchedAction: any = null;
  const dispatchMock = (action: any) => { dispatchedAction = action; };
  const initializedKey = await initializeVaultPersistence(dispatchMock);
  assert.ok(initializedKey);
  assert.equal(getActiveVaultKey()?.keys.get(1), initializedKey);
  assert.equal(dispatchedAction?.type, 'vault/hydrateVaultFromSession');

  // 5. Locking vault purges IndexedDB and resets unlocked state
  let state = vaultReducer(undefined, { type: '@@INIT' });
  state = vaultReducer(state, setVaultConfigured(true));
  state = vaultReducer(state, setVaultUnlocked({ key: restoredKey }));
  assert.equal(selectIsVaultUnlocked({ vault: state }), true);

  state = vaultReducer(state, lockVault());
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
  assert.equal(getActiveVaultKey(), null);

  await deleteVaultKey();
  const keyAfterLock = await restoreVaultKey();
  assert.equal(keyAfterLock, null, 'IndexedDB record must be deleted on vault lock');
});

test('REQ-SEARCH-BRIDGE-UNLOCK-19: versioned persistence restores the non-extractable content/search key pair', async () => {
  (globalThis as any).indexedDB = createMockIndexedDB();
  setActiveVaultKey(null);

  const rawHex = '9a'.repeat(32);
  const contentKey = await importRawKeyHex(rawHex);
  const searchKey = await deriveTaskChainSearchKey(rawHex, 1);
  await persistVaultKeys(contentKey, searchKey.key);

  const restored = await restoreVaultKeys();
  assert.ok(restored);
  assert.equal(restored.version, 3);
  assert.equal(restored.contentKey.extractable, false);
  assert.equal(restored.taskChainSearchKey?.extractable, false);
  await assert.rejects(() => crypto.subtle.exportKey('raw', restored.contentKey));
  await assert.rejects(() => crypto.subtle.exportKey('raw', restored.taskChainSearchKey!));

  await initializeVaultPersistence();
  assert.equal(getActiveVaultKey()?.keys.get(1), restored.contentKey);
  assert.equal(getActiveTaskChainSearchKey()?.key, restored.taskChainSearchKey);

  let state = vaultReducer(undefined, { type: '@@INIT' });
  state = vaultReducer(state, lockVault());
  assert.equal(getActiveVaultKey(), null);
  assert.equal(getActiveTaskChainSearchKey(), null);
  await deleteVaultKey();
  assert.equal(await restoreVaultKeys(), null);
});

test('REQ-SEARCH-BRIDGE-UNLOCK-19: legacy content-only records restore without inventing a search key', async () => {
  (globalThis as any).indexedDB = createMockIndexedDB();
  setActiveVaultKey(null);

  const contentKey = await importRawKeyHex('7b'.repeat(32));
  await persistVaultKey(contentKey);
  const restored = await restoreVaultKeys();
  assert.ok(restored);
  assert.equal(restored.version, 1);
  assert.equal(restored.contentKey, contentKey);
  assert.equal(restored.taskChainSearchKey, null);

  await initializeVaultPersistence();
  assert.equal(getActiveVaultKey()?.keys.get(1), contentKey);
  assert.equal(getActiveTaskChainSearchKey(), null);
});

test('REQ-SEARCH-BRIDGE-UNLOCK-19: explicit remembered unlock derives and persists both keys without raw bytes', async () => {
  (globalThis as any).indexedDB = createMockIndexedDB();
  setActiveVaultKey(null);

  const rawHex = '4c'.repeat(32);
  const contentKey = await importRawKeyHex(rawHex);
  const state = vaultReducer(undefined, setVaultUnlocked({ key: contentKey, rememberSession: true }));
  assert.equal(selectIsVaultUnlocked({ vault: state }), true);
  await setActiveBridgeVaultKeyMaterial(rawHex);
  const restored = await restoreVaultKeys();
  assert.ok(restored);
  assert.equal(restored.version, 3);
  assert.equal(restored.contentKey.extractable, false);
  assert.equal(restored.taskChainSearchKey?.extractable, false);
  assert.equal(JSON.stringify(restored).includes(rawHex), false);
});

test('REQ-SEARCH-BRIDGE-UNLOCK-19: remembered unlock propagates key-pair persistence failures', async () => {
  const previousIndexedDB = (globalThis as any).indexedDB;
  (globalThis as any).indexedDB = undefined;
  try {
    await assert.rejects(
      () => unlockVaultWithHex('6d'.repeat(32), true),
      /IndexedDB is not available/,
    );
  } finally {
    setActiveVaultKey(null);
    (globalThis as any).indexedDB = previousIndexedDB;
  }
});

test('REQ-VAULT-HARDEN-1: Redux state is strictly serializable without raw keys', () => {
  let state = vaultReducer(undefined, { type: '@@INIT' });
  state = vaultReducer(state, setVaultConfigured(true));
  state = vaultReducer(state, setVaultUnlocked());

  assert.equal(selectIsVaultConfigured({ vault: state }), true);
  assert.equal(selectIsVaultUnlocked({ vault: state }), true);
  assert.equal((state as any).rawVaultKeyHex, undefined);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);

  // JSON serialization test (guarantees state is serializable)
  const serialized = JSON.stringify(state);
  assert.ok(!serialized.includes('rawVaultKeyHex'), 'Serialized state must not contain rawVaultKeyHex');
  const parsed = JSON.parse(serialized);
  assert.equal(parsed.isConfigured, true);
  assert.equal(parsed.isUnlocked, true);
});
