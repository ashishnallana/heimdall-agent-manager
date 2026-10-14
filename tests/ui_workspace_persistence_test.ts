// Workspace persistence: the Main layout and aux strips persist GLOBALLY,
// never keyed by task chain; legacy chain-keyed workbench keys are cleared.
import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

test('workspace persistence is global (never keyed by task chain) and clears legacy chain-keyed workbench keys', async () => {
  const mockStorage: Record<string, string> = {
    'heimdall:window-layout:v1': '{}',
    'heimdall:workbench-layout:v1:chain:c1': '{}',
    'heimdall:workbench-layout:v1:agent:a1': '{}',
    'heimdall:other': 'keep',
  };
  const localStorage = {
    getItem: (key: string) => mockStorage[key] ?? null,
    setItem: (key: string, val: string) => { mockStorage[key] = String(val); },
    removeItem: (key: string) => { delete mockStorage[key]; },
    key: (i: number) => Object.keys(mockStorage)[i] ?? null,
    get length() { return Object.keys(mockStorage).length; },
  };
  (globalThis as any).window = { localStorage };

  const {
    WORKSPACE_LAYOUT_STORAGE_KEY,
    readWorkspaceLayoutState,
    writeWorkspaceLayoutState,
    readAuxPanesState,
    writeAuxPanesState,
    removeLegacyWorkbenchStorage,
  } = await import('../src/ui/utils/clientPersistence.ts');

  assert.equal(WORKSPACE_LAYOUT_STORAGE_KEY, 'heimdall:workspace-layout:v1');
  const tree = { rootPaneId: 'pane-1', focusedPaneId: 'pane-1', panes: { 'pane-1': { kind: 'content', value: { agentInstanceId: 'a1' } } } };
  writeWorkspaceLayoutState(tree);
  assert.deepEqual(readWorkspaceLayoutState(), tree);
  writeAuxPanesState({ agentPanes: { a1: { tabs: [], activeTabId: 'overview' } } });
  assert.deepEqual(readAuxPanesState(), { agentPanes: { a1: { tabs: [], activeTabId: 'overview' } } });
  assert.ok(!Object.keys(mockStorage).some((k) => k.includes('chain:') && k.startsWith('heimdall:workspace')));

  removeLegacyWorkbenchStorage();
  assert.equal(mockStorage['heimdall:window-layout:v1'], undefined);
  assert.equal(mockStorage['heimdall:workbench-layout:v1:chain:c1'], undefined);
  assert.equal(mockStorage['heimdall:workbench-layout:v1:agent:a1'], undefined);
  assert.equal(mockStorage['heimdall:other'], 'keep');
});


