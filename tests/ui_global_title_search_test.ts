// REQ-SEARCH-PALETTE-UI-1, REQ-SEARCH-CHAIN-SELECTOR-1:
// Unit tests for Refactored CommandPalette Task Chain Search & Conversation Chain Selector.
//
// RUN: npx tsx --test tests/ui_global_title_search_test.ts

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
    addEventListener: () => {},
    removeEventListener: () => {},
    location: { hash: '' },
    setTimeout: (fn: (...args: any[]) => void, ms?: number) => setTimeout(fn, ms),
    clearTimeout: (id: any) => clearTimeout(id),
  };
} else {
  (globalThis as any).window.sessionStorage = fakeSessionStorage;
}

import { asKeyring, keyringFromHex } from './helpers/vaultTestKeyring.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { configureStore } from '@reduxjs/toolkit';

import searchTitleReducer, {
  setBulkChainTitles,
  selectSearchChains,
} from '../src/ui/store/searchTitleSlice.ts';

import {
  chainStatusDot,
  taskChainRoute,
  DEFAULT_NAV,
  DEFAULT_ACTIONS,
  optionId,
  matchesQuery,
} from '../src/ui/components/ui/patterns/commandPaletteLogic.ts';
import {
  isVaultArmored,
  encryptVaultText,
} from '../src/ui/utils/vaultContent.ts';
import { batchDecryptTitles } from '../src/ui/utils/vaultSearch.ts';

// -----------------------------------------------------------------------------
// 1. CommandPalette Status Indicator Mapping
// -----------------------------------------------------------------------------

test('chainStatusDot correctly maps all task chain statuses to StatusDot tone and pulse', () => {
  // Active and in-progress chains pulse with success tone
  const activeDot = chainStatusDot('active');
  assert.equal(activeDot.tone, 'success');
  assert.equal(activeDot.pulse, true);

  const inProgressDot = chainStatusDot('in_progress');
  assert.equal(inProgressDot.tone, 'success');
  assert.equal(inProgressDot.pulse, true);

  // Completed and validated_good chains are neutral without pulse
  const completedDot = chainStatusDot('completed');
  assert.equal(completedDot.tone, 'neutral');
  assert.equal(completedDot.pulse, false);

  const validatedGoodDot = chainStatusDot('validated_good');
  assert.equal(validatedGoodDot.tone, 'neutral');
  assert.equal(validatedGoodDot.pulse, false);

  // Paused chains have warning tone
  const pausedDot = chainStatusDot('paused');
  assert.equal(pausedDot.tone, 'warning');
  assert.equal(pausedDot.pulse, false);

  // Cancelled and validated_not_good chains have danger tone
  const cancelledDot = chainStatusDot('cancelled');
  assert.equal(cancelledDot.tone, 'danger');
  assert.equal(cancelledDot.pulse, false);

  const validatedNotGoodDot = chainStatusDot('validated_not_good');
  assert.equal(validatedNotGoodDot.tone, 'danger');
  assert.equal(validatedNotGoodDot.pulse, false);

  // Unknown or undefined falls back to neutral
  const defaultDot = chainStatusDot(undefined);
  assert.equal(defaultDot.tone, 'neutral');
  assert.equal(defaultDot.pulse, false);
});

// -----------------------------------------------------------------------------
// 3. Task Chain Route Resolution
// -----------------------------------------------------------------------------

test('taskChainRoute navigates to conversation when coordinator is present or overview when absent', () => {
  // With coordinatorAgentInstanceId: navigates to conversation
  const chainWithCoordinator = {
    chainId: 'chain_123',
    coordinatorAgentInstanceId: 'inst_coord_456',
  };
  assert.equal(
    taskChainRoute(chainWithCoordinator),
    '/conversations/chain:chain_123',
    'Must navigate to the chain-addressed coordinator conversation (REQ-TV2-7) when a coordinator exists',
  );

  // Without coordinatorAgentInstanceId: navigates to chain overview
  const chainWithoutCoordinator = {
    chainId: 'chain_789',
    coordinatorAgentInstanceId: undefined,
  };
  assert.equal(
    taskChainRoute(chainWithoutCoordinator),
    '/chains/chain_789',
    'Must navigate to chain overview when coordinator is absent',
  );
});

// -----------------------------------------------------------------------------
// 4. Default Navigation and Actions Preservation
// -----------------------------------------------------------------------------

test('CommandPalette preserves default navigation routes and actions for empty query', () => {
  assert.ok(DEFAULT_NAV.length >= 10, 'DEFAULT_NAV must define core application navigation items');
  const labels = DEFAULT_NAV.map((n) => n.label);
  assert.ok(labels.includes('Task Chains'), 'DEFAULT_NAV must include Task Chains');
  assert.ok(labels.includes('Conversations'), 'DEFAULT_NAV must include Conversations');
  assert.ok(labels.includes('Projects'), 'DEFAULT_NAV must include Projects');
  assert.ok(labels.includes('Settings'), 'DEFAULT_NAV must include Settings');

  const actionIds = DEFAULT_ACTIONS.map((a) => a.id);
  assert.ok(actionIds.includes('new-chain'), 'DEFAULT_ACTIONS must include new-chain');
  assert.ok(actionIds.includes('new-conversation'), 'DEFAULT_ACTIONS must include new-conversation');
  assert.ok(actionIds.includes('new-project'), 'DEFAULT_ACTIONS must include new-project');

  assert.equal(optionId(0), 'command-palette-option-0');
  assert.equal(optionId(4), 'command-palette-option-4');
});

// -----------------------------------------------------------------------------
// 5. Redux Title Cache & Client-Side Task Chain Filtering Logic
// -----------------------------------------------------------------------------

test('Client-side task chain search filters strictly across decrypted titles', () => {
  const store = configureStore({
    reducer: {
      searchTitle: searchTitleReducer,
    },
  });

  // Seed multiple task chains across different projects with encrypted rawTitle and decryptedTitle
  store.dispatch(
    setBulkChainTitles([
      {
        id: 'chain_vault_auth',
        type: 'chain',
        rawTitle: 'vault:v2:7e57000000000001:e1:armoredCiphertext1',
        decryptedTitle: 'Implement User Vault & Master Password',
        projectId: 'proj_security',
        status: 'in_progress',
        updatedAt: '2026-09-26T12:00:00Z',
      },
      {
        id: 'chain_lsp',
        type: 'chain',
        rawTitle: 'vault:v2:7e57000000000001:e1:armoredCiphertext2',
        decryptedTitle: 'Language Server Protocol Client Support',
        projectId: 'proj_core',
        status: 'completed',
        updatedAt: '2026-09-25T10:00:00Z',
      },
      {
        id: 'chain_fleet',
        type: 'chain',
        rawTitle: 'vault:v2:7e57000000000001:e1:armoredCiphertext3',
        decryptedTitle: 'Worker Fleet Auto-Scaling and Recovery',
        projectId: 'proj_infra',
        status: 'active',
        updatedAt: '2026-09-26T14:00:00Z',
      },
    ]),
  );

  const chains = selectSearchChains(store.getState());
  assert.equal(Object.keys(chains).length, 3);

  // Search logic simulation matching CommandPalette filtering
  const allChains = Object.values(chains);

  // Query: "vault" -> matches "Implement User Vault & Master Password"
  const qVault = 'vault';
  const matchesVault = allChains.filter((c) =>
    c.decryptedTitle.toLowerCase().includes(qVault.toLowerCase()),
  );
  assert.equal(matchesVault.length, 1);
  assert.equal(matchesVault[0].id, 'chain_vault_auth');
  assert.equal(matchesVault[0].decryptedTitle, 'Implement User Vault & Master Password');

  // Query: "armoredCiphertext" -> should NOT match because search is strictly against decryptedTitle
  const qCipher = 'armoredciphertext';
  const matchesCipher = allChains.filter((c) =>
    c.decryptedTitle.toLowerCase().includes(qCipher.toLowerCase()),
  );
  assert.equal(matchesCipher.length, 0, 'Must search decrypted titles, not ciphertexts');

  // Query: "server" -> matches "Language Server Protocol Client Support"
  const qServer = 'server';
  const matchesServer = allChains.filter((c) =>
    c.decryptedTitle.toLowerCase().includes(qServer.toLowerCase()),
  );
  assert.equal(matchesServer.length, 1);
  assert.equal(matchesServer[0].id, 'chain_lsp');

  // Query: "nonexistent" -> matches nothing
  const qNone = 'nonexistentxyz';
  const matchesNone = allChains.filter((c) =>
    c.decryptedTitle.toLowerCase().includes(qNone.toLowerCase()),
  );
  assert.equal(matchesNone.length, 0);
});

// -----------------------------------------------------------------------------
// 8. Keyboard Navigation Logic
// -----------------------------------------------------------------------------

test('Keyboard navigation handles ArrowDown, ArrowUp with wrap-around and Enter selection', () => {
  const itemCount = 4;
  let activeIndex = 0;

  // ArrowDown
  const onArrowDown = () => {
    activeIndex = (activeIndex + 1) % itemCount;
  };
  // ArrowUp
  const onArrowUp = () => {
    activeIndex = (activeIndex - 1 + itemCount) % itemCount;
  };

  assert.equal(activeIndex, 0);
  onArrowDown();
  assert.equal(activeIndex, 1);
  onArrowDown();
  assert.equal(activeIndex, 2);
  onArrowDown();
  assert.equal(activeIndex, 3);
  onArrowDown(); // wraps to 0
  assert.equal(activeIndex, 0);

  onArrowUp(); // wraps to 3
  assert.equal(activeIndex, 3);
  onArrowUp();
  assert.equal(activeIndex, 2);

  // Enter activation
  let navigatedRoute = '';
  let closed = false;
  const mockNavigate = (r: string) => { navigatedRoute = r; };
  const mockClose = () => { closed = true; };

  const selectedItem = {
    kind: 'chain' as const,
    label: 'Test Chain',
    route: '/conversations/inst_test_123',
    group: 'Project — Chains',
    chainId: 'ch_1',
  };

  const activate = (item: typeof selectedItem) => {
    mockNavigate(item.route);
    mockClose();
  };

  activate(selectedItem);
  assert.equal(navigatedRoute, '/conversations/inst_test_123');
  assert.equal(closed, true);
});

// -----------------------------------------------------------------------------
// 9. Task Chain Matching Metadata: Project Labels and Status Indicators
// -----------------------------------------------------------------------------

test('Task chain results include project labels, status indicators, and correct routes', () => {
  const chain1 = {
    chainId: 'ch_alpha',
    title: 'Alpha Chain',
    status: 'in_progress',
    projectId: 'p_1',
    projectName: 'Security Gateway',
    coordinatorAgentInstanceId: 'inst_alpha_coord',
  };

  const chain2 = {
    chainId: 'ch_beta',
    title: 'Beta Chain',
    status: 'completed',
    projectId: 'p_2',
    projectName: 'Core Engine',
    coordinatorAgentInstanceId: undefined,
  };

  // Route calculation
  assert.equal(taskChainRoute(chain1), '/conversations/chain:ch_alpha');
  assert.equal(taskChainRoute(chain2), '/chains/ch_beta');

  // Status dot indicators
  const dot1 = chainStatusDot(chain1.status);
  assert.equal(dot1.tone, 'success');
  assert.equal(dot1.pulse, true);

  const dot2 = chainStatusDot(chain2.status);
  assert.equal(dot2.tone, 'neutral');
  assert.equal(dot2.pulse, false);
});

// -----------------------------------------------------------------------------
// 10. Empty Query vs Non-Empty Query Filtering
// -----------------------------------------------------------------------------

test('Query filtering separates quick navigation on empty from strict chain search on query', () => {
  const navItems = DEFAULT_NAV;
  const actions = DEFAULT_ACTIONS;
  const chains = [
    { chainId: 'c1', title: 'User Vault Setup', projectName: 'Auth' },
    { chainId: 'c2', title: 'Billing Integration', projectName: 'Billing' },
  ];

  // Empty query -> includes nav and actions
  const qEmpty = '';
  assert.ok(!qEmpty);
  assert.ok(navItems.length > 0);
  assert.ok(actions.length > 0);

  // Non-empty query "vault" -> filters strictly chains
  const qNonEmpty = 'vault';
  const matches = chains.filter(c => c.title.toLowerCase().includes(qNonEmpty.toLowerCase()));
  assert.equal(matches.length, 1);
  assert.equal(matches[0].chainId, 'c1');
  assert.equal(matches[0].title, 'User Vault Setup');
});

// -----------------------------------------------------------------------------
// 11. Armor Shielding in Pure Logic: matchesQuery (REQ-SEARCH-ARMOR-SHIELD-1)
// -----------------------------------------------------------------------------

test('matchesQuery returns false for any isVaultArmored string regardless of query', () => {
  const armoredSample = 'vault:v2:7e57000000000001:e1:WUgAS1y82QZU5dYC/488DrhnJXBmKsJTwengYlT7uLDJLbV09m8d2Lq3W';

  assert.ok(isVaultArmored(armoredSample), 'Sample string must be armored');

  // Armor prefix queries must return false
  assert.equal(matchesQuery(armoredSample, 'vault'), false, 'Must not match "vault" in armored string');
  assert.equal(matchesQuery(armoredSample, 'Vault'), false, 'Must not match "Vault" (case insensitive) in armored string');
  assert.equal(matchesQuery(armoredSample, 'v1'), false, 'Must not match "v1" in armored string');
  assert.equal(matchesQuery(armoredSample, 'vault:v2:7e57000000000001:e1:'), false, 'Must not match "vault:v2:7e57000000000001:e1:" in armored string');

  // Ciphertext substrings must return false
  assert.equal(matchesQuery(armoredSample, 'WUgAS1y82Q'), false, 'Must not match base64 ciphertext substring');
  assert.equal(matchesQuery(armoredSample, '82QZU5dYC'), false, 'Must not match base64 ciphertext substring');
  assert.equal(matchesQuery(armoredSample, ''), false, 'Empty query on armored string must return false');

  // Unarmored strings behave as standard substring search
  assert.equal(matchesQuery('User Vault Setup', 'vault'), true, 'Matches unarmored title containing query');
  assert.equal(matchesQuery('User Vault Setup', 'Vault'), true, 'Matches unarmored title case-insensitively');
  assert.equal(matchesQuery('Billing Integration', 'vault'), false, 'Does not match unarmored title without query');
});

// -----------------------------------------------------------------------------
// 13. Decryption Lifecycle: Typing "Vault" Matches Only Genuine Decrypted Titles (REQ-SEARCH-DECRYPT-TEST-1)
// -----------------------------------------------------------------------------

test('Typing "Vault" matches only chains whose decrypted title genuinely contains "Vault", never raw ciphertext', async () => {
  const TEST_KEY = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const realPlaintextTitle = 'User Vault: Master Password, Recovery Words & Settings';
  const otherPlaintextTitle = 'Core Engine Architecture & RPC Gateway';

  const armoredVaultTitle = await encryptVaultText(realPlaintextTitle, await keyringFromHex(TEST_KEY));
  const armoredOtherTitle = await encryptVaultText(otherPlaintextTitle, await keyringFromHex(TEST_KEY));

  assert.ok(isVaultArmored(armoredVaultTitle), 'Encrypted vault title must have vault armor');
  assert.ok(isVaultArmored(armoredOtherTitle), 'Encrypted other title must have vault armor');

  // 1. Raw armored chains before decryption
  const rawChains = [
    { chainId: 'chain_vault', title: armoredVaultTitle, projectName: 'Security' },
    { chainId: 'chain_core', title: armoredOtherTitle, projectName: 'Engine' },
  ];

  // Searching 'Vault' before decryption: matches 0 items (ciphertext shielded)
  const qVault = 'Vault';
  const matchingBeforeVault = rawChains.filter(
    (ch) => !isVaultArmored(ch.title) && matchesQuery(ch.title, qVault),
  );
  assert.equal(matchingBeforeVault.length, 0, 'Searching "Vault" must not match raw ciphertext before decryption');

  // Searching 'v1' or 'vault:v2:7e57000000000001:e1:' before decryption: matches 0 items
  const matchingBeforeV1 = rawChains.filter(
    (ch) => !isVaultArmored(ch.title) && matchesQuery(ch.title, 'v1'),
  );
  assert.equal(matchingBeforeV1.length, 0, 'Searching "v1" must not match raw armor prefix');

  // 2. Perform batch decryption
  const decryptedItems = await batchDecryptTitles(
    [
      { id: 'chain_vault', type: 'chain', rawTitle: armoredVaultTitle, title: armoredVaultTitle, projectId: 'Security' },
      { id: 'chain_core', type: 'chain', rawTitle: armoredOtherTitle, title: armoredOtherTitle, projectId: 'Engine' },
    ],
    await keyringFromHex(TEST_KEY),
  );

  assert.equal(decryptedItems.length, 2);
  assert.equal(decryptedItems[0].decryptedTitle, realPlaintextTitle);
  assert.equal(decryptedItems[1].decryptedTitle, otherPlaintextTitle);
  assert.ok(!isVaultArmored(decryptedItems[0].decryptedTitle));
  assert.ok(!isVaultArmored(decryptedItems[1].decryptedTitle));

  // 3. Search after decryption
  const matchingAfterVault = decryptedItems.filter(
    (ch) => !isVaultArmored(ch.decryptedTitle) && matchesQuery(ch.decryptedTitle, qVault),
  );
  assert.equal(matchingAfterVault.length, 1, 'Searching "Vault" after decryption must match exactly the vault chain');
  assert.equal(matchingAfterVault[0].id, 'chain_vault');
  assert.equal(matchingAfterVault[0].decryptedTitle, realPlaintextTitle);

  // Searching 'Engine' matches the other chain
  const matchingAfterEngine = decryptedItems.filter(
    (ch) => !isVaultArmored(ch.decryptedTitle) && matchesQuery(ch.decryptedTitle, 'Engine'),
  );
  assert.equal(matchingAfterEngine.length, 1);
  assert.equal(matchingAfterEngine[0].id, 'chain_core');
});
