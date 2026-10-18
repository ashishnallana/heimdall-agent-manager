// REQ-VAULT-ISSUES-UI-1: Unit Tests for Issues UI Zero-Knowledge Encryption, Decryption,
// and Reusable VaultText Component.
//
// RUN: node --test tests/ui_issues_vault_test.ts

import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  isVaultArmored,
  encryptVaultText,
  decryptVaultText,
  VAULT_ARMOR_PREFIX,
} from '../src/ui/utils/vaultContent.ts';
import vaultReducer, {
  setVaultUnlocked,
  lockVault,
  openUnlockModal,
  closeUnlockModal,
  setUnlockModalOpen,
  selectIsVaultUnlocked,
  selectIsUnlockModalOpen,
} from '../src/ui/store/vaultSlice.ts';
import {
  resolveVaultText,
  decryptVaultTextContent,
} from '../src/ui/components/vault/vaultTextHelper.ts';
import {
  encryptIssueFields,
  encryptCommentFields,
  decryptIssueRecord,
  decryptCommentRecord,
} from '../src/ui/utils/vaultIssues.ts';

const TEST_KEY_HEX_RAW = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const TEST_KEY_HEX = await keyringFromHex(TEST_KEY_HEX_RAW);
const DIFFERENT_KEY_HEX_RAW = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
const DIFFERENT_KEY_HEX = await keyringFromHex(DIFFERENT_KEY_HEX_RAW);

// -----------------------------------------------------------------------------
// Test 1: <VaultText /> renders plaintext for unencrypted strings
// -----------------------------------------------------------------------------

test('<VaultText /> renders plaintext for unencrypted strings and empty fallbacks', () => {
  // Plain text resolution
  const resolved = resolveVaultText('Bug: Odin build failure on arm64', false);
  assert.equal(resolved.mode, 'plaintext');
  assert.equal(resolved.isArmored, false);
  assert.equal(resolved.displayText, 'Bug: Odin build failure on arm64');
  assert.equal(resolved.isLocked, false);
  assert.equal(resolved.dataDebugId, undefined);

  // Empty string with fallback
  const resolvedEmpty = resolveVaultText('', false, 'No content provided');
  assert.equal(resolvedEmpty.mode, 'plaintext');
  assert.equal(resolvedEmpty.displayText, 'No content provided');
});

// -----------------------------------------------------------------------------
// Test 2: <VaultText /> renders interactive placeholder when vault is locked and triggers unlock
// -----------------------------------------------------------------------------

test('<VaultText /> renders interactive placeholder when vault is locked with data-debug-id="vault-locked-placeholder"', async () => {
  // Generate an armored string
  const armoredCiphertext = await encryptVaultText('Sensitive secret issue content', TEST_KEY_HEX);
  assert.ok(isVaultArmored(armoredCiphertext), 'Must produce valid armored ciphertext');

  // When vault is locked
  const resolvedLocked = resolveVaultText(armoredCiphertext, false);
  assert.equal(resolvedLocked.mode, 'locked');
  assert.equal(resolvedLocked.isArmored, true);
  assert.equal(resolvedLocked.isLocked, true);
  assert.equal(resolvedLocked.dataDebugId, 'vault-locked-placeholder');
  assert.equal(resolvedLocked.displayText, 'Encrypted content');

  // Redux state verification for openUnlockModal
  let state = vaultReducer(undefined, { type: '@@INIT' });
  assert.equal(selectIsUnlockModalOpen({ vault: state }), false);
  state = vaultReducer(state, openUnlockModal());
  assert.equal(selectIsUnlockModalOpen({ vault: state }), true);
});

// -----------------------------------------------------------------------------
// Test 4: <VaultText /> and decryptVaultText decrypt plaintext when vault is unlocked
// -----------------------------------------------------------------------------

test('<VaultText /> decrypts and renders plaintext when vault is unlocked', async () => {
  const secretTitle = 'Flaky test in bridge process synchronization';
  const armoredTitle = await encryptVaultText(secretTitle, TEST_KEY_HEX);
  assert.ok(isVaultArmored(armoredTitle));

  // Resolved when vault is unlocked
  const resolvedUnlocked = resolveVaultText(armoredTitle, true);
  assert.equal(resolvedUnlocked.mode, 'unlocked');
  assert.equal(resolvedUnlocked.isArmored, true);
  assert.equal(resolvedUnlocked.isLocked, false);

  // Decrypt with correct key
  const decrypted = await decryptVaultText(armoredTitle, TEST_KEY_HEX);
  assert.equal(decrypted, secretTitle, 'Must decrypt cleanly back to original plaintext');

  // Verify helper decryptVaultTextContent
  const contentDecrypted = await decryptVaultTextContent(armoredTitle, TEST_KEY_HEX);
  assert.equal(contentDecrypted, secretTitle);

  // Verify transparent fallback for unarmored string
  const unarmored = 'Plain text not armored';
  const passthrough = await decryptVaultText(unarmored, TEST_KEY_HEX);
  assert.equal(passthrough, unarmored, 'Unarmored string must pass through without modification');

  // Verify failure on wrong key
  await assert.rejects(
    async () => {
      await decryptVaultText(armoredTitle, DIFFERENT_KEY_HEX);
    },
    /operation failed|tag mismatch|decrypt/i,
    'Decryption with incorrect key must reject',
  );
});

// -----------------------------------------------------------------------------
// Test 5: Issue creation encrypts title and description into 'vault:v2:e1:<base64>' when vault is unlocked
// -----------------------------------------------------------------------------

test('Issue creation encrypts title and description into "vault:v2:e1:<base64>" when vault is unlocked', async () => {
  const rawIssuePayload = {
    title: 'Kernel deadlock on sqlite busy timeout',
    description: 'Stack trace details with sensitive environment variables:\nAPI_KEY=secret_123',
    scope_type: 'project',
    target_id: 'proj_cloudtop',
    chain_id: 'chain_18d892527be5e57f',
  };

  // 1. When vault is unlocked with a valid 256-bit key
  const encryptedPayload = await encryptIssueFields(rawIssuePayload, TEST_KEY_HEX);

  // Title and description must be armored
  assert.ok(
    isVaultArmored(encryptedPayload.title),
    'Title must be armored with vault:v2:e1: prefix',
  );
  assert.ok(
    isVaultArmored(encryptedPayload.description),
    'Description must be armored with vault:v2:e1: prefix',
  );
  assert.ok(
    encryptedPayload.title.startsWith(VAULT_ARMOR_PREFIX),
    'Title must start with vault:v2:e1:',
  );
  assert.ok(
    encryptedPayload.description.startsWith(VAULT_ARMOR_PREFIX),
    'Description must start with vault:v2:e1:',
  );

  // Plaintext must not leak into armored payload
  assert.ok(!encryptedPayload.title.includes('Kernel deadlock'));
  assert.ok(!encryptedPayload.description.includes('secret_123'));

  // Non-content fields must remain strictly in plaintext
  assert.equal(encryptedPayload.scope_type, 'project');
  assert.equal(encryptedPayload.target_id, 'proj_cloudtop');
  assert.equal(encryptedPayload.chain_id, 'chain_18d892527be5e57f');

  // 2. When vault is locked (no key provided)
  const unencryptedPayload = await encryptIssueFields(rawIssuePayload, null);
  assert.equal(unencryptedPayload.title, rawIssuePayload.title);
  assert.equal(unencryptedPayload.description, rawIssuePayload.description);

  // 3. Idempotency: already-armored fields are preserved without double-encryption
  const alreadyArmored = await encryptIssueFields(encryptedPayload, TEST_KEY_HEX);
  assert.equal(alreadyArmored.title, encryptedPayload.title);
  assert.equal(alreadyArmored.description, encryptedPayload.description);
});

// -----------------------------------------------------------------------------
// Test 6: Issue comment creation encrypts comment body into 'vault:v2:e1:<base64>' when vault is unlocked
// -----------------------------------------------------------------------------

test('Issue comment creation encrypts comment body into "vault:v2:e1:<base64>" when vault is unlocked', async () => {
  const commentPayload = {
    issueId: 'iss_123',
    body: 'Investigated: reproduction confirmed with gdb stack trace attached.',
    author_id: 'agt_coordinator',
    author_name: 'Coordinator #1',
  };

  // 1. Unlocked vault: encrypts comment body
  const encryptedComment = await encryptCommentFields(commentPayload, TEST_KEY_HEX);
  assert.ok(
    isVaultArmored(encryptedComment.body),
    'Comment body must be armored with vault:v2:e1: prefix',
  );
  assert.ok(
    encryptedComment.body.startsWith(VAULT_ARMOR_PREFIX),
    'Comment body must start with vault:v2:e1:',
  );
  assert.ok(!encryptedComment.body.includes('Investigated'));

  // Author metadata remains unencrypted
  assert.equal(encryptedComment.author_id, 'agt_coordinator');
  assert.equal(encryptedComment.author_name, 'Coordinator #1');

  // 2. Locked vault: preserves plaintext
  const plaintextComment = await encryptCommentFields(commentPayload, null);
  assert.equal(plaintextComment.body, commentPayload.body);
});

// -----------------------------------------------------------------------------
// Test 7: Round-trip encryption and decryption of full Issue record and comments
// -----------------------------------------------------------------------------

test('Full round-trip encryption, decryption, and transformation of Issue records and comments', async () => {
  const originalTitle = 'Odin compilation segfault in arm64 backend';
  const originalDescription = 'Reproduced on Linux 6.6 with llvm-18 toolchain.';
  const comment1Body = 'Confirmed on local dev machine.';
  const comment2Body = 'Fix proposed in PR #42.';

  // Encrypt fields
  const armoredTitle = await encryptVaultText(originalTitle, TEST_KEY_HEX);
  const armoredDescription = await encryptVaultText(originalDescription, TEST_KEY_HEX);
  const armoredComment1 = await encryptVaultText(comment1Body, TEST_KEY_HEX);
  const armoredComment2 = await encryptVaultText(comment2Body, TEST_KEY_HEX);

  const mockIssue = {
    id: 'iss_test_001',
    issueId: 'iss_test_001',
    issue_id: 'iss_test_001',
    ownerUserId: 'usr_tanmay',
    owner_user_id: 'usr_tanmay',
    title: armoredTitle,
    description: armoredDescription,
    descriptionPreview: armoredDescription,
    description_preview: armoredDescription,
    createdBy: 'tanmay',
    created_by: 'tanmay',
    status: 'new',
    scopeType: 'global',
    scope_type: 'global',
    targetId: '',
    target_id: '',
    chainId: 'chain_test',
    chain_id: 'chain_test',
    createdAt: '2026-09-25T12:00:00Z',
    created_at: '2026-09-25T12:00:00Z',
    updatedAt: '2026-09-25T12:00:00Z',
    updated_at: '2026-09-25T12:00:00Z',
    closedAt: '',
    closed_at: '',
    voteCount: 3,
    vote_count: 3,
    commentCount: 2,
    comment_count: 2,
    hasVoted: true,
    has_voted: true,
    comments: [
      {
        id: 'c_1',
        commentId: 'c_1',
        comment_id: 'c_1',
        issueId: 'iss_test_001',
        issue_id: 'iss_test_001',
        ownerUserId: 'usr_tanmay',
        owner_user_id: 'usr_tanmay',
        authorId: 'auth_1',
        author_id: 'auth_1',
        authorName: 'Reviewer',
        author_name: 'Reviewer',
        body: armoredComment1,
        createdAt: '2026-09-25T12:05:00Z',
        created_at: '2026-09-25T12:05:00Z',
        updatedAt: '2026-09-25T12:05:00Z',
        updated_at: '2026-09-25T12:05:00Z',
      },
      {
        id: 'c_2',
        commentId: 'c_2',
        comment_id: 'c_2',
        issueId: 'iss_test_001',
        issue_id: 'iss_test_001',
        ownerUserId: 'usr_tanmay',
        owner_user_id: 'usr_tanmay',
        authorId: 'auth_2',
        author_id: 'auth_2',
        authorName: 'Engineer',
        author_name: 'Engineer',
        body: armoredComment2,
        createdAt: '2026-09-25T12:10:00Z',
        created_at: '2026-09-25T12:10:00Z',
        updatedAt: '2026-09-25T12:10:00Z',
        updated_at: '2026-09-25T12:10:00Z',
      },
    ],
  };

  // Decrypt issue record with correct key
  const decryptedIssue = await decryptIssueRecord(mockIssue, TEST_KEY_HEX);
  assert.equal(decryptedIssue.title, originalTitle);
  assert.equal(decryptedIssue.description, originalDescription);
  assert.equal(decryptedIssue.comments?.[0].body, comment1Body);
  assert.equal(decryptedIssue.comments?.[1].body, comment2Body);
  assert.equal(decryptedIssue.status, 'new');
  assert.equal(decryptedIssue.voteCount, 3);

  // Individual comment decryption
  const decryptedComment = await decryptCommentRecord(mockIssue.comments![0], TEST_KEY_HEX);
  assert.equal(decryptedComment.body, comment1Body);
});

// -----------------------------------------------------------------------------
// Test 8: Redux state transitions for Vault Unlock Modal management
// -----------------------------------------------------------------------------

test('vaultSlice manages isUnlockModalOpen state and auto-resets on unlock and lock', () => {
  let state = vaultReducer(undefined, { type: '@@INIT' });
  assert.equal(selectIsUnlockModalOpen({ vault: state }), false);

  // openUnlockModal
  state = vaultReducer(state, openUnlockModal());
  assert.equal(selectIsUnlockModalOpen({ vault: state }), true);

  // closeUnlockModal
  state = vaultReducer(state, closeUnlockModal());
  assert.equal(selectIsUnlockModalOpen({ vault: state }), false);

  // setUnlockModalOpen(true / false)
  state = vaultReducer(state, setUnlockModalOpen(true));
  assert.equal(selectIsUnlockModalOpen({ vault: state }), true);
  state = vaultReducer(state, setUnlockModalOpen(false));
  assert.equal(selectIsUnlockModalOpen({ vault: state }), false);

  // Opening modal then unlocking vault automatically closes unlock modal
  state = vaultReducer(state, openUnlockModal());
  assert.equal(selectIsUnlockModalOpen({ vault: state }), true);
  state = vaultReducer(state, setVaultUnlocked(TEST_KEY_HEX_RAW));
  assert.equal(selectIsVaultUnlocked({ vault: state }), true);
  assert.equal(selectIsUnlockModalOpen({ vault: state }), false, 'Unlock must close unlock modal');

  // Locking vault also ensures unlock modal is closed
  state = vaultReducer(state, lockVault());
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
  assert.equal(selectIsUnlockModalOpen({ vault: state }), false);
});
