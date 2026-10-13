// REQ-VAULT-MEMORIES-1: Unit Tests for Memories UI Zero-Knowledge Encryption, Decryption,
// and Reusable VaultText Integration.
//
// RUN: node --test tests/ui_memories_vault_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  isVaultArmored,
  encryptVaultText,
  VAULT_ARMOR_PREFIX,
} from '../src/ui/utils/vaultContent.ts';
import {
  resolveVaultText,
} from '../src/ui/components/vault/vaultTextHelper.ts';
import {
  encryptMemoryFields,
  decryptMemoryRecord,
} from '../src/ui/utils/vaultMemories.ts';

const TEST_KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const DIFFERENT_KEY_HEX = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

// -----------------------------------------------------------------------------
// Test 1: <VaultText /> resolution for plaintext and legacy unencrypted memories
// -----------------------------------------------------------------------------

test('VaultText helper handles plaintext and legacy unencrypted memories without changes', () => {
  const legacyTitle = 'Project convention: always use Odin collections';
  const resolved = resolveVaultText(legacyTitle, false);
  assert.equal(resolved.mode, 'plaintext');
  assert.equal(resolved.isArmored, false);
  assert.equal(resolved.displayText, legacyTitle);
  assert.equal(resolved.isLocked, false);
  assert.equal(resolved.dataDebugId, undefined);

  // Empty fallback string
  const resolvedEmpty = resolveVaultText('', false, 'No memory details');
  assert.equal(resolvedEmpty.mode, 'plaintext');
  assert.equal(resolvedEmpty.displayText, 'No memory details');
});

// -----------------------------------------------------------------------------
// Test 3: <VaultText /> locked placeholder resolution for armored memory content
// -----------------------------------------------------------------------------

test('VaultText helper renders locked placeholder with data-debug-id for armored memory content', async () => {
  const secretBody = 'Internal infrastructure secret token: gcloud_auth_xyz123';
  const armoredBody = await encryptVaultText(secretBody, TEST_KEY_HEX);
  assert.ok(isVaultArmored(armoredBody), 'Must produce valid armored ciphertext');

  // Vault is locked
  const resolvedLocked = resolveVaultText(armoredBody, false);
  assert.equal(resolvedLocked.mode, 'locked');
  assert.equal(resolvedLocked.isArmored, true);
  assert.equal(resolvedLocked.isLocked, true);
  assert.equal(resolvedLocked.dataDebugId, 'vault-locked-placeholder');
  assert.equal(resolvedLocked.displayText, 'Encrypted content');
});

// -----------------------------------------------------------------------------
// Test 4: Memory field encryption encrypts title, description, body, evidence when unlocked
// -----------------------------------------------------------------------------

test('encryptMemoryFields encrypts title, description, body, evidence into "vault:v1:<base64>" when vault is unlocked', async () => {
  const rawMemoryPayload = {
    title: 'Secret architectural rule: do not call external API directly',
    description: 'Guidelines for secure outbound network calls from agents',
    body: 'Always route requests through internal proxy: http://proxy.internal:8080 with auth token secret_abc',
    evidence: 'Incident response log incident_9981: raw token leaked to stdout',
    type: 'rule',
    status: 'approved',
    agentIds: ['agt_worker1'],
    projectIds: ['proj_secret'],
    bridgeIds: [],
    templateIds: [],
  };

  // 1. Unlocked vault with valid 256-bit key
  const encrypted = await encryptMemoryFields(rawMemoryPayload, TEST_KEY_HEX);

  // Content fields must be armored
  assert.ok(isVaultArmored(encrypted.title), 'Title must be armored');
  assert.ok(isVaultArmored(encrypted.description), 'Description must be armored');
  assert.ok(isVaultArmored(encrypted.body), 'Body must be armored');
  assert.ok(isVaultArmored(encrypted.evidence), 'Evidence must be armored');

  assert.ok(encrypted.title!.startsWith(VAULT_ARMOR_PREFIX));
  assert.ok(encrypted.description!.startsWith(VAULT_ARMOR_PREFIX));
  assert.ok(encrypted.body!.startsWith(VAULT_ARMOR_PREFIX));
  assert.ok(encrypted.evidence!.startsWith(VAULT_ARMOR_PREFIX));

  // Plaintext must not leak into ciphertext
  assert.ok(!encrypted.title!.includes('Secret architectural rule'));
  assert.ok(!encrypted.description!.includes('Guidelines'));
  assert.ok(!encrypted.body!.includes('http://proxy.internal'));
  assert.ok(!encrypted.body!.includes('secret_abc'));
  assert.ok(!encrypted.evidence!.includes('incident_9981'));

  // Metadata / targeting dimensions must remain strictly plaintext
  assert.equal(encrypted.type, 'rule');
  assert.equal(encrypted.status, 'approved');
  assert.deepEqual(encrypted.agentIds, ['agt_worker1']);
  assert.deepEqual(encrypted.projectIds, ['proj_secret']);
  assert.deepEqual(encrypted.bridgeIds, []);
  assert.deepEqual(encrypted.templateIds, []);

  // 2. Locked vault (null key) preserves plaintext
  const unencrypted = await encryptMemoryFields(rawMemoryPayload, null);
  assert.equal(unencrypted.title, rawMemoryPayload.title);
  assert.equal(unencrypted.description, rawMemoryPayload.description);
  assert.equal(unencrypted.body, rawMemoryPayload.body);
  assert.equal(unencrypted.evidence, rawMemoryPayload.evidence);

  // 3. Idempotency: already armored fields must not be double encrypted
  const alreadyArmored = await encryptMemoryFields(encrypted, TEST_KEY_HEX);
  assert.equal(alreadyArmored.title, encrypted.title);
  assert.equal(alreadyArmored.description, encrypted.description);
  assert.equal(alreadyArmored.body, encrypted.body);
  assert.equal(alreadyArmored.evidence, encrypted.evidence);
});

// -----------------------------------------------------------------------------
// Test 5: Full round-trip encryption, decryption, and transformation of Memory records
// -----------------------------------------------------------------------------

test('Full round-trip encryption and decryption of Memory records', async () => {
  const originalTitle = 'Git rebase conflict avoidance pattern';
  const originalDescription = 'Best practices for keeping worker branch in sync';
  const originalBody = 'Run git fetch origin main && git rebase -X theirs carefully before pushing.';
  const originalEvidence = 'Applied in commit abcdef123 during PR validation.';

  const rawMemory = {
    id: 'mem_123456',
    memory_id: 'mem_123456',
    title: originalTitle,
    description: originalDescription,
    body: originalBody,
    evidence: originalEvidence,
    type: 'fact',
    status: 'active',
    owner_user_id: 'usr_admin',
    created_at: '2026-09-25T14:00:00Z',
  };

  // Encrypt fields
  const encryptedMemory = await encryptMemoryFields(rawMemory, TEST_KEY_HEX);
  assert.ok(isVaultArmored(encryptedMemory.title));
  assert.ok(isVaultArmored(encryptedMemory.description));
  assert.ok(isVaultArmored(encryptedMemory.body));
  assert.ok(isVaultArmored(encryptedMemory.evidence));

  // Decrypt with correct key
  const decryptedMemory = await decryptMemoryRecord(encryptedMemory, TEST_KEY_HEX);
  assert.equal(decryptedMemory.title, originalTitle);
  assert.equal(decryptedMemory.description, originalDescription);
  assert.equal(decryptedMemory.body, originalBody);
  assert.equal(decryptedMemory.evidence, originalEvidence);
  assert.equal(decryptedMemory.id, 'mem_123456');
  assert.equal(decryptedMemory.type, 'fact');
  assert.equal(decryptedMemory.status, 'active');

  // Locked vault (null key) leaves armored fields intact
  const lockedMemory = await decryptMemoryRecord(encryptedMemory, null);
  assert.equal(lockedMemory.title, encryptedMemory.title);
  assert.equal(lockedMemory.body, encryptedMemory.body);

  // Decrypt with incorrect key fails gracefully (leaves original armored string or does not throw)
  const wrongKeyMemory = await decryptMemoryRecord(encryptedMemory, DIFFERENT_KEY_HEX);
  assert.equal(wrongKeyMemory.title, encryptedMemory.title);
  assert.equal(wrongKeyMemory.body, encryptedMemory.body);
});

// -----------------------------------------------------------------------------
// Test 6: Partial memory updates encrypt only provided content fields
// -----------------------------------------------------------------------------

test('encryptMemoryFields handles partial payloads with omitted fields', async () => {
  const partialPayload = {
    title: 'Only updating title',
  };

  const encrypted = await encryptMemoryFields(partialPayload, TEST_KEY_HEX);
  assert.ok(isVaultArmored(encrypted.title));
  assert.equal(encrypted.body, undefined);
  assert.equal(encrypted.description, undefined);
  assert.equal(encrypted.evidence, undefined);

  const decrypted = await decryptMemoryRecord(encrypted, TEST_KEY_HEX);
  assert.equal(decrypted.title, 'Only updating title');
  assert.equal(decrypted.body, undefined);
});
