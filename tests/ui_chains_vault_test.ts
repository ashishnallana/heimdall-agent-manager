// REQ-VAULT-CHAINS-1: Unit Tests for Task Chains Zero-Knowledge Encryption, Decryption,
// UI Integration, and Generic Reusable Components.
//
// RUN: node --test tests/ui_chains_vault_test.ts

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
  encryptChainFields,
  decryptChainRecord,
  decryptChainList,
} from '../src/ui/utils/vaultChains.ts';

const TEST_KEY_HEX_RAW = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const TEST_KEY_HEX = await keyringFromHex(TEST_KEY_HEX_RAW);

// -----------------------------------------------------------------------------
// Test 1: encryptChainFields encrypts title and description when unlocked
// -----------------------------------------------------------------------------

test('encryptChainFields encrypts title and description when vault key is provided', async () => {
  const plainChain = {
    title: 'Zero-Knowledge Task Chain Integration',
    description: 'This description contains sensitive architecture plans and credentials.',
    kind: 'team_work',
    status: 'active',
  };

  const encrypted = await encryptChainFields(plainChain, TEST_KEY_HEX);

  assert.ok(isVaultArmored(encrypted.title), 'Chain title must have vault:v2:e1: armor');
  assert.ok(isVaultArmored(encrypted.description), 'Chain description must have vault:v2:e1: armor');
  assert.notEqual(encrypted.title, plainChain.title);
  assert.notEqual(encrypted.description, plainChain.description);
  assert.equal(encrypted.kind, 'team_work');
  assert.equal(encrypted.status, 'active');

  // Re-encrypting already-armored fields must be idempotent (no double encryption)
  const doubleEncrypted = await encryptChainFields(encrypted, TEST_KEY_HEX);
  assert.equal(doubleEncrypted.title, encrypted.title, 'Must not double-armor title');
  assert.equal(doubleEncrypted.description, encrypted.description, 'Must not double-armor description');
});

test('encryptChainFields leaves plaintext intact when no vault key is provided', async () => {
  const plainChain = {
    title: 'Public Community Documentation',
    description: 'Public description with no sensitive data.',
    kind: 'team_work',
  };

  const unencrypted = await encryptChainFields(plainChain, null);
  assert.equal(unencrypted.title, plainChain.title);
  assert.equal(unencrypted.description, plainChain.description);
  assert.equal(isVaultArmored(unencrypted.title), false);
  assert.equal(isVaultArmored(unencrypted.description), false);
});

// -----------------------------------------------------------------------------
// Test 3: decryptChainRecord decrypts title and description with correct key
// -----------------------------------------------------------------------------

test('decryptChainRecord decrypts armored title and description when unlocked', async () => {
  const origTitle = 'Feature: Secure Enclave Deployment';
  const origDesc = '# Deployment Steps\n1. Generate keys\n2. Attest enclave';

  const armoredTitle = await encryptVaultText(origTitle, TEST_KEY_HEX);
  const armoredDesc = await encryptVaultText(origDesc, TEST_KEY_HEX);

  const chainRecord = {
    chain_id: 'chain_test_123',
    title: armoredTitle,
    description: armoredDesc,
    description_preview: armoredTitle,
    status: 'active',
  };

  const decrypted = await decryptChainRecord(chainRecord, TEST_KEY_HEX);

  assert.equal(decrypted.title, origTitle);
  assert.equal(decrypted.description, origDesc);
  assert.equal(decrypted.description_preview, origTitle);
  assert.equal(decrypted.status, 'active');
});

test('decryptChainRecord preserves armored string when vault is locked or key is missing', async () => {
  const armoredTitle = await encryptVaultText('Secret chain title', TEST_KEY_HEX);
  const armoredDesc = await encryptVaultText('Secret chain description', TEST_KEY_HEX);

  const chainRecord = {
    chain_id: 'chain_test_456',
    title: armoredTitle,
    description: armoredDesc,
    status: 'active',
  };

  const preserved = await decryptChainRecord(chainRecord, null);

  assert.equal(preserved.title, armoredTitle, 'Armored title must be preserved intact');
  assert.equal(preserved.description, armoredDesc, 'Armored description must be preserved intact');
});

// -----------------------------------------------------------------------------
// Test 4: Legacy plaintext chains render transparently without regression
// -----------------------------------------------------------------------------

test('decryptChainRecord and resolveVaultText handle legacy plaintext chains transparently', async () => {
  const legacyChain = {
    chain_id: 'chain_legacy_789',
    title: 'Migrate legacy database schema',
    description: 'Plain markdown description from before vault encryption was introduced.',
    status: 'completed',
  };

  // Even with a vault key present, plaintext should remain unchanged
  const decrypted = await decryptChainRecord(legacyChain, TEST_KEY_HEX);
  assert.equal(decrypted.title, legacyChain.title);
  assert.equal(decrypted.description, legacyChain.description);

  // resolveVaultText returns plaintext mode
  const titleResolved = resolveVaultText(legacyChain.title, true);
  assert.equal(titleResolved.mode, 'plaintext');
  assert.equal(titleResolved.isArmored, false);
  assert.equal(titleResolved.displayText, legacyChain.title);

  const descResolved = resolveVaultText(legacyChain.description, false);
  assert.equal(descResolved.mode, 'plaintext');
  assert.equal(descResolved.isArmored, false);
  assert.equal(descResolved.displayText, legacyChain.description);
});

// -----------------------------------------------------------------------------
// Test 5: decryptChainList decrypts array of chain records
// -----------------------------------------------------------------------------

test('decryptChainList decrypts arrays containing mixed encrypted and legacy chains', async () => {
  const encTitle1 = await encryptVaultText('Encrypted Chain Alpha', TEST_KEY_HEX);
  const encDesc1 = await encryptVaultText('Description Alpha', TEST_KEY_HEX);

  const encTitle2 = await encryptVaultText('Encrypted Chain Beta', TEST_KEY_HEX);
  const encDesc2 = await encryptVaultText('Description Beta', TEST_KEY_HEX);

  const chains = [
    { chain_id: 'c1', title: encTitle1, description: encDesc1 },
    { chain_id: 'c2', title: 'Unencrypted Legacy Chain Gamma', description: 'Legacy Plain Desc' },
    { chain_id: 'c3', title: encTitle2, description: encDesc2 },
  ];

  const decryptedList = await decryptChainList(chains, TEST_KEY_HEX);

  assert.equal(decryptedList.length, 3);
  assert.equal(decryptedList[0].title, 'Encrypted Chain Alpha');
  assert.equal(decryptedList[0].description, 'Description Alpha');
  assert.equal(decryptedList[1].title, 'Unencrypted Legacy Chain Gamma');
  assert.equal(decryptedList[1].description, 'Legacy Plain Desc');
  assert.equal(decryptedList[2].title, 'Encrypted Chain Beta');
  assert.equal(decryptedList[2].description, 'Description Beta');
});

// -----------------------------------------------------------------------------
// Test 6: Redux vault state transitions and interactive locked placeholder
// -----------------------------------------------------------------------------

test('Vault locked state displays interactive placeholder and triggers unlock modal', async () => {
  const armoredTitle = await encryptVaultText('Classified Chain Title', TEST_KEY_HEX);

  // Locked resolution
  const lockedResolved = resolveVaultText(armoredTitle, false);
  assert.equal(lockedResolved.mode, 'locked');
  assert.equal(lockedResolved.isLocked, true);
  assert.equal(lockedResolved.dataDebugId, 'vault-locked-placeholder');
  assert.equal(lockedResolved.displayText, 'Encrypted content');

  // Unlocked resolution
  const unlockedResolved = resolveVaultText(armoredTitle, true);
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
