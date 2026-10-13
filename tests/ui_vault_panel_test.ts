// REQ-VAULT-UI-SETTINGS-1: Tests for Settings VaultPanel component,
// AppShell navigation & routing, and Zero-Knowledge setup/unlock flow.
//
// RUN: node --test tests/ui_vault_panel_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  generateVaultKey,
  exportRawKeyHex,
  deriveKeyFromPassword,
  generate12RecoveryWords,
  validateRecoveryWords,
  deriveKeyFromRecoveryWords,
  encryptVaultKeyEnvelope,
  decryptVaultKeyEnvelope,
  encryptVaultText,
  decryptVaultText,
  generateSaltHex,
  DEFAULT_KDF_ITERATIONS,
} from '../src/ui/utils/vaultCrypto.ts';
import vaultReducer, {
  setVaultConfigured,
  setVaultUnlocked,
  lockVault,
  selectIsVaultConfigured,
  selectIsVaultUnlocked,
  selectRawVaultKeyHex,
} from '../src/ui/store/vaultSlice.ts';

// -----------------------------------------------------------------------------
// Test 3: Functional verification of Setup Wizard envelope creation & Dual Unlock
// -----------------------------------------------------------------------------

test('End-to-End Vault lifecycle: Setup -> Master Password Unlock -> Recovery Phrase Unlock', async () => {
  // 1. Setup Wizard: generate keys and envelopes
  const password = 'CorrectHorseBatteryStaple123!';
  const { words, entropyHex } = generate12RecoveryWords();
  assert.equal(words.length, 12);
  assert.ok(validateRecoveryWords(words));

  const vaultKey = await generateVaultKey();
  const rawVaultKeyHex = await exportRawKeyHex(vaultKey);
  assert.equal(rawVaultKeyHex.length, 64);

  // Derive Master Wrapping Key (KM)
  const kdfSalt = generateSaltHex(16);
  const km = await deriveKeyFromPassword(password, kdfSalt, DEFAULT_KDF_ITERATIONS);
  const pwEnvelope = await encryptVaultKeyEnvelope(km, vaultKey);

  // Derive Recovery Wrapping Key (KR)
  const recoverySalt = generateSaltHex(16);
  const kr = await deriveKeyFromRecoveryWords(words, recoverySalt, DEFAULT_KDF_ITERATIONS);
  const recoveryEnvelope = await encryptVaultKeyEnvelope(kr, vaultKey);

  // Simulating POST /api/v1/user/vault payload
  const storedVaultRecord = {
    encrypted_vault_key: pwEnvelope.ciphertextHex,
    vault_key_nonce: pwEnvelope.nonceHex,
    vault_key_tag: pwEnvelope.tagHex,
    kdf_algorithm: 'PBKDF2-SHA256',
    kdf_salt: kdfSalt,
    kdf_iterations: DEFAULT_KDF_ITERATIONS,
    recovery_encrypted_vault_key: recoveryEnvelope.ciphertextHex,
    recovery_nonce: recoveryEnvelope.nonceHex,
    recovery_tag: recoveryEnvelope.tagHex,
    recovery_salt: recoverySalt,
  };

  // 2. Unlock with correct Master Password
  const kmUnlock = await deriveKeyFromPassword(
    password,
    storedVaultRecord.kdf_salt,
    storedVaultRecord.kdf_iterations,
  );
  const decryptedVaultKeyPw = await decryptVaultKeyEnvelope(
    kmUnlock,
    storedVaultRecord.encrypted_vault_key,
    storedVaultRecord.vault_key_nonce,
    storedVaultRecord.vault_key_tag,
  );
  assert.equal(decryptedVaultKeyPw.extractable, false, 'Password unlock must yield non-extractable key');
  const pwCipher = await encryptVaultText('pw test', vaultKey);
  const pwDecrypted = await decryptVaultText(pwCipher, decryptedVaultKeyPw);
  assert.equal(pwDecrypted, 'pw test');

  // 3. Unlock with wrong Master Password must fail
  const kmWrong = await deriveKeyFromPassword(
    'WrongPassword!',
    storedVaultRecord.kdf_salt,
    storedVaultRecord.kdf_iterations,
  );
  await assert.rejects(
    async () => {
      await decryptVaultKeyEnvelope(
        kmWrong,
        storedVaultRecord.encrypted_vault_key,
        storedVaultRecord.vault_key_nonce,
        storedVaultRecord.vault_key_tag,
      );
    },
    /operation failed|decryption failed|OperationError/i,
    'Decryption with incorrect password must fail',
  );

  // 4. Unlock with 12 Recovery Words
  const krUnlock = await deriveKeyFromRecoveryWords(
    words,
    storedVaultRecord.recovery_salt,
    storedVaultRecord.kdf_iterations,
  );
  const decryptedVaultKeyRec = await decryptVaultKeyEnvelope(
    krUnlock,
    storedVaultRecord.recovery_encrypted_vault_key,
    storedVaultRecord.recovery_nonce,
    storedVaultRecord.recovery_tag,
  );
  assert.equal(decryptedVaultKeyRec.extractable, false, 'Recovery words unlock must yield non-extractable key');
  const recCipher = await encryptVaultText('rec test', vaultKey);
  const recDecrypted = await decryptVaultText(recCipher, decryptedVaultKeyRec);
  assert.equal(recDecrypted, 'rec test');

  // 5. Redux state transitions
  let state = vaultReducer(undefined, { type: '@@INIT' });
  assert.equal(selectIsVaultConfigured({ vault: state }), false);
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);

  // Configure & Unlock
  state = vaultReducer(state, setVaultConfigured(true));
  state = vaultReducer(state, setVaultUnlocked());
  assert.equal(selectIsVaultConfigured({ vault: state }), true);
  assert.equal(selectIsVaultUnlocked({ vault: state }), true);
  assert.equal((state as any).rawVaultKeyHex, undefined);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);

  // Lock
  state = vaultReducer(state, lockVault());
  assert.equal(selectIsVaultConfigured({ vault: state }), true);
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);
});
