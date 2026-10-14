// Workspace persistence: the Main layout and aux strips persist GLOBALLY,
// never keyed by task chain; legacy chain-keyed workbench keys are cleared.
import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

test('aux strips persist per agent (never keyed by task chain); legacy chain-keyed and global layout keys are cleared', async () => {
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
    readAuxPanesState,
    writeAuxPanesState,
    removeLegacyWorkbenchStorage,
  } = await import('../src/ui/utils/clientPersistence.ts');

  mockStorage['heimdall:workspace-layout:v1'] = '{}';
  writeAuxPanesState({ agentPanes: { a1: { tabs: [], activeTabId: 'overview' } } });
  assert.deepEqual(readAuxPanesState(), { agentPanes: { a1: { tabs: [], activeTabId: 'overview' } } });
  assert.ok(!Object.keys(mockStorage).some((k) => k.includes('chain:') && k.startsWith('heimdall:workspace')));

  removeLegacyWorkbenchStorage();
  assert.equal(mockStorage['heimdall:window-layout:v1'], undefined);
  assert.equal(mockStorage['heimdall:workbench-layout:v1:chain:c1'], undefined);
  assert.equal(mockStorage['heimdall:workbench-layout:v1:agent:a1'], undefined);
  assert.equal(mockStorage['heimdall:workspace-layout:v1'], undefined, 'the single global layout key is gone');
  assert.equal(mockStorage['heimdall:other'], 'keep');
});


