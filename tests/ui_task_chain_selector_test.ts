// REQ-CHAIN-SELECTOR-MODAL-1, REQ-CHAIN-SELECTOR-SCALABILITY-1, REQ-CHAIN-SELECTOR-VAULT-1, REQ-CONVO-CHAIN-CLICK-1, REQ-CHAIN-SELECTOR-TEST-1, REQ-CHAIN-SELECTOR-MOBILE-1, REQ-CHAIN-SELECTOR-MOBILE-2, REQ-CHAIN-SELECTOR-MOBILE-3, REQ-CHAIN-SELECTOR-MOBILE-4:
// Comprehensive unit tests for Dedicated Task Chain Selector Modal with Prepopulated Lists, Scalability, and Mobile Responsive Layout.
//
// RUN: node --test tests/ui_task_chain_selector_test.ts

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
import React from 'react';

import {
  prepareChainSelectorItems,
  filterTaskChains,
  findInitialActiveIndex,
  navigateIndex,
  selectionDirectionForEvent,
  sortChainSelectorItems,
  INITIAL_VISIBLE_COUNT,
  type ChainSelectorItem,
} from '../src/ui/components/chains/taskChainSelectorLogic.ts';
import type { ChainProjectGroup } from '../src/ui/api/endpoints/tasks.ts';
import { taskChainRoute } from '../src/ui/components/ui/patterns/commandPaletteLogic.ts';
import { isVaultArmored, encryptVaultText } from '../src/ui/utils/vaultContent.ts';
import { batchDecryptTitles } from '../src/ui/utils/vaultSearch.ts';

// -----------------------------------------------------------------------------
// 2. Prepopulation Tests (REQ-CHAIN-SELECTOR-MODAL-1)
// -----------------------------------------------------------------------------

test('TaskChainSelectorModal prepopulates all task chains across projects without query input', () => {
  const mockGroups: ChainProjectGroup[] = [
    {
      projectId: 'proj_alpha',
      projectName: 'Alpha Core',
      chains: [
        {
          chainId: 'chain_a1',
          title: 'RPC Protocol Gateway',
          status: 'active',
          updatedAt: '2026-09-20T10:00:00Z',
          coordinatorAgentInstanceId: 'inst_coord_a1',
          projectId: 'proj_alpha',
          projectName: 'Alpha Core',
          taskCount: 5,
          completedTaskCount: 3,
          userValidationCount: 0,
          hasUserValidation: false,
          isPinned: false,
          pinnedAt: '',
        },
        {
          chainId: 'chain_a2',
          title: 'Memory Optimization Routine',
          status: 'in_progress',
          updatedAt: '2026-09-21T10:00:00Z',
          coordinatorAgentInstanceId: 'inst_coord_a2',
          projectId: 'proj_alpha',
          projectName: 'Alpha Core',
          taskCount: 2,
          completedTaskCount: 1,
          userValidationCount: 0,
          hasUserValidation: false,
          isPinned: false,
          pinnedAt: '',
        },
      ],
      chainTotal: 2,
      hasMore: false,
      nextCursor: '',
    },
    {
      projectId: 'proj_beta',
      projectName: 'Beta UI',
      chains: [
        {
          chainId: 'chain_b1',
          title: 'User Vault Dashboard',
          status: 'completed',
          updatedAt: '2026-09-22T10:00:00Z',
          coordinatorAgentInstanceId: 'inst_coord_b1',
          projectId: 'proj_beta',
          projectName: 'Beta UI',
          taskCount: 8,
          completedTaskCount: 8,
          userValidationCount: 1,
          hasUserValidation: true,
          isPinned: true,
          pinnedAt: '2026-09-22T11:00:00Z',
        },
      ],
      chainTotal: 1,
      hasMore: false,
      nextCursor: '',
    },
  ];

  const items = prepareChainSelectorItems(mockGroups, {});

  // Prepopulated items must contain all chains across all projects
  assert.equal(items.length, 3, 'Prepopulated items must include all 3 chains across projects');
  assert.equal(items[0].chainId, 'chain_a1');
  assert.equal(items[0].projectName, 'Alpha Core');
  assert.equal(items[1].chainId, 'chain_a2');
  assert.equal(items[2].chainId, 'chain_b1');
  assert.equal(items[2].projectName, 'Beta UI');

  const sorted = sortChainSelectorItems(items);
  assert.deepEqual(sorted.map((item) => item.chainId), ['chain_b1', 'chain_a2', 'chain_a1']);
  assert.deepEqual(items.map((item) => item.chainId), ['chain_a1', 'chain_a2', 'chain_b1']);

});

// -----------------------------------------------------------------------------
// 3. Current Chain Identification and Badging (REQ-CHAIN-SELECTOR-MODAL-1)
// -----------------------------------------------------------------------------

test('Current chain is properly identified, marked with isCurrent, and selected by default', () => {
  const mockGroups: ChainProjectGroup[] = [
    {
      projectId: 'proj_main',
      projectName: 'Main Project',
      chains: [
        {
          chainId: 'chain_1',
          title: 'First Chain',
          status: 'completed',
          updatedAt: '2026-09-01T00:00:00Z',
          coordinatorAgentInstanceId: 'inst_1',
          projectId: 'proj_main',
          projectName: 'Main Project',
          taskCount: 1,
          completedTaskCount: 1,
          userValidationCount: 0,
          hasUserValidation: false,
          isPinned: false,
          pinnedAt: '',
        },
        {
          chainId: 'chain_target',
          title: 'Target Active Chain',
          status: 'in_progress',
          updatedAt: '2026-09-02T00:00:00Z',
          coordinatorAgentInstanceId: 'inst_target',
          projectId: 'proj_main',
          projectName: 'Main Project',
          taskCount: 4,
          completedTaskCount: 2,
          userValidationCount: 0,
          hasUserValidation: false,
          isPinned: false,
          pinnedAt: '',
        },
        {
          chainId: 'chain_3',
          title: 'Third Chain',
          status: 'queued',
          updatedAt: '2026-09-03T00:00:00Z',
          coordinatorAgentInstanceId: '',
          projectId: 'proj_main',
          projectName: 'Main Project',
          taskCount: 3,
          completedTaskCount: 0,
          userValidationCount: 0,
          hasUserValidation: false,
          isPinned: false,
          pinnedAt: '',
        },
      ],
      chainTotal: 3,
      hasMore: false,
      nextCursor: '',
    },
  ];

  const currentChainId = 'chain_target';
  const items = prepareChainSelectorItems(mockGroups, {}, currentChainId);

  assert.equal(items[0].isCurrent, false);
  assert.equal(items[1].isCurrent, true, 'chain_target must have isCurrent=true');
  assert.equal(items[2].isCurrent, false);

  // findInitialActiveIndex returns target index
  const activeIdx = findInitialActiveIndex(items, currentChainId);
  assert.equal(activeIdx, 1, 'Initial active index must focus on current chain');

  // Fallback when currentChainId is not present
  const fallbackIdx = findInitialActiveIndex(items, 'nonexistent_chain');
  assert.equal(fallbackIdx, 0, 'Initial active index defaults to 0 when current chain not in list');
});

// -----------------------------------------------------------------------------
// 4. Live Search Filtering (REQ-CHAIN-SELECTOR-MODAL-1)
// -----------------------------------------------------------------------------

test('Live search filter filters chains by decrypted title, project name, or chain ID', () => {
  const items: ChainSelectorItem[] = [
    {
      chainId: 'chain_vault_setup',
      title: 'Zero-Knowledge Vault Setup & Recovery Words',
      rawTitle: 'Zero-Knowledge Vault Setup & Recovery Words',
      status: 'in_progress',
      projectId: 'proj_sec',
      projectName: 'Security & Auth',
      coordinatorAgentInstanceId: 'inst_sec_coord',
    },
    {
      chainId: 'chain_billing',
      title: 'Stripe Billing Webhooks Integration',
      rawTitle: 'Stripe Billing Webhooks Integration',
      status: 'active',
      projectId: 'proj_finance',
      projectName: 'Finance & Payments',
      coordinatorAgentInstanceId: 'inst_fin_coord',
    },
    {
      chainId: 'chain_lsp_diagnostics',
      title: 'Language Server Protocol Diagnostic Publisher',
      rawTitle: 'Language Server Protocol Diagnostic Publisher',
      status: 'completed',
      projectId: 'proj_editor',
      projectName: 'Developer Experience',
      coordinatorAgentInstanceId: 'inst_dx_coord',
    },
  ];

  // 1. Filter by decrypted title keyword
  const resultsVault = filterTaskChains(items, 'vault');
  assert.equal(resultsVault.length, 1);
  assert.equal(resultsVault[0].chainId, 'chain_vault_setup');

  const resultsRecovery = filterTaskChains(items, 'Recovery Words');
  assert.equal(resultsRecovery.length, 1);
  assert.equal(resultsRecovery[0].chainId, 'chain_vault_setup');

  // 2. Filter by project name
  const resultsFinance = filterTaskChains(items, 'Finance');
  assert.equal(resultsFinance.length, 1);
  assert.equal(resultsFinance[0].chainId, 'chain_billing');

  // 3. Filter by chain ID
  const resultsId = filterTaskChains(items, 'chain_lsp');
  assert.equal(resultsId.length, 1);
  assert.equal(resultsId[0].chainId, 'chain_lsp_diagnostics');

  // 4. Empty query returns all
  const resultsEmpty = filterTaskChains(items, '   ');
  assert.equal(resultsEmpty.length, 3);

  // 5. Non-matching query returns empty
  const resultsNone = filterTaskChains(items, 'nonexistentquery123');
  assert.equal(resultsNone.length, 0);
});

// -----------------------------------------------------------------------------
// 5. Armor Shielding Guard (REQ-CHAIN-SELECTOR-VAULT-1)
// -----------------------------------------------------------------------------

test('Armor shielding: raw vault:v2:7e57000000000001:e1:... ciphertext never matches search queries', async () => {
  const TEST_KEY = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const plaintextTitle = 'Master Password Vault Key Storage';
  const otherPlaintext = 'General Hub Infrastructure';

  const armoredVaultTitle = await encryptVaultText(plaintextTitle, await keyringFromHex(TEST_KEY));
  const armoredOtherTitle = await encryptVaultText(otherPlaintext, await keyringFromHex(TEST_KEY));

  assert.ok(isVaultArmored(armoredVaultTitle), 'Vault title must be armored');

  // Prior to decryption, chains have armored titles
  const armoredItems: ChainSelectorItem[] = [
    {
      chainId: 'chain_sec_1',
      title: armoredVaultTitle,
      rawTitle: armoredVaultTitle,
      status: 'active',
      projectId: 'proj_sec',
      projectName: 'Core Security',
    },
    {
      chainId: 'chain_infra_2',
      title: armoredOtherTitle,
      rawTitle: armoredOtherTitle,
      status: 'in_progress',
      projectId: 'proj_infra',
      projectName: 'Infrastructure',
    },
  ];

  // Searching "Vault" BEFORE decryption MUST yield 0 matches from ciphertext
  const matchBefore = filterTaskChains(armoredItems, 'Vault');
  assert.equal(
    matchBefore.length,
    0,
    'Searching "Vault" must not match raw ciphertext before decryption',
  );

  // Searching "vault:v2:7e57000000000001:e1:" or "v1" prefix MUST yield 0 matches
  const matchPrefix = filterTaskChains(armoredItems, 'vault:v2:7e57000000000001:e1:');
  assert.equal(matchPrefix.length, 0, 'Must not match "vault:v2:7e57000000000001:e1:" prefix');

  const matchV1 = filterTaskChains(armoredItems, 'v1');
  assert.equal(matchV1.length, 0, 'Must not match "v1" token');

  // Perform decryption simulation via batchDecryptTitles
  const decryptedItems = await batchDecryptTitles(
    [
      {
        id: 'chain_sec_1',
        type: 'chain',
        rawTitle: armoredVaultTitle,
        title: armoredVaultTitle,
        projectId: 'proj_sec',
      },
    ],
    await keyringFromHex(TEST_KEY),
  );

  assert.equal(decryptedItems[0].decryptedTitle, plaintextTitle);

  // After updating the chain with the decrypted title
  const decryptedChainItems: ChainSelectorItem[] = [
    {
      chainId: 'chain_sec_1',
      title: decryptedItems[0].decryptedTitle,
      rawTitle: armoredVaultTitle,
      status: 'active',
      projectId: 'proj_sec',
      projectName: 'Core Security',
    },
  ];

  // Searching "Vault" AFTER decryption matches genuine plaintext
  const matchAfter = filterTaskChains(decryptedChainItems, 'Vault');
  assert.equal(matchAfter.length, 1);
  assert.equal(matchAfter[0].chainId, 'chain_sec_1');
  assert.equal(matchAfter[0].title, plaintextTitle);
});

// -----------------------------------------------------------------------------
// 6. Scalability & Performance Budget (REQ-CHAIN-SELECTOR-SCALABILITY-1)
// -----------------------------------------------------------------------------

test('Scalability: smoothly handles 500+ task chains within <16ms performance budget', () => {
  // Generate a realistic fixture with 550 mock task chains across 12 projects
  const TOTAL_CHAINS = 550;
  const PROJECT_COUNT = 12;

  const mockGroups: ChainProjectGroup[] = [];
  for (let p = 0; p < PROJECT_COUNT; p++) {
    const projectId = `proj_${p}`;
    const projectName = `Enterprise Project ${p}`;
    const chainsInProj = Math.floor(TOTAL_CHAINS / PROJECT_COUNT) + (p === 0 ? TOTAL_CHAINS % PROJECT_COUNT : 0);

    const chains: any[] = [];
    for (let c = 0; c < chainsInProj; c++) {
      const idx = chains.length + p * 50;
      chains.push({
        chainId: `chain_${p}_${c}`,
        title: `Task Chain Execution Routine #${idx} - Subsystem ${p}`,
        status: idx % 4 === 0 ? 'active' : idx % 4 === 1 ? 'in_progress' : idx % 4 === 2 ? 'completed' : 'queued',
        updatedAt: new Date(Date.now() - idx * 60000).toISOString(),
        coordinatorAgentInstanceId: `inst_coord_${p}_${c}`,
        projectId,
        projectName,
        taskCount: 10 + (idx % 20),
        completedTaskCount: idx % 10,
        userValidationCount: 0,
        hasUserValidation: false,
        isPinned: idx % 10 === 0,
        pinnedAt: '',
      });
    }

    mockGroups.push({
      projectId,
      projectName,
      chains,
      chainTotal: chains.length,
      hasMore: false,
      nextCursor: '',
    });
  }

  // 1. Measure preparation time for 550 chains
  const startPrep = performance.now();
  const allChains = prepareChainSelectorItems(mockGroups, {}, 'chain_5_10');
  const elapsedPrep = performance.now() - startPrep;

  assert.equal(allChains.length, TOTAL_CHAINS, `Must prepopulate all ${TOTAL_CHAINS} chains`);
  assert.ok(
    elapsedPrep < 16,
    `prepareChainSelectorItems must complete in <16ms (actual: ${elapsedPrep.toFixed(2)}ms)`,
  );

  // 2. Measure search filtering performance on 550 chains
  const startFilter = performance.now();
  const filtered = filterTaskChains(allChains, 'Routine #42');
  const elapsedFilter = performance.now() - startFilter;

  assert.ok(filtered.length >= 1, 'Search query must find matching chain');
  assert.ok(
    elapsedFilter < 16,
    `filterTaskChains across 550 items must complete in <16ms (actual: ${elapsedFilter.toFixed(2)}ms)`,
  );

  // 3. Verify progressive slicing window
  assert.equal(INITIAL_VISIBLE_COUNT, 80, 'Initial progressive slice size must be 80');
  const visibleSlice = allChains.slice(0, INITIAL_VISIBLE_COUNT);
  assert.equal(visibleSlice.length, 80, 'Initial visible slice must contain exactly 80 items');

  // Sorting a visible window keeps each row in one flat array.
  assert.equal(sortChainSelectorItems(visibleSlice).length, INITIAL_VISIBLE_COUNT);

});

// -----------------------------------------------------------------------------
// 7. Keyboard Navigation & Routing (REQ-CHAIN-SELECTOR-MODAL-1)
// -----------------------------------------------------------------------------

test('Keyboard navigation handles ArrowDown, ArrowUp with wrapping and Enter route selection', () => {
  const TOTAL = 5;

  // ArrowDown forward step
  assert.equal(navigateIndex(0, TOTAL, 'down'), 1);
  assert.equal(navigateIndex(1, TOTAL, 'down'), 2);

  // ArrowDown wrap-around at bottom
  assert.equal(navigateIndex(4, TOTAL, 'down'), 0, 'ArrowDown at bottom must wrap to top (0)');

  // ArrowUp backward step
  assert.equal(navigateIndex(3, TOTAL, 'up'), 2);

  // ArrowUp wrap-around at top
  assert.equal(navigateIndex(0, TOTAL, 'up'), 4, 'ArrowUp at top must wrap to bottom (4)');

  // Selection routing: with coordinator vs overview
  const chainWithCoord = {
    chainId: 'chain_test_coord',
    coordinatorAgentInstanceId: 'inst_engineer_99',
  };
  assert.equal(
    taskChainRoute(chainWithCoord),
    '/conversations/chain:chain_test_coord',
    'Selecting chain with coordinator navigates to its chain-addressed conversation',
  );

  const chainWithoutCoord = {
    chainId: 'chain_test_nocoord',
  };
  assert.equal(
    taskChainRoute(chainWithoutCoord),
    '/chains/chain_test_nocoord',
    'Selecting chain without coordinator navigates to chain overview',
  );
});

test('selection keys map arrows and Ctrl-N/Ctrl-P without Meta or Alt', () => {
  const event = (key: string, ctrlKey = false, metaKey = false, altKey = false) => ({ key, ctrlKey, metaKey, altKey });
  assert.equal(selectionDirectionForEvent(event('ArrowDown')), 'down');
  assert.equal(selectionDirectionForEvent(event('ArrowUp')), 'up');
  assert.equal(selectionDirectionForEvent(event('n', true)), 'down');
  assert.equal(selectionDirectionForEvent(event('P', true)), 'up');
  assert.equal(selectionDirectionForEvent(event('n')), null);
  assert.equal(selectionDirectionForEvent(event('n', true, true)), null);
  assert.equal(selectionDirectionForEvent(event('p', true, false, true)), null);
  assert.equal(navigateIndex(0, 0, 'down'), 0, 'empty lists remain stable');
});

test('search errors without an installed key name no password, unlock or re-entry step', async () => {
  const { taskChainSearchErrorMessage } = await import('../src/ui/utils/taskChainSearch.ts');
  for (const code of ['vault_locked', 'search_key_unavailable']) {
    const msg = taskChainSearchErrorMessage({ code });
    assert.doesNotMatch(msg, /password|unlock|re-enter/i, code);
    assert.notEqual(msg, taskChainSearchErrorMessage({ code: 'unknown_code' }), `${code} has its own message`);
  }
});
