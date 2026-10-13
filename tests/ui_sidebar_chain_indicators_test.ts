// REQ-CHAIN-UI-SIDEBAR-1: Unit Tests for Sidebar Chain Indicators and Filter Icon
//
// RUN: node --test tests/ui_sidebar_chain_indicators_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

// 1. Persistence Tests for Sidebar Chain Filter
test('clientPersistence defines sidebar chain filter key and functions', async () => {
  // Test functional persistence behavior with a mock localStorage
  const mockStorage: Record<string, string> = {};
  (globalThis as any).window = {
    localStorage: {
      getItem: (key: string) => mockStorage[key] ?? null,
      setItem: (key: string, val: string) => { mockStorage[key] = String(val); },
      removeItem: (key: string) => { delete mockStorage[key]; },
    },
  };

  const { readSidebarChainFilter, writeSidebarChainFilter, SIDEBAR_CHAIN_FILTER_KEY } = await import(
    '../src/ui/utils/clientPersistence.ts'
  );

  assert.equal(SIDEBAR_CHAIN_FILTER_KEY, 'heimdall:sidebar-chain-filter');

  // Default to 'all' when empty
  delete mockStorage['heimdall:sidebar-chain-filter'];
  assert.equal(readSidebarChainFilter(), 'all', 'readSidebarChainFilter should default to all');

  // Write 'active' and read back
  writeSidebarChainFilter('active');
  assert.equal(mockStorage['heimdall:sidebar-chain-filter'], 'active');
  assert.equal(readSidebarChainFilter(), 'active', 'readSidebarChainFilter should return active');

  // Write 'all' and read back
  writeSidebarChainFilter('all');
  assert.equal(mockStorage['heimdall:sidebar-chain-filter'], 'all');
  assert.equal(readSidebarChainFilter(), 'all', 'readSidebarChainFilter should return all');

  // Support legacy or alternate 'active-only' value
  mockStorage['heimdall:sidebar-chain-filter'] = 'active-only';
  assert.equal(readSidebarChainFilter(), 'active', 'readSidebarChainFilter should normalize active-only to active');

  // Fallback to 'all' on unknown value
  mockStorage['heimdall:sidebar-chain-filter'] = 'unexpected_filter_value';
  assert.equal(readSidebarChainFilter(), 'all', 'readSidebarChainFilter should fallback to all on unknown value');
});

// 2. Pure Filtering Logic Tests (filterSidebarChains)
test('filterSidebarChains correctly filters active, completed, and archived chains', async () => {
  const { filterSidebarChains } = await import('../src/ui/utils/clientPersistence.ts');
  assert.equal(typeof filterSidebarChains, 'function', 'filterSidebarChains must be exported function');

  const mockChains: any[] = [
    { chainId: 'c1', title: 'Active Chain 1', status: 'active', projectId: 'p1' },
    { chainId: 'c2', title: 'Completed Chain 2', status: 'completed', projectId: 'p1' },
    { chainId: 'c3', title: 'Paused Chain 3', status: 'paused', projectId: 'p2' },
    { chainId: 'c4', title: 'Cancelled Chain 4', status: 'cancelled', projectId: 'p2' },
    { chainId: 'c5', title: 'Archived Chain 5', status: 'archived', projectId: 'p1' },
    { chainId: 'c6', title: 'Archived Flag Chain 6', status: 'active', archived: true, projectId: 'p1' },
    { chainId: 'c7', title: 'Archived Project Chain 7', status: 'active', projectId: 'p_archived' },
  ];

  const archivedProjects = new Set(['p_archived']);

  // Under 'all' filter: archived chains and archived projects should be excluded, all others kept
  const allFiltered = filterSidebarChains(mockChains, 'all', archivedProjects);
  const allIds = allFiltered.map((c: any) => c.chainId);
  assert.deepEqual(allIds, ['c1', 'c2', 'c3', 'c4'], 'all filter should exclude archived chains and projects, keeping active/completed/paused/cancelled');

  // Under 'active' filter: only non-archived active chains are kept
  const activeFiltered = filterSidebarChains(mockChains, 'active', archivedProjects);
  const activeIds = activeFiltered.map((c: any) => c.chainId);
  assert.deepEqual(activeIds, ['c1'], 'active filter should only include active chains');
});

// 3. REQ-CHAIN-SIDEBAR-PERSIST-5: Chain-level Workbench Workspace Key & State Persistence
test('REQ-CHAIN-SIDEBAR-PERSIST-5: clientPersistence resolves and persists workbench state by chainId and instanceId', async () => {
  const mockStorage: Record<string, string> = {};
  (globalThis as any).window = {
    localStorage: {
      getItem: (key: string) => mockStorage[key] ?? null,
      setItem: (key: string, val: string) => { mockStorage[key] = String(val); },
      removeItem: (key: string) => { delete mockStorage[key]; },
    },
  };

  const {
    resolveWorkbenchWorkspaceKey,
    readWorkbenchWorkspaceState,
    writeWorkbenchWorkspaceState,
  } = await import('../src/ui/utils/clientPersistence.ts');

  assert.equal(resolveWorkbenchWorkspaceKey({ chainId: 'chain_test_1', agentInstanceId: 'inst_1' }), 'chain:chain_test_1');
  assert.equal(resolveWorkbenchWorkspaceKey({ agentInstanceId: 'inst_solo' }), 'agent:inst_solo');

  const tree = {
    rootPaneId: 'pane-1',
    focusedPaneId: 'pane-1',
    maximizedPaneId: null,
    panes: {
      'pane-1': { kind: 'content', value: { tabs: [], activeTabId: 'newTab__empty' } },
    },
  };
  writeWorkbenchWorkspaceState('chain:chain_test_1', tree);
  assert.deepEqual(readWorkbenchWorkspaceState('chain:chain_test_1'), tree);
});


