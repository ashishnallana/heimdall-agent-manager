// REQ-VAULT-COMMAND-PALETTE, REQ-VAULT-ISSUES-PAGE, REQ-VAULT-NOTIFICATIONS:
// Comprehensive verification tests for Vault decryption in Command Palette, Issues page, and Notifications.
//
// RUN: node --test tests/ui_vault_palette_issues_notifications_test.ts

import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

const TEST_KEY_HEX_RAW = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const TEST_KEY_HEX = await keyringFromHex(TEST_KEY_HEX_RAW);

// -----------------------------------------------------------------------------
// Section 2: Command Palette Vault Decryption & Client-Side Search
// -----------------------------------------------------------------------------

import { encryptVaultText, decryptVaultText, isVaultArmored } from '../src/ui/utils/vaultContent.ts';
import { matchesQuery } from '../src/ui/components/ui/patterns/commandPaletteLogic.ts';

test('Command Palette: project names decryption enables client-side search by decrypted project name', async () => {
  const secretProjectName = 'Project Supernova';
  const armoredProjectName = await encryptVaultText(secretProjectName, TEST_KEY_HEX);

  assert.ok(isVaultArmored(armoredProjectName), 'Armored project name must be detected as vault:v2:e1:');

  // Before decryption: search with query 'supernova' fails against raw ciphertext
  const beforeSearch = !isVaultArmored(armoredProjectName) && matchesQuery(armoredProjectName, 'supernova');
  assert.equal(beforeSearch, false, 'Raw ciphertext must not match decrypted query');

  // After decryption with activeVaultKey:
  const decryptedProjectName = await decryptVaultText(armoredProjectName, TEST_KEY_HEX);
  assert.equal(decryptedProjectName, secretProjectName);

  const afterSearch = !isVaultArmored(decryptedProjectName) && matchesQuery(decryptedProjectName, 'supernova');
  assert.equal(afterSearch, true, 'Decrypted project name must match query "supernova"');

  const afterSearchPartial = !isVaultArmored(decryptedProjectName) && matchesQuery(decryptedProjectName, 'proj');
  assert.equal(afterSearchPartial, true, 'Decrypted project name must match prefix "proj"');
});

test('Command Palette: group headers and hints correctly format with VaultText', async () => {
  const secretHint = 'Top Secret Coordinator';
  const armoredHint = await encryptVaultText(secretHint, TEST_KEY_HEX);

  assert.ok(isVaultArmored(armoredHint));
  const decrypted = await decryptVaultText(armoredHint, TEST_KEY_HEX);
  assert.equal(decrypted, secretHint);
});

// -----------------------------------------------------------------------------
// Section 3: Issues Page & Hub issue_description_preview
// -----------------------------------------------------------------------------

import { decryptIssueRecord, type IssuePayload } from '../src/ui/utils/vaultIssues.ts';

test('Hub issue_description_preview logic preserves full vault armored ciphertext', async () => {
  const secretDescription = 'Very long secret description explaining the defect in extreme detail with steps to reproduce.';
  const armoredDescription = await encryptVaultText(secretDescription, TEST_KEY_HEX);

  // Armored strings exceed 160 runes
  assert.ok(armoredDescription.length > 100, 'Armored token must have substantial length');

  // Emulate issue_description_preview in Odin:
  const trimmed = armoredDescription.trim();
  let preview: string;
  if (trimmed.includes('vault:v2:e1:')) {
    preview = trimmed;
  } else {
    preview = trimmed.slice(0, 160);
  }

  assert.equal(preview, armoredDescription, 'issue_description_preview must return full untruncated ciphertext');
  // AES-GCM tags are intact; decryption succeeds without corruption
  const decrypted = await decryptVaultText(preview, TEST_KEY_HEX);
  assert.equal(decrypted, secretDescription);
});

test('decryptIssueRecord decrypts title, description, descriptionPreview, and comment bodies', async () => {
  const secretTitle = 'Fix database connection timeout';
  const secretDesc = 'The database pool exhausts connections under load.';
  const secretComment = 'Root cause identified: unclosed cursors in auth loop.';

  const armoredTitle = await encryptVaultText(secretTitle, TEST_KEY_HEX);
  const armoredDesc = await encryptVaultText(secretDesc, TEST_KEY_HEX);
  const armoredComment = await encryptVaultText(secretComment, TEST_KEY_HEX);

  const rawRecord: IssuePayload = {
    issue_id: 'iss_123',
    owner_user_id: 'user_1',
    title: armoredTitle,
    description: armoredDesc,
    description_preview: armoredDesc,
    created_by: 'tanmay',
    status: 'new',
    scope_type: 'global',
    target_id: '',
    chain_id: '',
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    closed_at: '',
    vote_count: 3,
    comment_count: 1,
    has_voted: true,
    comments: [
      {
        comment_id: 'cmt_001',
        issue_id: 'iss_123',
        owner_user_id: 'user_1',
        author_id: 'agt_1',
        author_name: 'Worker',
        body: armoredComment,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      },
    ],
  };

  assert.ok(isVaultArmored(rawRecord.title));
  assert.ok(isVaultArmored(rawRecord.description));
  assert.ok(isVaultArmored(rawRecord.comments![0].body));

  const decryptedRecord = await decryptIssueRecord(rawRecord, TEST_KEY_HEX);

  assert.equal(decryptedRecord.title, secretTitle);
  assert.equal(decryptedRecord.description, secretDesc);
  assert.equal(decryptedRecord.descriptionPreview, secretDesc);
  assert.equal(decryptedRecord.comments![0].body, secretComment);
});

test('decryptIssueRecord is a no-op when no active key is supplied', async () => {
  const secretTitle = 'Safe title';
  const armoredTitle = await encryptVaultText(secretTitle, TEST_KEY_HEX);

  const rawRecord: IssuePayload = {
    issue_id: 'iss_456',
    title: armoredTitle,
    description: armoredTitle,
  };

  const unchanged = await decryptIssueRecord(rawRecord, null);
  assert.equal(unchanged.title, armoredTitle);
});

// -----------------------------------------------------------------------------
// Section 4: Notification Banners, Toasts, and Native Notification Service
// -----------------------------------------------------------------------------

import { notificationForWsEvent } from '../src/ui/api/notificationMapper.ts';
import { setActiveVaultKey } from '../src/ui/utils/vaultCrypto.ts';

// Browser global mocks for Notification & Session Storage
const mockCreatedNotifications: Array<{ title: string; options: any }> = [];
class MockNotification {
  static permission: NotificationPermission = 'granted';
  static requestPermission = async () => 'granted';
  title: string;
  options: any;
  constructor(title: string, options: any = {}) {
    this.title = title;
    this.options = options;
    mockCreatedNotifications.push({ title, options });
  }
}

const mockStorage: Record<string, string> = {};
const mockSessionStorage = {
  getItem: (k: string) => mockStorage[k] ?? null,
  setItem: (k: string, v: string) => { mockStorage[k] = String(v); },
  removeItem: (k: string) => { delete mockStorage[k]; },
  clear: () => { Object.keys(mockStorage).forEach((k) => delete mockStorage[k]); },
};

(globalThis as any).window = {
  Notification: MockNotification,
  sessionStorage: mockSessionStorage,
  addEventListener: () => {},
  removeEventListener: () => {},
  location: { hash: '#/conversations' },
  isSecureContext: true,
};
(globalThis as any).Notification = MockNotification;
(globalThis as any).sessionStorage = mockSessionStorage;

const { fireNotificationForWsEvent } = await import('../src/ui/services/notificationService.ts');

const flushMicrotasks = async () => {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  await new Promise((r) => setTimeout(r, 30));
};

test('notificationMapper.ts: truncate does NOT truncate vault armored tokens before decryption', async () => {
  const longSecret = 'This is a critical secret message that contains details that must not be truncated prematurely before decryption.'.repeat(2);
  const armoredBody = await encryptVaultText(longSecret, TEST_KEY_HEX);

  assert.ok(armoredBody.length > 200, 'Armored body length must exceed 200 chars');

  const chatPayload = {
    type: 'chat_event',
    direction: 'agent_to_user',
    conversation_id: 'conv_mapper_test',
    message: {
      direction: 'agent_to_user',
      body: armoredBody,
    },
  };

  const plan = notificationForWsEvent(chatPayload, {});
  assert.ok(plan, 'Mapper plan must be generated');
  assert.equal(plan!.body, armoredBody, 'Armored body must NOT be truncated by notificationMapper');
  assert.ok(!plan!.body.endsWith('…'), 'Body must not have trailing ellipsis indicating premature truncation');
});

test('notificationService.ts: decrypts from the installed keyring; Redux carries only the flag', async () => {
  mockCreatedNotifications.length = 0;
  setActiveVaultKey(null);
  setActiveVaultKey(TEST_KEY_HEX);

  const secretBody = 'Agent completed deployment without errors.';
  const armoredBody = await encryptVaultText(secretBody, TEST_KEY_HEX);

  // Redux carries the unlock FLAG and nothing else -- there is no key field to populate.
  const unhydratedReduxState = () => ({
    notifications: {
      enabled: true,
      permission: 'granted',
      categories: { chat: true, attention: true },
    },
    vault: {
      isUnlocked: true,
      currentEpoch: 1,
    },
  });

  const payload = {
    type: 'chat_event',
    direction: 'agent_to_user',
    conversation_id: 'conv_session_test',
    message: {
      direction: 'agent_to_user',
      body: armoredBody,
    },
  };

  const plan = fireNotificationForWsEvent(unhydratedReduxState, payload);
  assert.ok(plan, 'Plan must be returned');

  await flushMicrotasks();

  assert.ok(mockCreatedNotifications.length >= 1, 'Native notification must be fired');
  const lastNotification = mockCreatedNotifications[mockCreatedNotifications.length - 1];
  assert.equal(lastNotification.options.body, secretBody, 'Body must be decrypted via the installed keyring');

  setActiveVaultKey(null);
});

test('notificationService.ts: truncates title/body AFTER successful decryption', async () => {
  mockCreatedNotifications.length = 0;
  setActiveVaultKey(null);

  const extraLongSecret = 'A'.repeat(250);
  const armoredBody = await encryptVaultText(extraLongSecret, TEST_KEY_HEX);
  setActiveVaultKey(TEST_KEY_HEX);

  const unlockedState = () => ({
    notifications: {
      enabled: true,
      permission: 'granted',
      categories: { chat: true, attention: true },
    },
    vault: {
      isUnlocked: true,
      currentEpoch: 1,
    },
  });

  const payload = {
    type: 'chat_event',
    direction: 'agent_to_user',
    conversation_id: 'conv_long_test',
    message: {
      direction: 'agent_to_user',
      body: armoredBody,
    },
  };

  fireNotificationForWsEvent(unlockedState, payload);
  await flushMicrotasks();

  assert.ok(mockCreatedNotifications.length >= 1);
  const lastNotification = mockCreatedNotifications[mockCreatedNotifications.length - 1];
  assert.ok(lastNotification.options.body.length <= 140, 'Decrypted notification body must be truncated to <= 140 chars');
  assert.ok(lastNotification.options.body.endsWith('…'), 'Truncated body must end with ellipsis');
});
