// REQ-VAULT-SIDEBAR-PROJECTS, REQ-VAULT-FILES-PANEL, REQ-VAULT-ARTIFACTS-LIBRARY, REQ-VAULT-PROJECT-LAUNCH, REQ-VAULT-TAGS-INVALIDATE
// Unit tests verifying Vault decryption and VaultText wrapping across Sidebar project tree,
// Files panel, Library, Launch modal, Action items tab, and RTK Query tag invalidation.
//
// RUN: node --test tests/ui_vault_sidebar_and_files_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  isVaultArmored,
  encryptVaultText,
  decryptVaultText,
} from '../src/ui/utils/vaultContent.ts';
import {
  decryptProjectRecord,
  decryptProjectList,
  encryptProjectFields,
} from '../src/ui/utils/vaultProjects.ts';

const TEST_KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

// -----------------------------------------------------------------------------
// Section 2: Behavioral & Cryptographic Decryption Verification
// -----------------------------------------------------------------------------

test('Behavioral: Project record and list encryption & decryption round-trip', async () => {
  const rawProject = {
    project_id: 'proj_secret_123',
    name: 'Top Secret Alpha',
    description: 'Internal confidential engineering project',
    default_path: '/home/tanmay/repo',
  };

  // Encrypt project fields
  const encrypted = await encryptProjectFields(rawProject, TEST_KEY_HEX);
  assert.ok(isVaultArmored(encrypted.name), 'Encrypted project name must be armored');
  assert.ok(isVaultArmored(encrypted.description), 'Encrypted project description must be armored');
  assert.equal(encrypted.project_id, rawProject.project_id, 'Project ID must remain plaintext');
  assert.equal(encrypted.default_path, rawProject.default_path, 'Default path must remain plaintext');

  // Decrypt single record
  const decryptedRecord = await decryptProjectRecord(encrypted, TEST_KEY_HEX);
  assert.equal(decryptedRecord.name, rawProject.name);
  assert.equal(decryptedRecord.description, rawProject.description);

  // Decrypt project list
  const list = [encrypted, { project_id: 'proj_plain', name: 'Plain Public Project' }];
  const decryptedList = await decryptProjectList(list, TEST_KEY_HEX);
  assert.equal(decryptedList.length, 2);
  assert.equal(decryptedList[0].name, 'Top Secret Alpha');
  assert.equal(decryptedList[1].name, 'Plain Public Project');

  // Decrypt without key (graceful fallback preserves armor or leaves as is)
  const lockedList = await decryptProjectList(list, null);
  assert.equal(lockedList[0].name, encrypted.name, 'When locked without key, leaves armored text as-is');
  assert.equal(lockedList[1].name, 'Plain Public Project');
});
