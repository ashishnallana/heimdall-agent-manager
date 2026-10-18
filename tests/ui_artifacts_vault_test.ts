// REQ-VAULT-ARTIFACTS-1: Unit Tests for Artifacts UI Zero-Knowledge Encryption, Decryption,
// and Reusable VaultText Integration.
//
// RUN: node --test tests/ui_artifacts_vault_test.ts

import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  isVaultArmored,
  encryptVaultText,
  decryptVaultText,
  VAULT_ARMOR_PREFIX,
  base64ToBytes,
  bytesToBase64,
} from '../src/ui/utils/vaultContent.ts';
import {
  encryptArtifactFields,
  decryptArtifactRecord,
  decryptArtifactText,
} from '../src/ui/utils/vaultArtifacts.ts';

const TEST_KEY_HEX_RAW = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const TEST_KEY_HEX = await keyringFromHex(TEST_KEY_HEX_RAW);

// -----------------------------------------------------------------------------
// Test 1: Legacy unarmored plaintext artifact tolerance and passthrough
// -----------------------------------------------------------------------------

test('Legacy plaintext artifacts pass through without error', async () => {
  const legacyArtifact = {
    artifact_id: 'art_legacy_100',
    name: 'architecture-diagram.md',
    description: 'System deployment topology for production clusters',
    content: '# Architecture Overview\nAll services connect via mTLS.',
    kind: 'markdown',
    mime: 'text/markdown',
    ext: '.md',
    size_bytes: 1024,
  };

  const unlockedDecrypted = await decryptArtifactRecord(legacyArtifact, TEST_KEY_HEX);
  assert.strictEqual(unlockedDecrypted.name, legacyArtifact.name);
  assert.strictEqual(unlockedDecrypted.description, legacyArtifact.description);
  assert.strictEqual(unlockedDecrypted.content, legacyArtifact.content);
  assert.strictEqual(unlockedDecrypted.kind, 'markdown');

  const lockedDecrypted = await decryptArtifactRecord(legacyArtifact, null);
  assert.strictEqual(lockedDecrypted.name, legacyArtifact.name);
  assert.strictEqual(lockedDecrypted.description, legacyArtifact.description);
  assert.strictEqual(lockedDecrypted.content, legacyArtifact.content);

  const plainText = 'Direct plaintext content string';
  assert.strictEqual(await decryptArtifactText(plainText, TEST_KEY_HEX), plainText);
  assert.strictEqual(await decryptArtifactText(plainText, null), plainText);
});

// -----------------------------------------------------------------------------
// Test 3: Locked vault behavior preserves armored ciphertext safely
// -----------------------------------------------------------------------------

test('Locked vault preserves armored strings without errors', async () => {
  const plaintext = 'Sensitive deployment plan artifact';
  const armored = await encryptVaultText(plaintext, TEST_KEY_HEX);

  assert.ok(isVaultArmored(armored));
  assert.ok(armored.startsWith(VAULT_ARMOR_PREFIX));

  // Without key (locked vault):
  const lockedRecord = await decryptArtifactRecord(
    { name: armored, description: armored, content: armored },
    null,
  );
  assert.strictEqual(lockedRecord.name, armored);
  assert.strictEqual(lockedRecord.description, armored);
  assert.strictEqual(lockedRecord.content, armored);

  const lockedText = await decryptArtifactText(armored, null);
  assert.strictEqual(lockedText, armored);
});

// -----------------------------------------------------------------------------
// Test 4: encryptArtifactFields encrypts name, description, and content into vault:v2:e1:...
// -----------------------------------------------------------------------------

test('encryptArtifactFields encrypts name, description, and content into vault:v2:e1:<base64> when unlocked', async () => {
  const payload = {
    name: 'security-audit-report.md',
    description: 'Comprehensive pen-test report for authentication gateway',
    content: '# Pen Test Findings\nZero high-severity vulnerabilities found.',
    kind: 'markdown',
    mime: 'text/markdown',
    ext: '.md',
    project_id: 'proj_alpha_99',
    size_bytes: 2048,
  };

  const encrypted = await encryptArtifactFields(payload, TEST_KEY_HEX);

  // Metadata preserved in plaintext
  assert.strictEqual(encrypted.kind, 'markdown');
  assert.strictEqual(encrypted.mime, 'text/markdown');
  assert.strictEqual(encrypted.ext, '.md');
  assert.strictEqual(encrypted.project_id, 'proj_alpha_99');
  assert.strictEqual(encrypted.size_bytes, 2048);

  // Name, description, and content must be encrypted
  assert.notStrictEqual(encrypted.name, payload.name);
  assert.ok(isVaultArmored(encrypted.name), 'name must be armored');

  assert.notStrictEqual(encrypted.description, payload.description);
  assert.ok(isVaultArmored(encrypted.description), 'description must be armored');

  assert.notStrictEqual(encrypted.content, payload.content);
  assert.ok(isVaultArmored(encrypted.content), 'content must be armored');

  // contentBase64 is generated containing the armored ciphertext
  assert.ok(encrypted.contentBase64, 'contentBase64 must be populated');
  const decodedBase64 = new TextDecoder().decode(base64ToBytes(encrypted.contentBase64));
  assert.strictEqual(decodedBase64, encrypted.content);

  // Idempotency: re-encrypting should not double-encrypt
  const reEncrypted = await encryptArtifactFields(encrypted, TEST_KEY_HEX);
  assert.strictEqual(reEncrypted.name, encrypted.name);
  assert.strictEqual(reEncrypted.description, encrypted.description);
  assert.strictEqual(reEncrypted.content, encrypted.content);
});

// -----------------------------------------------------------------------------
// Test 5: Full round-trip encryption and decryption of Artifact records
// -----------------------------------------------------------------------------

test('Full round-trip encryption and decryption of Artifact records', async () => {
  const original = {
    artifact_id: 'art_roundtrip_456',
    name: 'database-migration-spec.sql',
    description: 'Schema definition for user credentials table',
    content: 'CREATE TABLE secret_tokens (id TEXT PRIMARY KEY, key_hash TEXT NOT NULL);',
    kind: 'sql',
    mime: 'text/x-sql',
    ext: '.sql',
    project_id: 'proj_core_01',
  };

  // 1. Encrypt
  const encrypted = await encryptArtifactFields(original, TEST_KEY_HEX);
  assert.ok(isVaultArmored(encrypted.name));
  assert.ok(isVaultArmored(encrypted.description));
  assert.ok(isVaultArmored(encrypted.content));

  // 2. Decrypt with correct key
  const decrypted = await decryptArtifactRecord(encrypted, TEST_KEY_HEX);
  assert.strictEqual(decrypted.name, original.name);
  assert.strictEqual(decrypted.description, original.description);
  assert.strictEqual(decrypted.content, original.content);
  assert.strictEqual(decrypted.artifact_id, original.artifact_id);
  assert.strictEqual(decrypted.kind, original.kind);
  assert.strictEqual(decrypted.project_id, original.project_id);

  // 3. Decrypt content text directly
  const decryptedContent = await decryptArtifactText(encrypted.content, TEST_KEY_HEX);
  assert.strictEqual(decryptedContent, original.content);
});

// -----------------------------------------------------------------------------
// Test 6: Partial payloads and base64 content encryption
// -----------------------------------------------------------------------------

test('encryptArtifactFields handles contentBase64 when content string is omitted', async () => {
  const rawText = 'SELECT * FROM confidential_logs WHERE level = "CRITICAL";';
  const utf8Base64 = bytesToBase64(new TextEncoder().encode(rawText));

  const payload = {
    name: 'query.sql',
    contentBase64: utf8Base64,
  };

  const encrypted = await encryptArtifactFields(payload, TEST_KEY_HEX);
  assert.ok(isVaultArmored(encrypted.name));
  assert.ok(isVaultArmored(encrypted.content));

  const decryptedFromContent = await decryptVaultText(encrypted.content!, TEST_KEY_HEX);
  assert.strictEqual(decryptedFromContent, rawText);

  // contentBase64 should decode to the armored string
  const armoredFromBase64 = new TextDecoder().decode(base64ToBytes(encrypted.contentBase64!));
  assert.strictEqual(armoredFromBase64, encrypted.content);
});
