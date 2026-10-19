// REQ-VAULT-PROJECTS-1: Unit Tests for Projects Zero-Knowledge Encryption, Decryption,
// UI Integration, and Generic Reusable Components.
//
// RUN: node --test tests/ui_projects_vault_test.ts

import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  isVaultArmored,
  encryptVaultText,
} from '../src/ui/utils/vaultContent.ts';
import vaultReducer, {
  keyringInstalled,
  keyringCleared,
  selectIsVaultUnlocked,
} from '../src/ui/store/vaultSlice.ts';
import {
  resolveVaultText,
} from '../src/ui/components/vault/vaultTextHelper.ts';
import {
  encryptProjectFields,
  decryptProjectRecord,
  decryptProjectList,
} from '../src/ui/utils/vaultProjects.ts';

const TEST_KEY_HEX_RAW = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const TEST_KEY_HEX = await keyringFromHex(TEST_KEY_HEX_RAW);

// -----------------------------------------------------------------------------
// Test 1: encryptProjectFields encrypts name and description when unlocked
// -----------------------------------------------------------------------------

test('encryptProjectFields encrypts name and description when vault key is provided', async () => {
  const plainProject = {
    name: 'Confidential Production Infrastructure',
    description: 'Contains sensitive deployment credentials and cluster architecture.',
    slug: 'prod-infra',
    repo_url: 'git@github.com:example/infra.git',
    vcs_kind: 'git',
    default_path: '/opt/infra',
  };

  const encrypted = await encryptProjectFields(plainProject, TEST_KEY_HEX);

  assert.ok(isVaultArmored(encrypted.name), 'Project name must have vault:v2:7e57000000000001:e1: armor');
  assert.ok(isVaultArmored(encrypted.description), 'Project description must have vault:v2:7e57000000000001:e1: armor');
  assert.notEqual(encrypted.name, plainProject.name);
  assert.notEqual(encrypted.description, plainProject.description);
  assert.equal(encrypted.slug, 'prod-infra');
  assert.equal(encrypted.repo_url, 'git@github.com:example/infra.git');
  assert.equal(encrypted.vcs_kind, 'git');
  assert.equal(encrypted.default_path, '/opt/infra');

  // Re-encrypting already-armored fields must be idempotent (no double encryption)
  const doubleEncrypted = await encryptProjectFields(encrypted, TEST_KEY_HEX);
  assert.equal(doubleEncrypted.name, encrypted.name, 'Must not double-armor name');
  assert.equal(doubleEncrypted.description, encrypted.description, 'Must not double-armor description');
});

test('encryptProjectFields leaves plaintext intact when no vault key is provided', async () => {
  const plainProject = {
    name: 'Public Open Source Project',
    description: 'Public documentation and open repositories.',
    slug: 'public-repo',
  };

  const unencrypted = await encryptProjectFields(plainProject, null);
  assert.equal(unencrypted.name, plainProject.name);
  assert.equal(unencrypted.description, plainProject.description);
  assert.equal(isVaultArmored(unencrypted.name), false);
  assert.equal(isVaultArmored(unencrypted.description), false);
});

// -----------------------------------------------------------------------------
// Test 3: decryptProjectRecord decrypts name and description with correct key
// -----------------------------------------------------------------------------

test('decryptProjectRecord decrypts armored name and description when unlocked', async () => {
  const origName = 'Classified Core Engine';
  const origDesc = '# Architecture\nSensitive internal routing and tokens.';

  const armoredName = await encryptVaultText(origName, TEST_KEY_HEX);
  const armoredDesc = await encryptVaultText(origDesc, TEST_KEY_HEX);

  const projectRecord = {
    projectId: 'proj_test_123',
    name: armoredName,
    description: armoredDesc,
    slug: 'classified-core',
    vcsKind: 'git',
  };

  const decrypted = await decryptProjectRecord(projectRecord, TEST_KEY_HEX);

  assert.equal(decrypted.name, origName);
  assert.equal(decrypted.description, origDesc);
  assert.equal(decrypted.slug, 'classified-core');
  assert.equal(decrypted.projectId, 'proj_test_123');
});

test('decryptProjectRecord preserves armored string when vault is locked or key is missing', async () => {
  const armoredName = await encryptVaultText('Secret project name', TEST_KEY_HEX);
  const armoredDesc = await encryptVaultText('Secret project description', TEST_KEY_HEX);

  const projectRecord = {
    projectId: 'proj_test_456',
    name: armoredName,
    description: armoredDesc,
  };

  const preserved = await decryptProjectRecord(projectRecord, null);

  assert.equal(preserved.name, armoredName, 'Armored name must be preserved intact');
  assert.equal(preserved.description, armoredDesc, 'Armored description must be preserved intact');
});

// -----------------------------------------------------------------------------
// Test 4: Legacy plaintext projects render transparently without regression
// -----------------------------------------------------------------------------

test('decryptProjectRecord and resolveVaultText handle legacy plaintext projects transparently', async () => {
  const legacyProject = {
    projectId: 'proj_legacy_789',
    name: 'Legacy Project Frontend',
    description: 'Plain markdown description from before vault encryption was introduced.',
  };

  // Even with a vault key present, plaintext should remain unchanged
  const decrypted = await decryptProjectRecord(legacyProject, TEST_KEY_HEX);
  assert.equal(decrypted.name, legacyProject.name);
  assert.equal(decrypted.description, legacyProject.description);

  // resolveVaultText returns plaintext mode
  const nameResolved = resolveVaultText(legacyProject.name, true);
  assert.equal(nameResolved.mode, 'plaintext');
  assert.equal(nameResolved.isArmored, false);
  assert.equal(nameResolved.displayText, legacyProject.name);

  const descResolved = resolveVaultText(legacyProject.description, false);
  assert.equal(descResolved.mode, 'plaintext');
  assert.equal(descResolved.isArmored, false);
  assert.equal(descResolved.displayText, legacyProject.description);
});

// -----------------------------------------------------------------------------
// Test 5: decryptProjectList decrypts array of project records
// -----------------------------------------------------------------------------

test('decryptProjectList decrypts arrays containing mixed encrypted and legacy projects', async () => {
  const encName1 = await encryptVaultText('Encrypted Project Alpha', TEST_KEY_HEX);
  const encDesc1 = await encryptVaultText('Description Alpha', TEST_KEY_HEX);

  const encName2 = await encryptVaultText('Encrypted Project Beta', TEST_KEY_HEX);
  const encDesc2 = await encryptVaultText('Description Beta', TEST_KEY_HEX);

  const projects = [
    { projectId: 'p1', name: encName1, description: encDesc1 },
    { projectId: 'p2', name: 'Unencrypted Legacy Project Gamma', description: 'Legacy Plain Desc' },
    { projectId: 'p3', name: encName2, description: encDesc2 },
  ];

  const decryptedList = await decryptProjectList(projects, TEST_KEY_HEX);

  assert.equal(decryptedList.length, 3);
  assert.equal(decryptedList[0].name, 'Encrypted Project Alpha');
  assert.equal(decryptedList[0].description, 'Description Alpha');
  assert.equal(decryptedList[1].name, 'Unencrypted Legacy Project Gamma');
  assert.equal(decryptedList[1].description, 'Legacy Plain Desc');
  assert.equal(decryptedList[2].name, 'Encrypted Project Beta');
  assert.equal(decryptedList[2].description, 'Description Beta');
});

// -----------------------------------------------------------------------------
// Test 6: Redux vault state transitions and interactive locked placeholder
// -----------------------------------------------------------------------------

test('Vault locked state displays interactive placeholder and triggers unlock modal for project fields', async () => {
  const armoredName = await encryptVaultText('Classified Project Name', TEST_KEY_HEX);

  // Locked resolution
  const lockedResolved = resolveVaultText(armoredName, false);
  assert.equal(lockedResolved.mode, 'locked');
  assert.equal(lockedResolved.isLocked, true);
  assert.equal(lockedResolved.dataDebugId, 'vault-locked-placeholder');
  assert.equal(lockedResolved.displayText, 'Encrypted content');

  // Unlocked resolution
  const unlockedResolved = resolveVaultText(armoredName, true);
  assert.equal(unlockedResolved.mode, 'unlocked');
  assert.equal(unlockedResolved.isLocked, false);

  // Redux state transitions: keyring installed / purged; no key material in state
  let state = vaultReducer(undefined, { type: '@@INIT' });
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
  state = vaultReducer(state, keyringInstalled({ currentEpoch: 1 }));
  assert.equal(selectIsVaultUnlocked({ vault: state }), true);
  assert.deepEqual(Object.keys(state).sort(), ['currentEpoch', 'isUnlocked']);
  state = vaultReducer(state, keyringCleared());
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
});
