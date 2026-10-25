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
  migrateLegacySplitStorage,
  readGroupIndex,
  resolveOpenAgentIds,
  writeGroupIndex,
} from '../src/ui/store/splitGroups.ts';
import { buildDefaultSplitTree } from '../src/ui/store/workspaceLayoutSlice.ts';
import {
  chainConversationRoute,
  chainIdFromTargetId,
  chainTargetId,
  parsePaneTargetId,
  paneTargetId,
  resolvePaneTargetAgent,
} from '../src/ui/utils/paneTarget.ts';

function withStorage(fn: (store: Record<string, string>) => void) {
  const store: Record<string, string> = {};
  const prev = (globalThis as any).window;
  (globalThis as any).window = {
    localStorage: {
      getItem: (k: string) => store[k] ?? null,
      setItem: (k: string, v: string) => { store[k] = String(v); },
      removeItem: (k: string) => { delete store[k]; },
      key: (i: number) => Object.keys(store)[i] ?? null,
      get length() { return Object.keys(store).length; },
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
    assert.ok(store['heimdall:split-layout:v2:a+b']);
    assert.ok(loadSavedLayout(['b', 'a']), 'restorable for the same set in any order');
    assert.equal(loadSavedLayout(['a', 'c']), null);

    // Same set again: geometry refreshed, index untouched.
    writeGroupIndex([['a', 'b'], ['x', 'y']]);
    key = persistSplitLayout(ab, key);
    assert.deepEqual(readGroupIndex(), [['a', 'b'], ['x', 'y']]);

    // New intersecting set evicts {a,b} and its geometry.
    key = persistSplitLayout(buildDefaultSplitTree(['b', 'c']), key);
    assert.deepEqual(readGroupIndex(), [['x', 'y'], ['b', 'c']]);
    assert.equal(store['heimdall:split-layout:v2:a+b'], undefined);
    assert.ok(store['heimdall:split-layout:v2:b+c']);
  });
});

// ---- REQ-TV2-7: chain-addressed pane targets ------------------------------

test('pane targets: chain:<id> and instance ids round-trip; empty ids are not chain targets', () => {
  assert.equal(chainTargetId('chain_a'), 'chain:chain_a');
  assert.equal(chainTargetId('  '), '');
  assert.equal(chainIdFromTargetId('chain:chain_a'), 'chain_a');
  assert.equal(chainIdFromTargetId('chain:'), '', 'a bare prefix is not a chain target');
  assert.equal(chainIdFromTargetId('inst_1'), '');
  assert.deepEqual(parsePaneTargetId('chain:chain_a'), { kind: 'chain_coordinator', chainId: 'chain_a' });
  assert.deepEqual(parsePaneTargetId('inst_1'), { kind: 'agent', agentInstanceId: 'inst_1' });
  assert.equal(paneTargetId({ kind: 'chain_coordinator', chainId: 'chain_a' }), 'chain:chain_a');
  assert.equal(paneTargetId({ kind: 'agent', agentInstanceId: 'inst_1' }), 'inst_1');
  // A chain target shows its CURRENT coordinator; an agent target shows itself.
  assert.equal(resolvePaneTargetAgent('chain:chain_a', { chain_a: 'inst_new' }), 'inst_new');
  assert.equal(resolvePaneTargetAgent('chain:chain_a', {}), '');
  assert.equal(resolvePaneTargetAgent('inst_1', { chain_a: 'inst_new' }), 'inst_1');
  assert.equal(chainConversationRoute('chain a/b'), '/conversations/chain:chain%20a%2Fb');
});

test('URL grammar: #/conversations/chain:<id>+<inst>?focused=chain:<id> parses and builds verbatim', () => {
  const hash = buildConversationHash(['chain:chain_a', 'inst_2'], { focusedId: 'chain:chain_a' });
  assert.equal(hash, '#/conversations/chain:chain_a+inst_2?focused=chain:chain_a');
  const [path, search] = hash.slice(1).split('?');
  assert.deepEqual(parseConversationIdsFromRoute(path, `?${search}`), {
    ids: ['chain:chain_a', 'inst_2'],
    focused: 'chain:chain_a',
  });
  // Percent-encoded separators (an older copy of the link) parse identically.
  assert.deepEqual(
    parseConversationIdsFromRoute('/conversations/chain%3Achain_a+inst_2', '?focused=chain%3Achain_a'),
    { ids: ['chain:chain_a', 'inst_2'], focused: 'chain:chain_a' },
  );
  // Two chains are two panes even when the same durable agent coordinates both.
  assert.equal(
    buildConversationHash(['chain:chain_a', 'chain:chain_b'], { focusedId: 'chain:chain_b' }),
    '#/conversations/chain:chain_a+chain:chain_b?focused=chain:chain_b',
  );
  assert.equal(buildConversationHash(['chain:chain_a']), '#/conversations/chain:chain_a');
  // Legacy instance links keep their shape.
  assert.equal(buildConversationHash(['inst_coord']), '#/conversations/inst_coord');
});

test('split groups: keyed by target list; a chain target opens its saved group', () => {
  withStorage((store) => {
    const tree = buildDefaultSplitTree(['chain:chain_a', 'chain:chain_b']);
    tree.panes['split-1'] = { ...(tree.panes['split-1'] as any), ratio: 30 };
    persistSplitLayout(tree, null);
    assert.ok(store['heimdall:split-layout:v2:chain:chain_a+chain:chain_b']);
    assert.deepEqual(readGroupIndex(), [['chain:chain_a', 'chain:chain_b']]);
    assert.deepEqual(resolveOpenAgentIds('chain:chain_b'), {
      ids: ['chain:chain_a', 'chain:chain_b'],
      focusedId: 'chain:chain_b',
    });
    const restored = loadSavedLayout(['chain:chain_b', 'chain:chain_a']);
    assert.equal((restored?.panes['split-1'] as any)?.ratio, 30, 'workspace restore keeps the geometry');
  });
});

test('split groups: v1 instance-keyed entries migrate once to v2 and the v1 keys are removed', () => {
  withStorage((store) => {
    const legacyTree = buildDefaultSplitTree(['inst_a', 'inst_b']);
    store['heimdall:split-groups:v1'] = JSON.stringify([['inst_a', 'inst_b']]);
    store['heimdall:split-layout:v1:inst_a+inst_b'] = JSON.stringify(legacyTree);
    store['heimdall:split-layout:v1:orphan+x'] = '{}';
    assert.deepEqual(readGroupIndex(), [['inst_a', 'inst_b']]);
    assert.ok(loadSavedLayout(['inst_b', 'inst_a']), 'migrated geometry restores');
    assert.equal(store['heimdall:split-groups:v1'], undefined);
    assert.equal(store['heimdall:split-layout:v1:inst_a+inst_b'], undefined);
    assert.equal(store['heimdall:split-layout:v1:orphan+x'], undefined);
    // Idempotent; a later v1 write never clobbers v2.
    store['heimdall:split-groups:v1'] = JSON.stringify([['old', 'stale']]);
    migrateLegacySplitStorage();
    assert.deepEqual(readGroupIndex(), [['inst_a', 'inst_b']]);
    assert.equal(store['heimdall:split-groups:v1'], undefined);
  });
});
