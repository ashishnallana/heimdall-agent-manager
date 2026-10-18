// REQ-VAULT-CRYPTO-LIB-1: Tests for WebCrypto User Vault Client Library,
// BIP-39 mnemonic phrase generation, envelope wrapping/unwrapping, and Redux vaultSlice.
//
// RUN: node --test tests/ui_vault_crypto_test.ts

import { asKeyring } from './helpers/vaultTestKeyring.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { BIP39_WORDS } from '../src/ui/utils/bip39Words.ts';
import {
  generateVaultKey,
  exportRawKeyHex,
  importRawKeyHex,
  deriveKeyFromPassword,
  generate12RecoveryWords,
  validateRecoveryWords,
  deriveKeyFromRecoveryWords,
  encryptVaultKeyEnvelope,
  decryptVaultKeyEnvelope,
  encryptVaultText,
  decryptVaultText,
  generateSaltHex,
  generateNonceHex,
  bytesToHex,
  hexToBytes,
  DEFAULT_KDF_ITERATIONS,
  VAULT_KEY_BYTES,
  AES_GCM_NONCE_BYTES,
  AES_GCM_TAG_BYTES,
} from '../src/ui/utils/vaultCrypto.ts';
import { configureStore } from '@reduxjs/toolkit';
import vaultReducer, {
  setVaultConfigured,
  setVaultUnlocked,
  lockVault,
  selectVaultState,
  selectIsVaultConfigured,
  selectIsVaultUnlocked,
  selectRawVaultKeyHex,
} from '../src/ui/store/vaultSlice.ts';

/**
 * Flip every bit of the first byte of a hex string, for tamper-detection assertions.
 *
 * Do NOT tamper by assigning a fixed byte (e.g. `'00' + hex.slice(2)`): that is the
 * identity function whenever the first byte already equals the value assigned, so on
 * 1 run in 256 nothing is actually tampered, decryption legitimately succeeds, and the
 * assertion either fails spuriously or — worse — passes without testing tamper
 * detection at all. XOR with 0xff always changes the byte.
 *
 * Matches the byte-flip convention already used in tests/ui_vault_content_test.ts.
 */
function flipFirstByteHex(hex: string): string {
  const flipped = (parseInt(hex.slice(0, 2), 16) ^ 0xff).toString(16).padStart(2, '0');
  return flipped + hex.slice(2);
}

// -----------------------------------------------------------------------------
// 1. BIP-39 Word List
// -----------------------------------------------------------------------------

test('BIP-39 English wordlist contains exactly 2048 words with proper bounds', () => {
  assert.equal(BIP39_WORDS.length, 2048, 'Word list must contain exactly 2048 words');
  assert.equal(BIP39_WORDS[0], 'abandon', 'First word in BIP-39 English is abandon');
  assert.equal(BIP39_WORDS[2047], 'zoo', 'Last word in BIP-39 English is zoo');

  const uniqueWords = new Set(BIP39_WORDS);
  assert.equal(uniqueWords.size, 2048, 'All words in BIP-39 list must be unique');

  for (const word of BIP39_WORDS) {
    assert.ok(word.length > 0, 'Word must not be empty');
    assert.equal(word, word.toLowerCase(), 'Word must be lowercase');
    assert.ok(!/\s/.test(word), 'Word must not contain whitespace');
  }
});

// -----------------------------------------------------------------------------
// 2. Hex and Buffer Utilities
// -----------------------------------------------------------------------------

test('hex conversion helpers correctly encode and decode bytes', () => {
  const sample = new Uint8Array([0x00, 0x0f, 0x10, 0xab, 0xff]);
  const hex = bytesToHex(sample);
  assert.equal(hex, '000f10abff');
  const decoded = hexToBytes(hex);
  assert.deepEqual(Array.from(decoded), Array.from(sample));

  // Invalid hex error cases
  assert.throws(() => hexToBytes('abc'), /even length/);
  assert.throws(() => hexToBytes('0g'), /Invalid hex/);
});

test('generateSaltHex and generateNonceHex return correct lengths', () => {
  const salt = generateSaltHex(16);
  assert.equal(salt.length, 32, '16-byte salt must be 32 hex characters');

  const nonce = generateNonceHex(12);
  assert.equal(nonce.length, 24, '12-byte nonce must be 24 hex characters');
});

// -----------------------------------------------------------------------------
// 3. Vault Key Generation, Hex Export, and Import
// -----------------------------------------------------------------------------

test('generateVaultKey creates an extractable 256-bit AES-GCM key', async () => {
  const key = await generateVaultKey();
  assert.equal(key.type, 'secret');
  assert.equal(key.algorithm.name, 'AES-GCM');
  assert.equal((key.algorithm as any).length, 256);
  assert.equal(key.extractable, true);
});

test('importRawKeyHex imports non-extractable 256-bit AES-GCM key (REQ-VAULT-HARDEN-1)', async () => {
  const originalKey = await generateVaultKey();
  const hex = await exportRawKeyHex(originalKey);

  assert.equal(hex.length, VAULT_KEY_BYTES * 2, 'Raw key hex must be 64 characters');
  assert.ok(/^[0-9a-f]{64}$/.test(hex), 'Raw key hex must be lowercase hex characters');

  const importedKey = await importRawKeyHex(hex);
  assert.equal(importedKey.extractable, false);

  // Calling crypto.subtle.exportKey('raw', key) throws InvalidAccessError (REQ-VAULT-HARDEN-1)
  await assert.rejects(async () => {
    await crypto.subtle.exportKey('raw', importedKey);
  }, (err: any) => err.name === 'InvalidAccessError' || String(err).includes('not extractable'));

  // Round-trip encryption and decryption functions correctly with non-extractable key
  const testCipher = await encryptVaultText('roundtrip test', asKeyring(importedKey));
  const testPlain = await decryptVaultText(testCipher, asKeyring(importedKey));
  assert.equal(testPlain, 'roundtrip test');

  // Input validation
  await assert.rejects(async () => {
    await importRawKeyHex('abcd');
  }, /expected 32 bytes/);
});

// -----------------------------------------------------------------------------
// 4. PBKDF2 Password Derivation
// -----------------------------------------------------------------------------

test('deriveKeyFromPassword deterministically derives non-extractable 256-bit AES-GCM key', async () => {
  const password = 'SuperSecretMasterPassword!2026';
  const saltHex = generateSaltHex(16);

  const key1 = await deriveKeyFromPassword(password, saltHex, 10_000);
  const key2 = await deriveKeyFromPassword(password, saltHex, 10_000);

  assert.equal(key1.extractable, false);
  assert.equal(key2.extractable, false);

  // Calling crypto.subtle.exportKey('raw', key) throws InvalidAccessError
  await assert.rejects(async () => {
    await crypto.subtle.exportKey('raw', key1);
  }, (err: any) => err.name === 'InvalidAccessError' || String(err).includes('not extractable'));

  // Verify key1 and key2 are functionally identical: encrypt with key1, decrypt with key2
  const cipher1 = await encryptVaultText('deterministic check', asKeyring(key1));
  const plain2 = await decryptVaultText(cipher1, asKeyring(key2));
  assert.equal(plain2, 'deterministic check');

  // Different password produces different key (decryption fails)
  const keyDiffPass = await deriveKeyFromPassword('DifferentPassword!2026', saltHex, 10_000);
  await assert.rejects(async () => {
    await decryptVaultText(cipher1, asKeyring(keyDiffPass));
  });

  // Different salt produces different key (decryption fails)
  const saltHex2 = generateSaltHex(16);
  const keyDiffSalt = await deriveKeyFromPassword(password, saltHex2, 10_000);
  await assert.rejects(async () => {
    await decryptVaultText(cipher1, asKeyring(keyDiffSalt));
  });
});

// -----------------------------------------------------------------------------
// 5. 12-Word Mnemonic Generation and BIP-39 Checksum Validation
// -----------------------------------------------------------------------------

test('generate12RecoveryWords generates valid 12 BIP-39 words with valid checksum', () => {
  const result = generate12RecoveryWords();
  assert.equal(result.words.length, 12, 'Must generate exactly 12 words');
  assert.equal(result.entropyHex.length, 32, '128-bit entropy must be 32 hex chars');

  for (const word of result.words) {
    assert.ok(BIP39_WORDS.includes(word), `Word ${word} must be in BIP-39 wordlist`);
  }

  const isValid = validateRecoveryWords(result.words);
  assert.equal(isValid, true, 'Generated mnemonic must pass checksum validation');
});

test('validateRecoveryWords matches official BIP-39 test vector', () => {
  // BIP-39 test vector for 16 zero bytes (128-bit 0):
  // 11 x 'abandon' + 'about'
  const zeroEntropy = new Uint8Array(16);
  const vector = generate12RecoveryWords(zeroEntropy);

  assert.equal(vector.entropyHex, '00000000000000000000000000000000');
  assert.deepEqual(vector.words.slice(0, 11), Array(11).fill('abandon'));
  assert.equal(vector.words[11], 'about');

  assert.equal(validateRecoveryWords(vector.words), true);

  // Altering the last word invalidates the checksum
  const corrupted = [...vector.words];
  corrupted[11] = 'abandon';
  assert.equal(validateRecoveryWords(corrupted), false, 'Corrupted checksum word must fail');

  // Invalid word outside wordlist
  const unknownWord = [...vector.words];
  unknownWord[0] = 'notabip39word';
  assert.equal(validateRecoveryWords(unknownWord), false, 'Unknown word must fail');

  // Wrong number of words
  assert.equal(validateRecoveryWords(vector.words.slice(0, 11)), false);
});

// -----------------------------------------------------------------------------
// 6. Envelope Wrapping and Unwrapping (Master Password)
// -----------------------------------------------------------------------------

test('encryptVaultKeyEnvelope and decryptVaultKeyEnvelope round-trip with password', async () => {
  const vaultKey = await generateVaultKey();
  const originalVaultHex = await exportRawKeyHex(vaultKey);

  const saltHex = generateSaltHex(16);
  const password = 'CorrectHorseBatteryStaple#42';
  const masterKey = await deriveKeyFromPassword(password, saltHex, 50_000);

  const envelope = await encryptVaultKeyEnvelope(masterKey, vaultKey);
  assert.equal(envelope.ciphertextHex.length, VAULT_KEY_BYTES * 2, 'Ciphertext must be 32 bytes hex');
  assert.equal(envelope.nonceHex.length, AES_GCM_NONCE_BYTES * 2, 'Nonce must be 12 bytes hex');
  assert.equal(envelope.tagHex.length, AES_GCM_TAG_BYTES * 2, 'Tag must be 16 bytes hex');

  // Successful decryption
  const decryptedVaultKey = await decryptVaultKeyEnvelope(
    masterKey,
    envelope.ciphertextHex,
    envelope.nonceHex,
    envelope.tagHex,
  );
  assert.equal(decryptedVaultKey.extractable, false);
  const testCipher = await encryptVaultText('envelope test', asKeyring(vaultKey));
  const testDecrypted = await decryptVaultText(testCipher, asKeyring(decryptedVaultKey));
  assert.equal(testDecrypted, 'envelope test');

  // Wrong password fails
  const wrongKey = await deriveKeyFromPassword('WrongPassword', saltHex, 50_000);
  await assert.rejects(async () => {
    await decryptVaultKeyEnvelope(
      wrongKey,
      envelope.ciphertextHex,
      envelope.nonceHex,
      envelope.tagHex,
    );
  });

  // Tampered tag fails
  const tamperedTag = flipFirstByteHex(envelope.tagHex);
  await assert.rejects(
    async () => {
      await decryptVaultKeyEnvelope(
        masterKey,
        envelope.ciphertextHex,
        envelope.nonceHex,
        tamperedTag,
      );
    },
    /operation|mac|tag|decrypt/i,
    'Tampered auth tag must fail AES-GCM authentication, not merely fail to parse',
  );

  // Tampered ciphertext fails
  const tamperedCiphertext = flipFirstByteHex(envelope.ciphertextHex);
  await assert.rejects(
    async () => {
      await decryptVaultKeyEnvelope(
        masterKey,
        tamperedCiphertext,
        envelope.nonceHex,
        envelope.tagHex,
      );
    },
    /operation|mac|tag|decrypt/i,
    'Tampered ciphertext must fail AES-GCM authentication, not merely fail to parse',
  );
});

// -----------------------------------------------------------------------------
// 7. Envelope Wrapping and Unwrapping (12 Recovery Words)
// -----------------------------------------------------------------------------

test('deriveKeyFromRecoveryWords enables full recovery envelope round-trip', async () => {
  const vaultKey = await generateVaultKey();
  const originalVaultHex = await exportRawKeyHex(vaultKey);

  const { words } = generate12RecoveryWords();
  const recoverySaltHex = generateSaltHex(16);

  const recoveryKey = await deriveKeyFromRecoveryWords(words, recoverySaltHex, 50_000);
  const recoveryEnvelope = await encryptVaultKeyEnvelope(recoveryKey, vaultKey);

  // Recover vault key using recovery words
  const recoveryKey2 = await deriveKeyFromRecoveryWords(words, recoverySaltHex, 50_000);
  const recoveredVaultKey = await decryptVaultKeyEnvelope(
    recoveryKey2,
    recoveryEnvelope.ciphertextHex,
    recoveryEnvelope.nonceHex,
    recoveryEnvelope.tagHex,
  );

  assert.equal(recoveredVaultKey.extractable, false);
  const recCipher = await encryptVaultText('recovery test', asKeyring(vaultKey));
  const recDecrypted = await decryptVaultText(recCipher, asKeyring(recoveredVaultKey));
  assert.equal(recDecrypted, 'recovery test');

  // Wrong recovery phrase fails
  const otherWords = [...words];
  otherWords[0] = otherWords[0] === 'abandon' ? 'ability' : 'abandon';
  const wrongRecoveryKey = await deriveKeyFromRecoveryWords(otherWords, recoverySaltHex, 50_000);
  await assert.rejects(async () => {
    await decryptVaultKeyEnvelope(
      wrongRecoveryKey,
      recoveryEnvelope.ciphertextHex,
      recoveryEnvelope.nonceHex,
      recoveryEnvelope.tagHex,
    );
  });
});

// -----------------------------------------------------------------------------
// 8. Redux vaultSlice State Management
// -----------------------------------------------------------------------------

test('vaultSlice transitions between unconfigured, configured, unlocked, and locked', () => {
  let state = vaultReducer(undefined, { type: '@@init' });
  assert.equal(state.isConfigured, false);
  assert.equal(state.isUnlocked, false);
  assert.equal((state as any).rawVaultKeyHex, undefined);

  // Configure vault
  state = vaultReducer(state, setVaultConfigured(true));
  assert.equal(state.isConfigured, true);
  assert.equal(state.isUnlocked, false);
  assert.equal((state as any).rawVaultKeyHex, undefined);

  // Unlock vault
  const sampleKeyHex = 'a'.repeat(64);
  state = vaultReducer(state, setVaultUnlocked(sampleKeyHex));
  assert.equal(state.isConfigured, true);
  assert.equal(state.isUnlocked, true);
  // Redux state must be serializable and NOT store raw key strings (REQ-VAULT-HARDEN-1)
  assert.equal((state as any).rawVaultKeyHex, undefined);

  // Lock vault
  state = vaultReducer(state, lockVault());
  assert.equal(state.isConfigured, true);
  assert.equal(state.isUnlocked, false);
  assert.equal((state as any).rawVaultKeyHex, undefined);

  // Reset configured state to false resets unlocked state and key
  state = vaultReducer(state, setVaultUnlocked(sampleKeyHex));
  assert.equal(state.isUnlocked, true);
  state = vaultReducer(state, setVaultConfigured(false));
  assert.equal(state.isConfigured, false);
  assert.equal(state.isUnlocked, false);
  assert.equal((state as any).rawVaultKeyHex, undefined);
});

test('store mounts vaultSlice and selectors work correctly', () => {
  const testStore = configureStore({
    reducer: {
      vault: vaultReducer,
    },
  });

  const rootState = testStore.getState();
  assert.ok('vault' in rootState, 'vault slice must be mounted in root store');

  const vault = selectVaultState(rootState);
  assert.equal(selectIsVaultConfigured(rootState), vault.isConfigured);
  assert.equal(selectIsVaultUnlocked(rootState), vault.isUnlocked);
  assert.equal(selectRawVaultKeyHex(rootState), null);

  // Dispatch actions to store
  const sampleKey = 'f'.repeat(64);
  testStore.dispatch(setVaultConfigured(true));
  testStore.dispatch(setVaultUnlocked(sampleKey));

  const updatedState = testStore.getState();
  assert.equal(selectIsVaultConfigured(updatedState), true);
  assert.equal(selectIsVaultUnlocked(updatedState), true);
  // Redux state must be serializable and NOT contain raw key
  assert.equal((updatedState.vault as any).rawVaultKeyHex, undefined);
  assert.equal(selectRawVaultKeyHex(updatedState), null);

  testStore.dispatch(lockVault());
  const lockedState = testStore.getState();
  assert.equal(selectIsVaultUnlocked(lockedState), false);
  assert.equal(selectRawVaultKeyHex(lockedState), null);
});

