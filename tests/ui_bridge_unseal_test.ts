// REQ-VAULT-HARDEN-3, REQ-VAULT-HARDEN-8:
// Unit tests for Hub-blind E2EE bridge key wrapping and authenticated unseal protocol.
//
// RUN: node --test tests/ui_bridge_unseal_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  buildUnsealAad,
  prepareUnsealPayload,
  type BridgeUnsealPayload,
} from '../src/ui/utils/vaultBridgeUnseal.ts';
import { hexToBytes, bytesToHex } from '../src/ui/utils/vaultCrypto.ts';

const TEST_VAULT_KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

test('buildUnsealAad produces canonical bridge_id:timestamp:nonce string', () => {
  const aad = buildUnsealAad('brg_test_123', 1700000000000, 'nonce_abc_456');
  const decoded = new TextDecoder().decode(aad);
  assert.equal(decoded, 'brg_test_123:1700000000000:nonce_abc_456');
});

test('prepareUnsealPayload rejects invalid bridge public key length or format', async () => {
  // Not 65 bytes
  await assert.rejects(
    async () => {
      await prepareUnsealPayload('brg_1', '04aabbcc', TEST_VAULT_KEY_HEX);
    },
    /Invalid bridge public key/
  );

  // 65 bytes but does not start with 0x04
  const invalidHeaderBytes = new Uint8Array(65);
  invalidHeaderBytes[0] = 0x02;
  const invalidHeaderHex = bytesToHex(invalidHeaderBytes);
  await assert.rejects(
    async () => {
      await prepareUnsealPayload('brg_1', invalidHeaderHex, TEST_VAULT_KEY_HEX);
    },
    /Invalid bridge public key/
  );
});

test('prepareUnsealPayload encrypts payload that bridge can decrypt with private key', async () => {
  // Generate a mock Bridge ECDH P-256 keypair
  const bridgeKeyPair = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' },
    true,
    ['deriveBits', 'deriveKey']
  );

  const bridgePubRaw = await crypto.subtle.exportKey('raw', bridgeKeyPair.publicKey);
  const bridgePubHex = bytesToHex(new Uint8Array(bridgePubRaw));

  const bridgeId = 'brg_alpha';
  const timestamp = Date.now();
  const nonce = 'test_nonce_789';
  const commandId = 'cmd_unseal_test_1';

  const payload: BridgeUnsealPayload = await prepareUnsealPayload(
    bridgeId,
    bridgePubHex,
    TEST_VAULT_KEY_HEX,
    { timestamp, nonce, commandId }
  );

  assert.equal(payload.type, 'bridge_unseal');
  assert.equal(payload.bridge_id, bridgeId);
  assert.equal(payload.timestamp, timestamp);
  assert.equal(payload.nonce, nonce);
  assert.equal(payload.command_id, commandId);
  assert.equal(payload.iv.length, 24); // 12 bytes = 24 hex chars
  assert.equal(payload.tag.length, 32); // 16 bytes = 32 hex chars
  assert.ok(payload.ciphertext.length > 0);
  assert.equal(payload.client_public_key.length, 130); // 65 bytes = 130 hex chars

  // Decrypt using simulated Bridge logic
  const clientPubBytes = hexToBytes(payload.client_public_key);
  const clientCryptoKey = await crypto.subtle.importKey(
    'raw',
    clientPubBytes as any,
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    []
  );

  const sharedSecret = await crypto.subtle.deriveBits(
    { name: 'ECDH', public: clientCryptoKey },
    bridgeKeyPair.privateKey,
    256
  );

  const hkdfKey = await crypto.subtle.importKey(
    'raw',
    sharedSecret as any,
    'HKDF',
    false,
    ['deriveKey']
  );

  const aesKey = await crypto.subtle.deriveKey(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: new Uint8Array(32),
      info: new TextEncoder().encode('heimdall-bridge-unseal-v1'),
    },
    hkdfKey,
    { name: 'AES-GCM', length: 256 },
    false,
    ['decrypt']
  );

  const ivBytes = hexToBytes(payload.iv);
  const tagBytes = hexToBytes(payload.tag);
  const ctBytes = hexToBytes(payload.ciphertext);

  // In WebCrypto AES-GCM, ciphertext and tag are concatenated
  const combinedEncrypted = new Uint8Array(ctBytes.length + tagBytes.length);
  combinedEncrypted.set(ctBytes, 0);
  combinedEncrypted.set(tagBytes, ctBytes.length);

  const aadBytes = buildUnsealAad(payload.bridge_id, payload.timestamp, payload.nonce);

  const decryptedBuf = await crypto.subtle.decrypt(
    {
      name: 'AES-GCM',
      iv: ivBytes as any,
      additionalData: aadBytes as any,
      tagLength: 128,
    },
    aesKey,
    combinedEncrypted as any
  );

  const decryptedKey = new TextDecoder().decode(decryptedBuf);
  assert.equal(decryptedKey, TEST_VAULT_KEY_HEX, 'Decrypted key matches original vault key');
});

test('tampering with timestamp, nonce, or bridge_id in AAD fails AES-GCM tag verification', async () => {
  const bridgeKeyPair = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' },
    true,
    ['deriveBits', 'deriveKey']
  );
  const bridgePubHex = bytesToHex(new Uint8Array(await crypto.subtle.exportKey('raw', bridgeKeyPair.publicKey)));

  const payload = await prepareUnsealPayload('brg_alpha', bridgePubHex, TEST_VAULT_KEY_HEX, {
    timestamp: 1000000,
    nonce: 'nonce_tamper_test',
  });

  const clientCryptoKey = await crypto.subtle.importKey(
    'raw',
    hexToBytes(payload.client_public_key) as any,
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    []
  );

  const sharedSecret = await crypto.subtle.deriveBits(
    { name: 'ECDH', public: clientCryptoKey },
    bridgeKeyPair.privateKey,
    256
  );

  const hkdfKey = await crypto.subtle.importKey('raw', sharedSecret as any, 'HKDF', false, ['deriveKey']);
  const aesKey = await crypto.subtle.deriveKey(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: new Uint8Array(32),
      info: new TextEncoder().encode('heimdall-bridge-unseal-v1'),
    },
    hkdfKey,
    { name: 'AES-GCM', length: 256 },
    false,
    ['decrypt']
  );

  const ivBytes = hexToBytes(payload.iv);
  const tagBytes = hexToBytes(payload.tag);
  const ctBytes = hexToBytes(payload.ciphertext);
  const combinedEncrypted = new Uint8Array(ctBytes.length + tagBytes.length);
  combinedEncrypted.set(ctBytes, 0);
  combinedEncrypted.set(tagBytes, ctBytes.length);

  // 1. Tamper with bridge_id
  const tamperedBridgeAad = buildUnsealAad('brg_different', payload.timestamp, payload.nonce);
  await assert.rejects(async () => {
    await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: ivBytes as any, additionalData: tamperedBridgeAad as any, tagLength: 128 },
      aesKey,
      combinedEncrypted as any
    );
  }, /operation failed/i);

  // 2. Tamper with timestamp
  const tamperedTimeAad = buildUnsealAad(payload.bridge_id, payload.timestamp + 1000, payload.nonce);
  await assert.rejects(async () => {
    await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: ivBytes as any, additionalData: tamperedTimeAad as any, tagLength: 128 },
      aesKey,
      combinedEncrypted as any
    );
  }, /operation failed/i);

  // 3. Tamper with nonce
  const tamperedNonceAad = buildUnsealAad(payload.bridge_id, payload.timestamp, 'tampered_nonce');
  await assert.rejects(async () => {
    await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: ivBytes as any, additionalData: tamperedNonceAad as any, tagLength: 128 },
      aesKey,
      combinedEncrypted as any
    );
  }, /operation failed/i);
});

test('tampering with ciphertext or authentication tag fails AEAD verification', async () => {
  const bridgeKeyPair = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' },
    true,
    ['deriveBits', 'deriveKey']
  );
  const bridgePubHex = bytesToHex(new Uint8Array(await crypto.subtle.exportKey('raw', bridgeKeyPair.publicKey)));

  const payload = await prepareUnsealPayload('brg_alpha', bridgePubHex, TEST_VAULT_KEY_HEX);

  const clientCryptoKey = await crypto.subtle.importKey(
    'raw',
    hexToBytes(payload.client_public_key) as any,
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    []
  );

  const sharedSecret = await crypto.subtle.deriveBits(
    { name: 'ECDH', public: clientCryptoKey },
    bridgeKeyPair.privateKey,
    256
  );

  const hkdfKey = await crypto.subtle.importKey('raw', sharedSecret as any, 'HKDF', false, ['deriveKey']);
  const aesKey = await crypto.subtle.deriveKey(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: new Uint8Array(32),
      info: new TextEncoder().encode('heimdall-bridge-unseal-v1'),
    },
    hkdfKey,
    { name: 'AES-GCM', length: 256 },
    false,
    ['decrypt']
  );

  const ivBytes = hexToBytes(payload.iv);
  const tagBytes = hexToBytes(payload.tag);
  const ctBytes = hexToBytes(payload.ciphertext);
  const aadBytes = buildUnsealAad(payload.bridge_id, payload.timestamp, payload.nonce);

  // Tamper ciphertext byte
  const tamperedCt = new Uint8Array(ctBytes.length + tagBytes.length);
  tamperedCt.set(ctBytes, 0);
  tamperedCt.set(tagBytes, ctBytes.length);
  tamperedCt[0] ^= 0xff;

  await assert.rejects(async () => {
    await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: ivBytes as any, additionalData: aadBytes as any, tagLength: 128 },
      aesKey,
      tamperedCt as any
    );
  }, /operation failed/i);

  // Tamper tag byte
  const tamperedTag = new Uint8Array(ctBytes.length + tagBytes.length);
  tamperedTag.set(ctBytes, 0);
  tamperedTag.set(tagBytes, ctBytes.length);
  tamperedTag[tamperedTag.length - 1] ^= 0xff;

  await assert.rejects(async () => {
    await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: ivBytes as any, additionalData: aadBytes as any, tagLength: 128 },
      aesKey,
      tamperedTag as any
    );
  }, /operation failed/i);
});

test('resolveVaultStatus returns correct tri-state for all conditions (REQ-VAULT-HARDEN-7, 10, 11)', async () => {
  const { resolveVaultStatus } = await import('../src/ui/store/vaultSlice.ts');

  // 1. Not configured -> Disabled
  assert.equal(resolveVaultStatus({ isConfigured: false, isUnlocked: false }), 'Disabled');
  assert.equal(resolveVaultStatus({ isConfigured: false, isUnlocked: true }), 'Disabled');

  // 2. Configured but not unlocked -> Locked
  assert.equal(resolveVaultStatus({ isConfigured: true, isUnlocked: false }), 'Locked');

  // 3. Configured and unlocked -> Unlocked
  assert.equal(resolveVaultStatus({ isConfigured: true, isUnlocked: true }), 'Unlocked');
});


