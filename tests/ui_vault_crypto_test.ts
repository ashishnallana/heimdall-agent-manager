// REQ-VAULT-CRYPTO-LIB-1: vault byte helpers, BIP-39 recovery words and the
// keyring-accessor vaultSlice. (Password/PBKDF2 key envelopes no longer exist.)
//
// RUN: node --test tests/ui_vault_crypto_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { BIP39_WORDS } from '../src/ui/utils/bip39Words.ts';
import {
  generate12RecoveryWords,
  validateRecoveryWords,
  generateSaltHex,
  generateNonceHex,
  bytesToHex,
  hexToBytes,
} from '../src/ui/utils/vaultCrypto.ts';
import { configureStore } from '@reduxjs/toolkit';
import vaultReducer, {
  keyringInstalled,
  keyringCleared,
  selectIsVaultUnlocked,
  selectVaultEpoch,
} from '../src/ui/store/vaultSlice.ts';

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
// 3. 12-Word Mnemonic Generation and BIP-39 Checksum Validation
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
// 4. vaultSlice: keyring accessors only (no configured/lock state, no key bytes)
// -----------------------------------------------------------------------------

test('vaultSlice mirrors keyring install/clear and stays serializable', () => {
  const store = configureStore({ reducer: { vault: vaultReducer } });
  assert.equal(selectIsVaultUnlocked(store.getState()), false);
  assert.equal(selectVaultEpoch(store.getState()), 0);

  store.dispatch(keyringInstalled({ currentEpoch: 3 }));
  assert.equal(selectIsVaultUnlocked(store.getState()), true);
  assert.equal(selectVaultEpoch(store.getState()), 3);
  assert.deepEqual(Object.keys(store.getState().vault).sort(), ['currentEpoch', 'isUnlocked']);
  assert.doesNotThrow(() => JSON.stringify(store.getState()));

  store.dispatch(keyringCleared());
  assert.equal(selectIsVaultUnlocked(store.getState()), false);
  assert.equal(selectVaultEpoch(store.getState()), 0);
});
