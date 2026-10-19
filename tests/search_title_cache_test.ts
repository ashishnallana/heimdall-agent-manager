// REQ-SEARCH-CLIENT-CACHE-1, REQ-SEARCH-WS-SYNC-1:
// Unit tests for Frontend Title Search Cache, Decryption Engine & Real-Time Sync.
//
// RUN: npx tsx --test tests/search_title_cache_test.ts

const sessionStore = new Map<string, string>();
const fakeSessionStorage = {
  getItem: (k: string) => sessionStore.get(k) ?? null,
  setItem: (k: string, v: string) => { sessionStore.set(k, String(v)); },
  removeItem: (k: string) => { sessionStore.delete(k); },
  clear: () => { sessionStore.clear(); },
};
(globalThis as any).sessionStorage = fakeSessionStorage;
if (typeof (globalThis as any).window === 'undefined') {
  (globalThis as any).window = {
    sessionStorage: fakeSessionStorage,
  };
} else {
  (globalThis as any).window.sessionStorage = fakeSessionStorage;
}

import { importRawKeyHex } from './helpers/vaultTestKeyring.ts';
import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { configureStore } from '@reduxjs/toolkit';
import './helpers/vaultEndpointHarness.ts';

import searchTitleReducer, {
  upsertChainTitle,
  upsertConversationTitle,
  setBulkChainTitles,
  setBulkConversationTitles,
  clearSearchTitles,
  setSearchTitlesInitialized,
  selectSearchTitleState,
  selectSearchChains,
  selectSearchConversations,
  selectIsSearchTitlesInitialized,
  selectAllSearchItems,
  type SearchItem,
} from '../src/ui/store/searchTitleSlice.ts';

import {
  batchDecryptTitles,
  decryptSearchTitle,
  SEARCH_DECRYPT_BATCH_SIZE,
} from '../src/ui/utils/vaultSearch.ts';

import {
  encryptVaultText,
  isVaultArmored,
} from '../src/ui/utils/vaultContent.ts';

import {
  default as vaultReducer,
} from '../src/ui/store/vaultSlice.ts';

// REQ-RAWKEY-A8: the key reaches wsInvalidation through getActiveVaultKey() only. The
// sessionStorage route (writeSessionVaultKey / readSessionVaultKey) is hardened to a no-op,
// so a fixture that writes the hex there installs nothing -- see the test at section 8.
import {
  setActiveVaultKey,
} from '../src/ui/utils/vaultCrypto.ts';

const { handleUserWsEvent } = await import('../src/ui/api/wsInvalidation.ts');

const TEST_KEY_HEX_RAW = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const TEST_KEY_HEX = await keyringFromHex(TEST_KEY_HEX_RAW);
const ALT_KEY_HEX_RAW = 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
const ALT_KEY_HEX = await keyringFromHex(ALT_KEY_HEX_RAW);

// -----------------------------------------------------------------------------
// 1. Redux Slice: Initial State and Selectors
// -----------------------------------------------------------------------------

test('searchTitleSlice starts with empty collections and uninitialized flag', () => {
  const state = searchTitleReducer(undefined, { type: '@@INIT' });
  assert.deepEqual(state.chains, {});
  assert.deepEqual(state.conversations, {});
  assert.equal(state.isInitialized, false);

  const rootState = { searchTitle: state };
  assert.deepEqual(selectSearchChains(rootState), {});
  assert.deepEqual(selectSearchConversations(rootState), {});
  assert.equal(selectIsSearchTitlesInitialized(rootState), false);
  assert.deepEqual(selectAllSearchItems(rootState), []);
});

// -----------------------------------------------------------------------------
// 2. Redux Slice: upsertChainTitle
// -----------------------------------------------------------------------------

test('upsertChainTitle adds new entry and updates existing without losing properties', () => {
  let state = searchTitleReducer(undefined, { type: '@@INIT' });

  // Add new chain entry
  state = searchTitleReducer(
    state,
    upsertChainTitle({
      id: 'chain_1',
      rawTitle: 'vault:v2:7e57000000000001:e1:abc',
      decryptedTitle: 'Decrypted Chain 1',
      projectId: 'proj_1',
      status: 'in_progress',
      updatedAt: '2026-09-26T12:00:00Z',
    }),
  );

  assert.ok(state.chains['chain_1']);
  assert.equal(state.chains['chain_1'].id, 'chain_1');
  assert.equal(state.chains['chain_1'].type, 'chain');
  assert.equal(state.chains['chain_1'].rawTitle, 'vault:v2:7e57000000000001:e1:abc');
  assert.equal(state.chains['chain_1'].decryptedTitle, 'Decrypted Chain 1');
  assert.equal(state.chains['chain_1'].projectId, 'proj_1');
  assert.equal(state.chains['chain_1'].status, 'in_progress');

  // Update status without re-specifying title - preserves title and decryptedTitle
  state = searchTitleReducer(
    state,
    upsertChainTitle({
      id: 'chain_1',
      rawTitle: 'vault:v2:7e57000000000001:e1:abc',
      status: 'completed',
    }),
  );

  assert.equal(state.chains['chain_1'].status, 'completed');
  assert.equal(state.chains['chain_1'].decryptedTitle, 'Decrypted Chain 1');

  // Update with plaintext title when decryptedTitle is omitted
  state = searchTitleReducer(
    state,
    upsertChainTitle({
      id: 'chain_2',
      rawTitle: 'Plaintext Title',
    }),
  );
  assert.equal(state.chains['chain_2'].decryptedTitle, 'Plaintext Title');
});

// -----------------------------------------------------------------------------
// 3. Redux Slice: upsertConversationTitle
// -----------------------------------------------------------------------------

test('upsertConversationTitle adds and updates conversation search entries', () => {
  let state = searchTitleReducer(undefined, { type: '@@INIT' });

  state = searchTitleReducer(
    state,
    upsertConversationTitle({
      id: 'chat_1',
      rawTitle: 'vault:v2:7e57000000000001:e1:xyz',
      decryptedTitle: 'Direct Agent Chat',
      projectId: 'proj_1',
      updatedAt: '2026-09-26T12:05:00Z',
    }),
  );

  assert.ok(state.conversations['chat_1']);
  assert.equal(state.conversations['chat_1'].id, 'chat_1');
  assert.equal(state.conversations['chat_1'].type, 'conversation');
  assert.equal(state.conversations['chat_1'].decryptedTitle, 'Direct Agent Chat');

  // Selectors reflect items
  const rootState = { searchTitle: state };
  const allItems = selectAllSearchItems(rootState);
  assert.equal(allItems.length, 1);
  assert.equal(allItems[0].id, 'chat_1');
});

// -----------------------------------------------------------------------------
// 4. Redux Slice: Bulk Upsert and Clear
// -----------------------------------------------------------------------------

test('setBulkChainTitles and setBulkConversationTitles accept arrays and records and set isInitialized', () => {
  let state = searchTitleReducer(undefined, { type: '@@INIT' });

  // Bulk set chains via array
  state = searchTitleReducer(
    state,
    setBulkChainTitles([
      {
        id: 'c1',
        type: 'chain',
        rawTitle: 'Raw 1',
        decryptedTitle: 'Title 1',
        projectId: 'p1',
      },
      {
        id: 'c2',
        type: 'chain',
        rawTitle: 'Raw 2',
        decryptedTitle: 'Title 2',
        projectId: 'p1',
      },
    ]),
  );

  assert.equal(Object.keys(state.chains).length, 2);
  assert.equal(state.isInitialized, true);
  assert.equal(state.chains['c1'].decryptedTitle, 'Title 1');
  assert.equal(state.chains['c2'].decryptedTitle, 'Title 2');

  // Bulk set conversations via record object
  state = searchTitleReducer(
    state,
    setBulkConversationTitles({
      conv1: {
        id: 'conv1',
        type: 'conversation',
        rawTitle: 'Chat A',
        decryptedTitle: 'Chat A Decrypted',
      },
    }),
  );

  assert.equal(Object.keys(state.conversations).length, 1);
  assert.equal(state.conversations['conv1'].decryptedTitle, 'Chat A Decrypted');

  // Clear search titles resets everything
  state = searchTitleReducer(state, clearSearchTitles());
  assert.deepEqual(state.chains, {});
  assert.deepEqual(state.conversations, {});
  assert.equal(state.isInitialized, false);
});

// -----------------------------------------------------------------------------
// 5. Decryption Engine: decryptSearchTitle
// -----------------------------------------------------------------------------

test('decryptSearchTitle decrypts armored text or falls back to plaintext', async () => {
  const plain = 'Heimdall Task Chain Title';
  const armored = await encryptVaultText(plain, TEST_KEY_HEX);

  assert.ok(isVaultArmored(armored));

  // Decrypts correctly with matching key
  const decrypted = await decryptSearchTitle(armored, TEST_KEY_HEX);
  assert.equal(decrypted, plain);

  // Plaintext without armor returns unchanged without key
  assert.equal(await decryptSearchTitle(plain, null), plain);

  // Fallback on invalid key returns raw armored text without throwing
  const failed = await decryptSearchTitle(armored, ALT_KEY_HEX);
  assert.equal(failed, armored);
});

// -----------------------------------------------------------------------------
// 6. Decryption Engine: batchDecryptTitles in Async Batches
// -----------------------------------------------------------------------------

test('batchDecryptTitles decrypts items asynchronously in batches of 50 without blocking', async () => {
  const totalCount = 115; // 2 full batches of 50 + 1 partial batch of 15
  const rawItems = [];

  for (let i = 0; i < totalCount; i++) {
    const isEncrypted = i % 2 === 0;
    const title = `Item ${i} Title`;
    const rawTitle = isEncrypted ? await encryptVaultText(title, TEST_KEY_HEX) : title;
    rawItems.push({
      id: `item_${i}`,
      type: (i % 3 === 0 ? 'chain' : 'conversation') as 'chain' | 'conversation',
      rawTitle,
      projectId: 'proj_main',
      status: 'active',
      updatedAt: '2026-09-26T12:00:00Z',
    });
  }

  assert.equal(rawItems.length, totalCount);

  // Decrypt all items
  const decryptedItems = await batchDecryptTitles(rawItems, TEST_KEY_HEX, SEARCH_DECRYPT_BATCH_SIZE);

  assert.equal(decryptedItems.length, totalCount);

  for (let i = 0; i < totalCount; i++) {
    const item = decryptedItems[i];
    assert.equal(item.id, `item_${i}`);
    assert.equal(item.decryptedTitle, `Item ${i} Title`);
    assert.equal(item.projectId, 'proj_main');
    assert.equal(item.status, 'active');
  }
});

test('batchDecryptTitles handles empty array and null key gracefully', async () => {
  assert.deepEqual(await batchDecryptTitles([]), []);

  const items = [
    { id: '1', type: 'chain' as const, rawTitle: 'Plain 1' },
    { id: '2', type: 'conversation' as const, rawTitle: 'Plain 2' },
  ];

  const results = await batchDecryptTitles(items, null);
  assert.equal(results.length, 2);
  assert.equal(results[0].decryptedTitle, 'Plain 1');
  assert.equal(results[1].decryptedTitle, 'Plain 2');
});

// -----------------------------------------------------------------------------
// 7. WebSocket Live Updates: wsInvalidation integration
// -----------------------------------------------------------------------------

test('handleUserWsEvent dispatches upsertChainTitle when task_chain resource_changed arrives', () => {
  const dispatchedActions: any[] = [];
  const mockDispatch = (action: any) => {
    if (typeof action === 'function') {
      // In case a thunk is dispatched
      return action(mockDispatch, () => ({ vault: { isUnlocked: false } }));
    }
    dispatchedActions.push(action);
  };

  const payload = {
    type: 'resource_changed',
    resource: 'task_chain',
    resource_id: 'chain_ws_1',
    summary: {
      chain_id: 'chain_ws_1',
      title: 'Real-Time Updated Chain Title',
      project_id: 'proj_ws',
      status: 'in_progress',
    },
  };

  handleUserWsEvent(mockDispatch, payload, {});

  const upsertAction = dispatchedActions.find(
    (a) => a.type === upsertChainTitle.type,
  );

  assert.ok(upsertAction, 'upsertChainTitle must be dispatched for task_chain event');
  assert.equal(upsertAction.payload.id, 'chain_ws_1');
  assert.equal(upsertAction.payload.type, 'chain');
  assert.equal(upsertAction.payload.rawTitle, 'Real-Time Updated Chain Title');
  assert.equal(upsertAction.payload.decryptedTitle, 'Real-Time Updated Chain Title');
  assert.equal(upsertAction.payload.projectId, 'proj_ws');
});

test('handleUserWsEvent dispatches upsertConversationTitle and invalidates ConversationSummaries on conversation resource_changed', () => {
  const dispatchedActions: any[] = [];
  const mockDispatch = (action: any) => {
    if (typeof action === 'function') {
      return action(mockDispatch, () => ({ vault: { isUnlocked: false } }));
    }
    dispatchedActions.push(action);
  };

  const payload = {
    type: 'resource_changed',
    resource: 'conversation',
    resource_id: 'chat_conv_ws_1',
    summary: {
      title: 'Renamed Chat Conversation',
      project_id: 'proj_chat',
    },
  };

  handleUserWsEvent(mockDispatch, payload, {});

  const upsertAction = dispatchedActions.find(
    (a) => a.type === upsertConversationTitle.type,
  );

  assert.ok(upsertAction, 'upsertConversationTitle must be dispatched for conversation event');
  assert.equal(upsertAction.payload.id, 'chat_conv_ws_1');
  assert.equal(upsertAction.payload.type, 'conversation');
  assert.equal(upsertAction.payload.rawTitle, 'Renamed Chat Conversation');
  assert.equal(upsertAction.payload.projectId, 'proj_chat');

  // Verify ConversationSummaries cache invalidation was triggered
  const invalidateAction = dispatchedActions.find(
    (a) => a.type === 'heimdallApi/invalidateTags',
  );
  assert.ok(invalidateAction, 'heimdallApi/invalidateTags must be dispatched');
  const tags = invalidateAction.payload;
  assert.ok(
    tags.some((t: any) => t.type === 'ConversationSummaries' && t.id === 'chat_conv_ws_1'),
    'ConversationSummaries for specific conversation must be invalidated',
  );
});

test('handleUserWsEvent dispatches upsertConversationTitle on chat_event title updates', () => {
  const dispatchedActions: any[] = [];
  const mockDispatch = (action: any) => {
    if (typeof action === 'function') {
      return action(mockDispatch, () => ({ vault: { isUnlocked: false } }));
    }
    dispatchedActions.push(action);
  };

  const payload = {
    type: 'chat_event',
    agent_instance_id: 'inst_agent_1',
    conversation_id: 'chat_conv_live_1',
    title: 'Live Chat Title Update',
  };

  handleUserWsEvent(mockDispatch, payload, {});

  const upsertAction = dispatchedActions.find(
    (a) => a.type === upsertConversationTitle.type,
  );

  assert.ok(upsertAction, 'upsertConversationTitle must be dispatched for chat_event title update');
  assert.equal(upsertAction.payload.id, 'chat_conv_live_1');
  assert.equal(upsertAction.payload.rawTitle, 'Live Chat Title Update');
});

// -----------------------------------------------------------------------------
// 8. Full Redux Store Integration with Encrypted WS Event
// -----------------------------------------------------------------------------

test('Full Store: encrypted resource_changed decrypts via the active CryptoKey and updates store', async () => {
  const store = configureStore({
    reducer: {
      searchTitle: searchTitleReducer,
      vault: vaultReducer,
    },
  });

  const plainTitle = 'Encrypted Chain Title Over WS';
  const armoredTitle = await encryptVaultText(plainTitle, TEST_KEY_HEX);

  // Install the key the PRODUCTION way so the background decryption in
  // wsInvalidation.ts:380 can resolve it. This used to call writeSessionVaultKey(hex),
  // which is now a hardened no-op -- the test therefore asserted a decrypted title while
  // the store legitimately held `vault:v2:7e57000000000001:e1:...`, i.e. it was failing for the mechanism and
  // not for the behaviour under test (REQ-VAULT-HARDEN-1, REQ-RAWKEY-A8).
  setActiveVaultKey(await keyringFromHex(TEST_KEY_HEX_RAW), null);

  const payload = {
    type: 'resource_changed',
    resource: 'task_chain',
    resource_id: 'chain_encrypted_ws',
    summary: {
      chain_id: 'chain_encrypted_ws',
      title: armoredTitle,
      project_id: 'proj_enc',
      status: 'active',
    },
  };

  handleUserWsEvent(store.dispatch, payload, {});

  // Wait a tick for async decryption promise
  await new Promise((r) => setTimeout(r, 50));

  const state = store.getState().searchTitle;
  const item = state.chains['chain_encrypted_ws'];

  assert.ok(item, 'Item must be present in searchTitle chains state');
  assert.equal(item.id, 'chain_encrypted_ws');
  assert.equal(item.rawTitle, armoredTitle);
  assert.equal(item.decryptedTitle, plainTitle);
  assert.equal(item.projectId, 'proj_enc');

  // The active key is MODULE-level state shared by every test in this file; leaving it set
  // would silently arm any later "no key" case.
  setActiveVaultKey(null, null);
});
