// REQ-VAULT-CHAT-1: Unit Tests for Chat and Conversations UI Zero-Knowledge Encryption,
// Decryption, Reusable VaultText Integration, and Legacy Plaintext Compatibility.
//
// RUN: node --test tests/ui_chat_vault_test.ts

import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  isVaultArmored,
  encryptVaultText,
} from '../src/ui/utils/vaultContent.ts';
import {
  resolveVaultText,
  decryptVaultTextContent,
} from '../src/ui/components/vault/vaultTextHelper.ts';
import {
  encryptChatFields,
  decryptChatMessage,
  decryptChatMessages,
  encryptConversationFields,
  decryptConversationRecord,
  decryptConversationList,
} from '../src/ui/utils/vaultChats.ts';

const TEST_KEY_HEX_RAW = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const TEST_KEY_HEX = await keyringFromHex(TEST_KEY_HEX_RAW);
const DIFFERENT_KEY_HEX_RAW = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
const DIFFERENT_KEY_HEX = await keyringFromHex(DIFFERENT_KEY_HEX_RAW);

// -----------------------------------------------------------------------------
// Test 1: Chat message body encryption and decryption round-trip
// -----------------------------------------------------------------------------

test('encryptChatFields encrypts message body when key is provided', async () => {
  const origBody = 'Confidential message: system migration scheduled at 02:00 UTC.';
  const payload = { body: origBody, author: 'user' };

  const encrypted = await encryptChatFields(payload, TEST_KEY_HEX);

  assert.equal(encrypted.author, 'user', 'author metadata must remain unaltered');
  assert.ok(encrypted.body !== origBody, 'body must not leak plaintext');
  assert.ok(isVaultArmored(encrypted.body), 'body must start with vault:v2:7e57000000000001:e1:');

  // Round-trip decrypt
  const decrypted = await decryptChatMessage(encrypted, TEST_KEY_HEX);
  assert.equal(decrypted.body, origBody, 'body must decrypt to original plaintext');
});

test('encryptChatFields leaves body as plaintext when key is not provided', async () => {
  const origBody = 'Normal unencrypted message.';
  const payload = { body: origBody, author: 'agent' };

  const resNull = await encryptChatFields(payload, null);
  assert.equal(resNull.body, origBody, 'body must remain plaintext when key is null');
  assert.ok(!isVaultArmored(resNull.body), 'must not be armored');

  const resEmpty = await encryptChatFields(payload, '');
  assert.equal(resEmpty.body, origBody, 'body must remain plaintext when key is empty');
});

test('decryptChatMessage handles locked vault and wrong key gracefully', async () => {
  const origBody = 'Protected secret message.';
  const encrypted = await encryptChatFields({ body: origBody }, TEST_KEY_HEX);

  // When vault is locked (no key), returns armored string intact
  const lockedRes = await decryptChatMessage(encrypted, null);
  assert.equal(lockedRes.body, encrypted.body, 'locked vault must preserve armored text intact');

  // When wrong key is used, decryption error is caught gracefully
  const wrongKeyRes = await decryptChatMessage(encrypted, DIFFERENT_KEY_HEX);
  assert.equal(wrongKeyRes.body, encrypted.body, 'wrong key must return armored text intact');
});

test('decryptChatMessages decrypts an array of messages', async () => {
  const msg1 = 'First encrypted chat message';
  const msg2 = 'Second encrypted chat message';
  const enc1 = await encryptChatFields({ id: '1', body: msg1 }, TEST_KEY_HEX);
  const enc2 = await encryptChatFields({ id: '2', body: msg2 }, TEST_KEY_HEX);

  const decryptedList = await decryptChatMessages([enc1, enc2], TEST_KEY_HEX);
  assert.equal(decryptedList[0].body, msg1);
  assert.equal(decryptedList[1].body, msg2);
});

// -----------------------------------------------------------------------------
// Test 3: Conversation title and preview encryption and decryption round-trip
// -----------------------------------------------------------------------------

test('encryptConversationFields encrypts title when key is provided', async () => {
  const origTitle = 'Confidential Architecture Discussion';
  const conv = { conversationId: 'chat_123', title: origTitle };

  const encrypted = await encryptConversationFields(conv, TEST_KEY_HEX);
  assert.equal(encrypted.conversationId, 'chat_123', 'conversationId must remain plaintext');
  assert.ok(encrypted.title !== origTitle, 'title must not leak plaintext');
  assert.ok(isVaultArmored(encrypted.title), 'title must be armored');

  // Round-trip decrypt
  const decrypted = await decryptConversationRecord(encrypted, TEST_KEY_HEX);
  assert.equal(decrypted.title, origTitle, 'title must decrypt to original plaintext');
});

test('decryptConversationRecord decrypts title and previews', async () => {
  const origTitle = 'Zero-Knowledge Vault Thread';
  const origPreview = 'Last preview: keys configured successfully';
  const encTitle = await encryptVaultText(origTitle, TEST_KEY_HEX);
  const encPreview = await encryptVaultText(origPreview, TEST_KEY_HEX);

  const conv = {
    conversationId: 'chat_456',
    title: encTitle,
    last_message_preview: encPreview,
    lastMessagePreview: encPreview,
  };

  const decrypted = await decryptConversationRecord(conv, TEST_KEY_HEX);
  assert.equal(decrypted.title, origTitle);
  assert.equal(decrypted.last_message_preview, origPreview);
  assert.equal(decrypted.lastMessagePreview, origPreview);
});

test('decryptConversationList decrypts array of conversations', async () => {
  const encTitle1 = await encryptVaultText('Thread Alpha', TEST_KEY_HEX);
  const encTitle2 = await encryptVaultText('Thread Beta', TEST_KEY_HEX);

  const list = [
    { conversationId: 'c1', title: encTitle1 },
    { conversationId: 'c2', title: encTitle2 },
  ];

  const decryptedList = await decryptConversationList(list, TEST_KEY_HEX);
  assert.equal(decryptedList[0].title, 'Thread Alpha');
  assert.equal(decryptedList[1].title, 'Thread Beta');
});

// -----------------------------------------------------------------------------
// Test 4: resolveVaultText helper integration with chat values
// -----------------------------------------------------------------------------

test('resolveVaultText resolves chat messages based on vault lock state', async () => {
  const origText = 'Live chat status message.';
  const armored = await encryptVaultText(origText, TEST_KEY_HEX);

  // Plaintext returns immediately
  const resPlain = resolveVaultText(origText, false);
  assert.equal(resPlain.mode, 'plaintext');
  assert.equal(resPlain.displayText, origText);
  assert.equal(resPlain.isLocked, false);

  // Armored with vault locked returns locked status
  const resLocked = resolveVaultText(armored, false);
  assert.equal(resLocked.mode, 'locked');
  assert.ok(resLocked.isLocked);
  assert.ok(resLocked.displayText.includes('Encrypted content'));

  // Armored with vault unlocked
  const resUnlocked = resolveVaultText(armored, true);
  assert.equal(resUnlocked.mode, 'unlocked');
  assert.equal(resUnlocked.isLocked, false);

  // Async decrypt helper
  const dec = await decryptVaultTextContent(armored, TEST_KEY_HEX);
  assert.equal(dec, origText);
});

// -----------------------------------------------------------------------------
// Test 5: Legacy unarmored plaintext chat messages render transparently
// -----------------------------------------------------------------------------

test('legacy plaintext chat messages and threads render transparently without regression', async () => {
  const legacyBody = 'Legacy plaintext message from v1 system.';
  const legacyTitle = 'Legacy Thread Title';
  const legacyPreview = 'Legacy message preview snippet.';

  const message = { id: 'msg_legacy', body: legacyBody };
  const conv = {
    conversationId: 'chat_legacy',
    title: legacyTitle,
    last_message_preview: legacyPreview,
  };

  // Decryption with vault unlocked preserves plaintext
  const decMsgUnlocked = await decryptChatMessage(message, TEST_KEY_HEX);
  assert.equal(decMsgUnlocked.body, legacyBody);

  const decConvUnlocked = await decryptConversationRecord(conv, TEST_KEY_HEX);
  assert.equal(decConvUnlocked.title, legacyTitle);
  assert.equal(decConvUnlocked.last_message_preview, legacyPreview);

  // Decryption with vault locked preserves plaintext
  const decMsgLocked = await decryptChatMessage(message, null);
  assert.equal(decMsgLocked.body, legacyBody);

  const decConvLocked = await decryptConversationRecord(conv, null);
  assert.equal(decConvLocked.title, legacyTitle);
  assert.equal(decConvLocked.last_message_preview, legacyPreview);
});

// -----------------------------------------------------------------------------
// Test 6: Embedded ciphertext tokens in messages, action notices, and sender-prefixed previews (REQ-INDIRECT-DECRYPT-UI-1)
// -----------------------------------------------------------------------------

test('embedded ciphertext tokens in message bodies and sender-prefixed previews decrypt cleanly', async () => {
  const secretBody = 'I deployed the auth module successfully.';
  const armoredSecret = await encryptVaultText(secretBody, TEST_KEY_HEX);

  // Embedded token in message body
  const embeddedMsg = {
    id: 'msg_embedded',
    body: `Execution report: ${armoredSecret} (verified).`,
  };
  const decryptedMsg = await decryptChatMessage(embeddedMsg, TEST_KEY_HEX);
  assert.equal(decryptedMsg.body, `Execution report: ${secretBody} (verified).`);

  // Sender-prefixed preview: "You: vault:v2:7e57000000000001:e1:..."
  const convWithPrefix = {
    conversationId: 'chat_prefix',
    title: 'Deployment Chat',
    lastMessagePreview: `You: ${armoredSecret}`,
    last_message_preview: `You: ${armoredSecret}`,
  };
  const decryptedConv = await decryptConversationRecord(convWithPrefix, TEST_KEY_HEX);
  assert.equal(decryptedConv.lastMessagePreview, `You: ${secretBody}`);
  assert.equal(decryptedConv.last_message_preview, `You: ${secretBody}`);

  // Action receipt with embedded token
  const actionReceiptMsg = {
    id: 'msg_action_receipt',
    body: `Action receipt for approval ${armoredSecret}`,
  };
  const decryptedActionMsg = await decryptChatMessage(actionReceiptMsg, TEST_KEY_HEX);
  assert.equal(decryptedActionMsg.body, `Action receipt for approval ${secretBody}`);
});

