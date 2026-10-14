import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  buildConversationHash,
  conversationIdsSegment,
  parseConversationIdsFromRoute,
} from '../src/ui/utils/conversationUrl.ts';
import {
  computeUpdatedGroups,
  evictAgentFromGroups,
  filterValidGroups,
  findGroupForAgent,
  getGroupsToEvict,
  loadSavedLayout,
  persistSplitLayout,
  readGroupIndex,
  resolveOpenAgentIds,
  writeGroupIndex,
} from '../src/ui/store/splitGroups.ts';
import { buildDefaultSplitTree } from '../src/ui/store/workspaceLayoutSlice.ts';

function withStorage(fn: (store: Record<string, string>) => void) {
  const store: Record<string, string> = {};
  const prev = (globalThis as any).window;
  (globalThis as any).window = {
    localStorage: {
      getItem: (k: string) => store[k] ?? null,
      setItem: (k: string, v: string) => { store[k] = String(v); },
      removeItem: (k: string) => { delete store[k]; },
    },
  };
  try {
    fn(store);
  } finally {
    (globalThis as any).window = prev;
  }
}

test('URL parse: pane set, de-dupe (keeping _new), focused fallback, legacy single id', () => {
  assert.deepEqual(parseConversationIdsFromRoute('/conversations/a', ''), { ids: ['a'], focused: 'a' });
  assert.deepEqual(parseConversationIdsFromRoute('/c/a', ''), { ids: ['a'], focused: 'a' });
  assert.deepEqual(parseConversationIdsFromRoute('/conversations/a+b+a', '?focused=b'), { ids: ['a', 'b'], focused: 'b' });
  assert.deepEqual(parseConversationIdsFromRoute('/conversations/a+_new+_new', ''), { ids: ['a', '_new', '_new'], focused: 'a' });
  assert.deepEqual(parseConversationIdsFromRoute('/conversations/a+b', '?focused=zzz'), { ids: ['a', 'b'], focused: 'a' });
  assert.deepEqual(parseConversationIdsFromRoute('/conversations/a++', ''), { ids: ['a'], focused: 'a' });
  assert.deepEqual(parseConversationIdsFromRoute('/conversations/a%2Fx+b', '?msg=m1'), { ids: ['a/x', 'b'], focused: 'a/x' });
  assert.deepEqual(parseConversationIdsFromRoute('/conversations/%E0', ''), { ids: ['%E0'], focused: '%E0' });
  assert.deepEqual(parseConversationIdsFromRoute('/home', '?focused=a'), { ids: [], focused: undefined });
  assert.equal(conversationIdsSegment('/conversations/new'), null, 'the launch page is not a pane set');
});

test('URL construct: single view keeps the legacy shape; splits carry focused', () => {
  assert.equal(buildConversationHash(['a']), '#/conversations/a');
  assert.equal(buildConversationHash(['a', 'b'], { focusedId: 'b' }), '#/conversations/a+b?focused=b');
  assert.equal(buildConversationHash(['a', 'b'], { focusedId: 'nope' }), '#/conversations/a+b?focused=a');
  assert.equal(buildConversationHash(['a/x', '_new']), '#/conversations/a%2Fx+_new?focused=a%2Fx');
  assert.equal(buildConversationHash(['a'], { extraSearch: { msg: 'm1' } }), '#/conversations/a?msg=m1');
  const round = parseConversationIdsFromRoute('/conversations/a%2Fx+_new', '?focused=_new');
  assert.deepEqual(round, { ids: ['a/x', '_new'], focused: '_new' });
});

test('split group index: membership, eviction of intersecting sets, <=1-member groups dropped', () => {
  let groups: string[][] = [];
  groups = computeUpdatedGroups(groups, ['a', 'b']);
  assert.deepEqual(groups, [['a', 'b']]);
  groups = computeUpdatedGroups(groups, ['c', 'd', '_new']);
  assert.deepEqual(groups, [['a', 'b'], ['c', 'd']], '_new never persists');
  // Forming {b, c} evicts both intersecting groups: an agent is in at most one group.
  assert.deepEqual(getGroupsToEvict(groups, ['b', 'c']), [['a', 'b'], ['c', 'd']]);
  groups = computeUpdatedGroups(groups, ['b', 'c']);
  assert.deepEqual(groups, [['b', 'c']]);
  // Same set (any order) is kept, not duplicated.
  assert.deepEqual(computeUpdatedGroups(groups, ['c', 'b']), [['b', 'c']]);
  // A single view only evicts groups containing it.
  assert.deepEqual(computeUpdatedGroups(groups, ['x']), [['b', 'c']]);
  assert.deepEqual(computeUpdatedGroups(groups, ['b']), []);
  assert.deepEqual(computeUpdatedGroups(groups, ['_new']), [['b', 'c']]);
  // Evicting an agent drops groups left with <= 1 real agent.
  assert.deepEqual(evictAgentFromGroups([['a', 'b'], ['c', 'd', 'e']], 'a').nextGroups, [['c', 'd', 'e']]);
  assert.deepEqual(evictAgentFromGroups([['c', 'd', 'e']], 'e').nextGroups, [['c', 'd']]);
  assert.deepEqual(filterValidGroups([['a'], ['a', '_new'], ['a', 'b'], 'x', [1, 2]]), [['a', 'b']]);
  assert.deepEqual(findGroupForAgent([['a', 'b']], 'b'), ['a', 'b']);
  assert.equal(findGroupForAgent([['a', 'b']], 'z'), undefined);
});

test('open-agent routing: an agent in a saved group opens the group focused on it, else its single view', () => {
  assert.deepEqual(resolveOpenAgentIds('b', [['a', 'b', 'c']]), { ids: ['a', 'b', 'c'], focusedId: 'b' });
  assert.deepEqual(resolveOpenAgentIds('z', [['a', 'b', 'c']]), { ids: ['z'], focusedId: 'z' });
});

test('layout persistence: geometry per sorted id set, group index updates on set change, eviction drops geometry', () => {
  withStorage((store) => {
    const ab = buildDefaultSplitTree(['a', 'b']);
    let key = persistSplitLayout(ab, null);
    assert.equal(key, 'a+b');
    assert.deepEqual(readGroupIndex(), [['a', 'b']]);
    assert.ok(store['heimdall:split-layout:v1:a+b']);
    assert.ok(loadSavedLayout(['b', 'a']), 'restorable for the same set in any order');
    assert.equal(loadSavedLayout(['a', 'c']), null);

    // Same set again: geometry refreshed, index untouched.
    writeGroupIndex([['a', 'b'], ['x', 'y']]);
    key = persistSplitLayout(ab, key);
    assert.deepEqual(readGroupIndex(), [['a', 'b'], ['x', 'y']]);

    // New intersecting set evicts {a,b} and its geometry.
    key = persistSplitLayout(buildDefaultSplitTree(['b', 'c']), key);
    assert.deepEqual(readGroupIndex(), [['x', 'y'], ['b', 'c']]);
    assert.equal(store['heimdall:split-layout:v1:a+b'], undefined);
    assert.ok(store['heimdall:split-layout:v1:b+c']);
  });
});
