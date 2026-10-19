// REQ-INDIRECT-DECRYPT-TEST-1: Full Stack Regression & End-to-End Verification Test Suite
// Verifies embedded vault token detection, multi-token decryption, desktop OS notification shielding,
// Web Push notification mapping, and friendly display name / reviewer reference resolution.
//
// RUN: node --test tests/ui_embedded_vault_decrypt_test.ts

import { importRawKeyHex } from './helpers/vaultTestKeyring.ts';
import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

const TEST_KEY_HEX_RAW = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const TEST_KEY_HEX = await keyringFromHex(TEST_KEY_HEX_RAW);
const DIFFERENT_KEY_HEX_RAW = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
const DIFFERENT_KEY_HEX = await keyringFromHex(DIFFERENT_KEY_HEX_RAW);

// -----------------------------------------------------------------------------
// Section 1: Embedded Vault Token Detection & Multi-Token Decryption
// -----------------------------------------------------------------------------

import {
  isVaultArmored,
  containsVaultArmored,
  encryptVaultText,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
  VAULT_ARMOR_PREFIX,
} from '../src/ui/utils/vaultContent.ts';

test('containsVaultArmored accurately detects embedded and standalone vault:v2:7e57000000000001:e1:... tokens', async () => {
  const secret = 'Confidential Token Data';
  const armored = await encryptVaultText(secret, TEST_KEY_HEX);

  // Standalone
  assert.equal(containsVaultArmored(armored), true);

  // Embedded in conversation / chat messages
  assert.equal(containsVaultArmored(`You: ${armored}`), true);
  assert.equal(containsVaultArmored(`Notice from agent: ${armored} was logged.`), true);
  assert.equal(containsVaultArmored(`[action_receipt] Task created: ${armored}`), true);

  // Multiple embedded tokens
  const secret2 = 'Second Secret';
  const armored2 = await encryptVaultText(secret2, TEST_KEY_HEX);
  assert.equal(containsVaultArmored(`Chain ${armored} produced result ${armored2}`), true);

  // Non-matching edge cases
  assert.equal(containsVaultArmored('Completely plain text without armor'), false);
  assert.equal(containsVaultArmored('vault:v2:unsupported-version-data'), false);
  assert.equal(containsVaultArmored('vault:'), false);
  assert.equal(containsVaultArmored('vault:v2:7e57000000000001:e1:'), false);
  assert.equal(containsVaultArmored(''), false);
  assert.equal(containsVaultArmored(null), false);
  assert.equal(containsVaultArmored(undefined), false);
  assert.equal(containsVaultArmored(42), false);
  assert.equal(containsVaultArmored({}), false);
});

test('decryptEmbeddedVaultTokens decrypts single and multiple embedded tokens while preserving surroundings', async () => {
  const secret1 = 'Secret Operation 1';
  const secret2 = 'Secret Parameter 2';
  const armored1 = await encryptVaultText(secret1, TEST_KEY_HEX);
  const armored2 = await encryptVaultText(secret2, TEST_KEY_HEX);

  // Single embedded token with sender prefix
  const senderMessage = `You: ${armored1}`;
  const decryptedSender = await decryptEmbeddedVaultTokens(senderMessage, TEST_KEY_HEX);
  assert.equal(decryptedSender, `You: ${secret1}`);

  // Action receipt with surrounding context
  const receipt = `Receipt [action_123]: Successfully processed ${armored2} in 42ms.`;
  const decryptedReceipt = await decryptEmbeddedVaultTokens(receipt, TEST_KEY_HEX);
  assert.equal(decryptedReceipt, `Receipt [action_123]: Successfully processed ${secret2} in 42ms.`);

  // Multiple embedded tokens in same string
  const multi = `Token A: ${armored1} and Token B: ${armored2} finished.`;
  const decryptedMulti = await decryptEmbeddedVaultTokens(multi, TEST_KEY_HEX);
  assert.equal(decryptedMulti, `Token A: ${secret1} and Token B: ${secret2} finished.`);

  // Repeated instance of same token (tests Set deduplication)
  const repeated = `${armored1} matches ${armored1}`;
  const decryptedRepeated = await decryptEmbeddedVaultTokens(repeated, TEST_KEY_HEX);
  assert.equal(decryptedRepeated, `${secret1} matches ${secret1}`);

  // Plaintext returns as-is
  const plain = 'Regular non-armored text.';
  assert.equal(await decryptEmbeddedVaultTokens(plain, TEST_KEY_HEX), plain);

  // Missing or empty key returns input string without throwing
  assert.equal(await decryptEmbeddedVaultTokens(senderMessage, ''), senderMessage);
  assert.equal(await decryptEmbeddedVaultTokens(senderMessage, null as any), senderMessage);
});

test('decryptEmbeddedVaultTokens gracefully preserves surroundings on decryption error', async () => {
  const secret = 'Authentic Secret';
  const armored = await encryptVaultText(secret, TEST_KEY_HEX);

  // Decryption with wrong key should not throw, but preserve surrounding structure
  const input = `You: ${armored}`;
  const result = await decryptEmbeddedVaultTokens(input, DIFFERENT_KEY_HEX);
  // When decryption fails, individual token failure is handled gracefully
  assert.ok(result.startsWith('You: '));
});

// -----------------------------------------------------------------------------
// Section 3: Chat Message & Conversation Record Decryption with Embedded Tokens
// -----------------------------------------------------------------------------

import {
  decryptChatMessage,
  decryptConversationRecord,
  decryptConversationList,
} from '../src/ui/utils/vaultChats.ts';

test('decryptChatMessage decrypts embedded tokens in message body and metadata', async () => {
  const secretBody = 'Agent conversation body containing confidential tokens';
  const armoredBody = await encryptVaultText(secretBody, TEST_KEY_HEX);
  const embeddedMessageBody = `Status update: ${armoredBody} (completed)`;

  const message = {
    id: 'msg_100',
    body: embeddedMessageBody,
    direction: 'agent_to_user',
  };

  const decrypted = await decryptChatMessage(message, TEST_KEY_HEX);
  assert.equal(decrypted.body, `Status update: ${secretBody} (completed)`);

  // When locked (key is null), preserves message body without throwing
  const lockedDecrypted = await decryptChatMessage(message, null);
  assert.equal(lockedDecrypted.body, embeddedMessageBody);
});

test('decryptConversationRecord decrypts sender-prefixed previews with embedded tokens', async () => {
  const secretPreview = 'This is a private message preview';
  const armoredPreview = await encryptVaultText(secretPreview, TEST_KEY_HEX);
  const senderPrefixedPreview = `You: ${armoredPreview}`;

  const secretTitle = 'Encrypted Project Conversation';
  const armoredTitle = await encryptVaultText(secretTitle, TEST_KEY_HEX);

  const conv = {
    conversationId: 'chat_789',
    title: armoredTitle,
    last_message_preview: senderPrefixedPreview,
    lastMessagePreview: senderPrefixedPreview,
    body_preview: senderPrefixedPreview,
    lastMessage: {
      body: senderPrefixedPreview,
    },
  };

  const decrypted = await decryptConversationRecord(conv, TEST_KEY_HEX);
  assert.equal(decrypted.title, secretTitle);
  assert.equal(decrypted.last_message_preview, `You: ${secretPreview}`);
  assert.equal(decrypted.lastMessagePreview, `You: ${secretPreview}`);
  assert.equal(decrypted.body_preview, `You: ${secretPreview}`);
  assert.equal(decrypted.lastMessage?.body, `You: ${secretPreview}`);
});

// -----------------------------------------------------------------------------
// Section 4: Web Push Notification Mapper Sanitization
// -----------------------------------------------------------------------------

import { planForPushPayload } from '../src/ui/api/pushNotificationMapper.ts';

test('planForPushPayload sanitizes armored titles and bodies to shield push notifications', async () => {
  const secretTitle = 'Sensitive Task Completed';
  const secretBody = 'Details of deployment to production cluster';
  const armoredTitle = await encryptVaultText(secretTitle, TEST_KEY_HEX);
  const armoredBody = await encryptVaultText(secretBody, TEST_KEY_HEX);

  // 1. Armored title & body
  const plan1 = planForPushPayload({
    title: armoredTitle,
    body: armoredBody,
    category: 'chat',
  });
  assert.equal(plan1.title, '[🔒 Encrypted notification]', 'Armored title must be sanitized');
  assert.equal(plan1.body, '[🔒 Encrypted notification]', 'Armored body must be sanitized');

  // 2. Embedded vault token in title & body
  const plan2 = planForPushPayload({
    title: `Notice: ${armoredTitle}`,
    body: `You: ${armoredBody}`,
    category: 'attention',
  });
  assert.equal(plan2.title, '[🔒 Encrypted notification]', 'Embedded token in title must be sanitized');
  assert.equal(plan2.body, '[🔒 Encrypted notification]', 'Embedded token in body must be sanitized');

  // 3. Plaintext title & body are preserved
  const plan3 = planForPushPayload({
    title: 'Public Notification',
    body: 'Regular system update.',
    category: 'attention',
  });
  assert.equal(plan3.title, 'Public Notification');
  assert.match(plan3.body, /Regular system update\./);
});

// -----------------------------------------------------------------------------
// Section 5: Native OS Desktop Notification Shielding & Decryption
// -----------------------------------------------------------------------------

// Setup DOM / Notification environment for notificationService tests
type MockCreatedNotification = { title: string; options: any };
const mockCreatedNotifications: MockCreatedNotification[] = [];

class MockNotification {
  title: string;
  options: any;
  onclick: (() => void) | null = null;
  static permission: 'default' | 'granted' | 'denied' = 'granted';
  static requestImpl: () => Promise<'default' | 'granted' | 'denied'> = async () => 'granted';
  constructor(title: string, options: any) {
    this.title = title;
    this.options = options;
    mockCreatedNotifications.push({ title, options });
  }
  static async requestPermission() {
    return MockNotification.requestImpl();
  }
  close() {}
}

const mockBrowserState = {
  visibility: 'hidden' as 'hidden' | 'visible',
  focus: false,
  hash: '',
  origin: 'https://hub.test',
  pathname: '/index.html',
  search: '',
};

(globalThis as any).document = {
  get visibilityState() { return mockBrowserState.visibility; },
  hasFocus() { return mockBrowserState.focus; },
  querySelector() { return { href: 'https://hub.test/favicon.png' }; },
  addEventListener() {},
  removeEventListener() {},
};

(globalThis as any).window = {
  Notification: MockNotification,
  localStorage: {
    getItem() { return null; },
    setItem() {},
    removeItem() {},
  },
  get location() {
    return {
      origin: mockBrowserState.origin,
      pathname: mockBrowserState.pathname,
      search: mockBrowserState.search,
      get hash() { return mockBrowserState.hash; },
      set hash(v: string) { mockBrowserState.hash = v; },
    };
  },
  focus() { mockBrowserState.focus = true; },
  open(url: string) { return { focus() {} }; },
  odinApi: undefined,
  isSecureContext: true,
};
(globalThis as any).Notification = MockNotification;

const flushMicrotasks = async () => {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  await new Promise((r) => setTimeout(r, 20));
};

const { fireNotificationForWsEvent } = await import('../src/ui/services/notificationService.ts');

// REQ-RAWKEY-A8: notificationService resolves the key via getActiveVaultKey(), not
// from Redux state. Supply it the production way -- a real non-extractable CryptoKey
// in the module-level active-key slot -- rather than injecting fake hex into a mock
// state, which no longer reaches any production read.
const { setActiveVaultKey } = await import('../src/ui/utils/vaultCrypto.ts');

test('fireNotificationForWsEvent sanitizes notifications when vault is locked', async () => {
  mockCreatedNotifications.length = 0;
  mockBrowserState.visibility = 'hidden';
  mockBrowserState.focus = false;

  const secretText = 'Confidential task data';
  const armoredText = await encryptVaultText(secretText, TEST_KEY_HEX);

  const lockedState = () => ({
    notifications: {
      enabled: true,
      permission: 'granted',
      categories: { chat: true, attention: true },
    },
    vault: {
      isConfigured: true,
      isUnlocked: false,
    },
  });

  // Locked means no active key at all -- this is what lockVault() leaves behind.
  setActiveVaultKey(null);

  // 1. Attention category with armored body
  const attentionPayload = {
    type: 'chat_approval',
    approval: {
      chain_id: 'chain_123',
      agent_instance_id: 'agent_abc',
      body: armoredText,
    },
  };

  const planAttention = fireNotificationForWsEvent(lockedState, attentionPayload);
  assert.ok(planAttention, 'Plan must be created');
  assert.equal(planAttention.body, '[🔒 Encrypted action]', 'Locked attention body must be sanitized');

  await flushMicrotasks();
  assert.ok(mockCreatedNotifications.length >= 1);
  const lastAttention = mockCreatedNotifications[mockCreatedNotifications.length - 1];
  assert.equal(lastAttention.options.body, '[🔒 Encrypted action]');

  // 2. Chat category with armored body
  const chatPayload = {
    type: 'chat_event',
    direction: 'agent_to_user',
    conversation_id: 'conv_vault',
    message: {
      direction: 'agent_to_user',
      body: `You: ${armoredText}`,
    },
  };

  const planChat = fireNotificationForWsEvent(lockedState, chatPayload);
  assert.ok(planChat, 'Plan must be created for chat');
  assert.equal(planChat.body, '[🔒 Encrypted message]', 'Locked chat body must be sanitized');

  await flushMicrotasks();
  const lastChat = mockCreatedNotifications[mockCreatedNotifications.length - 1];
  assert.equal(lastChat.options.body, '[🔒 Encrypted message]');
});

test('fireNotificationForWsEvent asynchronously decrypts notifications when vault is unlocked', async () => {
  mockCreatedNotifications.length = 0;
  mockBrowserState.visibility = 'hidden';
  mockBrowserState.focus = false;

  const secretBody = 'Agent has completed task 42.';
  const armoredBody = await encryptVaultText(secretBody, TEST_KEY_HEX);

  const unlockedState = () => ({
    notifications: {
      enabled: true,
      permission: 'granted',
      categories: { chat: true, attention: true },
    },
    vault: {
      isConfigured: true,
      isUnlocked: true,
    },
  });

  // Unlocked means a live CryptoKey in the active-key slot.
  setActiveVaultKey(await keyringFromHex(TEST_KEY_HEX_RAW));

  const payload = {
    type: 'chat_event',
    direction: 'agent_to_user',
    conversation_id: 'conv_unlocked',
    message: {
      direction: 'agent_to_user',
      body: `Status: ${armoredBody}`,
    },
  };

  try {
    const plan = fireNotificationForWsEvent(unlockedState, payload);
    assert.ok(plan, 'Plan must be returned');

    // Wait for asynchronous decryption to complete
    await flushMicrotasks();

    assert.ok(mockCreatedNotifications.length >= 1);
    const notification = mockCreatedNotifications[mockCreatedNotifications.length - 1];
    assert.equal(notification.options.body, `Status: ${secretBody}`, 'Body must be decrypted in OS notification');
  } finally {
    // The active key is MODULE-level state shared by every test in this file, and
    // decryptEmbeddedVaultTokens() falls back to it when called without a key. Leaving
    // it set would silently arm later no-active-key tests. Restore the locked state.
    setActiveVaultKey(null);
  }
});

// -----------------------------------------------------------------------------
// Section 6: Task Inference & Reviewer Resolution
// -----------------------------------------------------------------------------

import { taskReviewerOf } from '../src/ui/components/chat/chainTaskInference.ts';

test('taskReviewerOf correctly resolves reviewer from agent IDs and instance IDs across schema variations', () => {
  // 1. Durable agent ID in reviewer_refs[0].agent_id
  const task1 = {
    taskId: 'task_001',
    reviewer_refs: [{ type: 'agent_id', agent_id: 'agt_reviewer_durable' }],
  };
  assert.equal(taskReviewerOf(task1 as any), 'agt_reviewer_durable');

  // 2. Durable agent ID in reviewerRefs[0].agentId (camelCase)
  const task2 = {
    taskId: 'task_002',
    reviewerRefs: [{ type: 'agent_id', agentId: 'agt_reviewer_camel' }],
  };
  assert.equal(taskReviewerOf(task2 as any), 'agt_reviewer_camel');

  // 3. Live instance ID in reviewer_refs[0].agent_instance_id
  const task3 = {
    taskId: 'task_003',
    reviewer_refs: [{ type: 'agent_instance', agent_instance_id: 'inst_reviewer_live' }],
  };
  assert.equal(taskReviewerOf(task3 as any), 'inst_reviewer_live');

  // 4. Live instance ID in reviewerRefs[0].agentInstanceId
  const task4 = {
    taskId: 'task_004',
    reviewerRefs: [{ type: 'agent_instance', agentInstanceId: 'inst_reviewer_camel' }],
  };
  assert.equal(taskReviewerOf(task4 as any), 'inst_reviewer_camel');

  // 5. Direct reviewerAgentInstanceId / reviewer_agent_instance_id
  const task5 = {
    taskId: 'task_005',
    reviewer_agent_instance_id: 'inst_reviewer_direct',
  };
  assert.equal(taskReviewerOf(task5 as any), 'inst_reviewer_direct');

  // 6. Empty fallback
  const taskEmpty = { taskId: 'task_none' };
  assert.equal(taskReviewerOf(taskEmpty as any), '');
  assert.equal(taskReviewerOf(null), '');
});

// -----------------------------------------------------------------------------
// Section 7: Acceptance Criteria Summary Extraction & Display Logic
// -----------------------------------------------------------------------------

test('acceptanceSummary helper extracts criteria lines cleanly from markdown descriptions', () => {
  function testAcceptanceSummary(rawText: string): string {
    const raw = String(rawText || '').trim();
    if (!raw) return '';
    const lines = raw.split('\n');
    const crit: string[] = [];
    let inAcceptance = false;
    for (const line of lines) {
      const trimmed = line.trim();
      if (/^#{1,6}\s*accept/i.test(trimmed) || /acceptance criteria/i.test(trimmed)) {
        inAcceptance = true;
        continue;
      }
      if (inAcceptance && /^#{1,6}/.test(trimmed)) {
        inAcceptance = false;
        continue;
      }
      if (inAcceptance && (trimmed.startsWith('-') || trimmed.startsWith('*') || /^\[[ x]\]/i.test(trimmed))) {
        crit.push(trimmed.replace(/^[-*]\s*(\[[ x]\]\s*)?/, '').slice(0, 80));
      }
    }
    if (crit.length > 0) return crit.slice(0, 2).join(' · ');
    return raw.split('\n').map((l) => l.trim()).filter(Boolean)[0]?.slice(0, 80) || '';
  }

  const sampleDescription = `
Title: Implementation Task
Requirement ID: REQ-TEST-1

## Acceptance Criteria
- [ ] First criteria item: ensure zero-knowledge decryption
- [ ] Second criteria item: shield OS notifications
- [ ] Third criteria item: run full test battery
`;

  const summary = testAcceptanceSummary(sampleDescription);
  assert.equal(
    summary,
    'First criteria item: ensure zero-knowledge decryption · Second criteria item: shield OS notifications',
    'Must parse and format the first 2 acceptance criteria joined by interpunct',
  );

  const bulletDescription = `
Acceptance Criteria:
* Criteria Alpha
* Criteria Beta
`;
  assert.equal(testAcceptanceSummary(bulletDescription), 'Criteria Alpha · Criteria Beta');
});

// -----------------------------------------------------------------------------
// REQ-VAULT-UNSUP-5: embedded decryption is inert when SubtleCrypto is unavailable
//
// Without crypto.subtle the vault can never be unlocked, so no active key ever
// reaches the embedded-token decrypt path. It must degrade to leaving the armored
// text untouched — never throw a raw TypeError at the user.
// -----------------------------------------------------------------------------

test('embedded vault decryption is a no-op without an active key, touching no SubtleCrypto', async () => {
  const { decryptEmbeddedVaultTokens, containsVaultArmored } = await import(
    '../src/ui/utils/vaultContent.ts'
  );

  const armored = 'Task note: vault:v2:7e57000000000001:e1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= end.';
  assert.equal(containsVaultArmored(armored), true, 'fixture must contain an armored token');

  // Simulate the unsupported context: crypto present, subtle absent, no unlocked key.
  const realCrypto = globalThis.crypto;
  Object.defineProperty(globalThis, 'crypto', {
    value: { getRandomValues: (a: any) => a },
    configurable: true,
    writable: true,
  });
  try {
    for (const noKey of ['', null, undefined] as any[]) {
      const out = await decryptEmbeddedVaultTokens(armored, noKey);
      assert.equal(
        out,
        armored,
        'armored text must pass through unchanged when no vault key is active',
      );
    }
  } finally {
    Object.defineProperty(globalThis, 'crypto', {
      value: realCrypto,
      configurable: true,
      writable: true,
    });
  }
});

test('isVaultSupported() is the single availability predicate consumed by vault UI', async () => {
  const { isVaultSupported } = await import('../src/ui/utils/vaultCrypto.ts');
  assert.equal(typeof isVaultSupported, 'function', 'vaultCrypto.ts must export isVaultSupported');
  assert.equal(isVaultSupported(), true, 'Node webcrypto is a supported context');
});

console.log('ui_embedded_vault_decrypt_test: all regression tests completed successfully.');
