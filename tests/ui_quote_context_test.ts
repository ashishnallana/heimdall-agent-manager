import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { configureStore } from '@reduxjs/toolkit';
import context, { addComposerQuote, removeComposerQuote, consumeComposerQuotes, clearComposerContexts, selectComposerQuotes } from '../src/ui/store/composerContextSlice.ts';
import { quotedMessageBody, quoteLabel, quoteLimitError, type QuoteContext } from '../src/ui/utils/quoteContext.ts';
import { unlockVault, clearActiveKey, installWindowShim } from './helpers/vaultEndpointHarness.ts';
import { heimdallApi } from '../src/ui/api/heimdallApi.ts';
import { chatEndpoints } from '../src/ui/api/endpoints/chats.ts';
import vault, { keyringCleared } from '../src/ui/store/vaultSlice.ts';
import { vaultCacheInvalidationMiddleware } from '../src/ui/api/vaultCacheInvalidation.ts';
import { decryptVaultText, isVaultArmored } from '../src/ui/utils/vaultContent.ts';

const quote = (id = 'q1', selectedText = 'first two three four five six seven\n  code'): QuoteContext => ({
  version: 1, id, selectedText, capturedAt: 1, source: {
    kind: 'agent_message', chainId: 'chain1', conversationId: 'workerchat', messageId: 'm1',
    agentInstanceId: 'worker', author: 'Worker', createdUnixMs: 2, href: '#/conversations/worker?msg=m1',
  },
});
test('safe versioned serializer preserves arbitrary exact selections and sources, excludes local ids', () => {
  const selected = '  \ncode with ```````\n</script> and "quotes"\n  ';
  const body = quotedMessageBody('  Please fix  ', [quote('local-id', selected)]);
  assert.match(body, /^Please fix\n\nQuoted context/);
  const fence = body.split('\n')[3];
  assert.equal(fence, '`'.repeat(8) + 'json');
  const parsed = JSON.parse(body.slice(body.indexOf('json\n') + 5, body.lastIndexOf('\n')));
  assert.equal(parsed.version, 1);
  assert.equal(parsed.quoted_context[0].selectedText, selected);
  assert.deepEqual(parsed.quoted_context[0].source, quote().source);
  assert.equal(parsed.quoted_context[0].id, undefined);
  assert.equal(quotedMessageBody('', [quote()]).startsWith('Quoted context'), true);
  assert.equal(quotedMessageBody(' hi ', []), 'hi');
});
test('label truncation does not alter selection; limits reject visibly rather than clipping', () => {
  assert.equal(quoteLabel(quote().selectedText), 'first two three four five six…');
  assert.equal(quoteLabel('one\n two'), 'one two');
  assert.match(quoteLimitError([], quote('a', 'x'.repeat(8001))), /8,000/);
  assert.match(quoteLimitError([], quote('a', '  ')), /Select/);
  const eight = Array.from({ length: 8 }, (_, i) => quote(String(i), 'quote ' + i));
  assert.match(quoteLimitError(eight, quote('new')), /maximum 8/);
  assert.equal(quoteLimitError(eight, { ...eight[0], id: 'duplicate' }), '');
});
test('chain-scoped quote state deduplicates, preserves newer additions on consume, and cannot resurrect after purge', () => {
  let state = context(undefined, addComposerQuote({ target: 'chain:c', quote: quote() }));
  state = context(state, addComposerQuote({ target: 'chain:c', quote: quote('dup') }));
  assert.equal(state.byTarget['chain:c'].length, 1);
  const renamed = quote('renamed');
  if (renamed.source.kind === 'agent_message') renamed.source.author = 'Renamed worker';
  state = context(state, addComposerQuote({ target: 'chain:c', quote: renamed }));
  assert.equal(state.byTarget['chain:c'].length, 1, 'source identity does not change with author label');
  state = context(state, addComposerQuote({ target: 'chain:other', quote: quote('other') }));
  state = context(state, addComposerQuote({ target: 'chain:c', quote: quote('q2', 'new text') }));
  state = context(state, consumeComposerQuotes({ target: 'chain:c', ids: ['q1'], epoch: 0 }));
  assert.deepEqual(state.byTarget['chain:c'].map(q => q.id), ['q2']);
  assert.equal(state.byTarget['chain:other'].length, 1);
  state = context(state, removeComposerQuote({ target: 'chain:c', id: 'q2' }));
  assert.equal(state.byTarget['chain:c'].length, 0);
  state = context(state, clearComposerContexts());
  state = context(state, consumeComposerQuotes({ target: 'chain:other', ids: ['other'], epoch: 0 }));
  assert.deepEqual(state.byTarget, {});
  assert.equal(state.epoch, 1);
  assert.equal(selectComposerQuotes({ composerContext: state }, 'worker').length, 0);
});

async function endpointFixture(run: (ctx: any) => Promise<void>) {
  installWindowShim();
  const previousFetch = globalThis.fetch;
  const store = configureStore({
    reducer: { vault, composerContext: context, chat: (s: any = { session: {} }) => s, [heimdallApi.reducerPath]: heimdallApi.reducer },
    middleware: g => g({ serializableCheck: false }).concat(vaultCacheInvalidationMiddleware, heimdallApi.middleware),
  });
  const key = await unlockVault(store, '71'.repeat(32));
  const requests: any[] = [];
  let coordinator = 'coord';
  let beforeReturn: (() => void) | undefined;
  let fail = false;
  globalThis.fetch = (async (input: any, init: any = {}) => {
    const url = String(input); const method = init.method || 'GET';
    requests.push({ url, method, body: init.body ? JSON.parse(init.body) : null });
    const data = method === 'POST' ? { message_id: 'sent' } : { coordinator_agent_instance_id: coordinator, conversation_id: 'coordchat' };
    beforeReturn?.();
    return { ok: !fail, status: fail ? 503 : 200, headers: { get: () => 'application/json' }, text: async () => JSON.stringify({ data }) } as any;
  }) as any;
  const send = () => store.dispatch(chatEndpoints.endpoints.sendConversationMessage.initiate({
    conversationId: 'coordchat', body: quotedMessageBody('Please explain', [quote()]), artifactIds: ['art1'],
    quoteTarget: { chainId: 'chain1', coordinatorAgentInstanceId: 'coord', epoch: store.getState().composerContext.epoch },
  }));
  try {
    await run({ store, key, requests, send, setCoordinator: (v: string) => coordinator = v, setBeforeReturn: (fn: () => void) => beforeReturn = fn, fail: () => fail = true });
  } finally { store.dispatch(heimdallApi.util.resetApiState()); globalThis.fetch = previousFetch; await clearActiveKey(); }
}
test('real send endpoint encrypts body and source together; no plaintext quote metadata or worker send', async () => {
  await endpointFixture(async ({ send, requests, key }) => {
    const result = await send(); assert.equal(result.error, undefined);
    assert.equal(requests.length, 2);
    assert.match(requests[0].url, /task-chains\/chain1\/conversation/);
    const post = requests.find((r: any) => r.method === 'POST');
    assert.match(post.url, /chats\/coordchat\/messages/);
    assert.deepEqual(Object.keys(post.body).sort(), ['artifact_ids', 'body']);
    assert.equal(isVaultArmored(post.body.body), true);
    assert.equal(await decryptVaultText(post.body.body, key), quotedMessageBody('Please explain', [quote()]));
    assert.deepEqual(post.body.artifact_ids, ['art1']);
    assert.equal(JSON.stringify(requests).includes(quote().selectedText), false);
  });
});
test('changed coordinator rejects before POST and leaves pending chips intact', async () => {
  await endpointFixture(async ({ send, requests, store, setCoordinator }) => {
    store.dispatch(addComposerQuote({ target: 'chain:chain1', quote: quote() }));
    setCoordinator('replacement');
    const result = await send(); assert.match(result.error.error, /coordinator changed/);
    assert.equal(requests.filter((r: any) => r.method === 'POST').length, 0);
    assert.equal(store.getState().composerContext.byTarget['chain:chain1'].length, 1);
  });
});
test('lock during coordinator validation purges chips and prevents plaintext or stale encrypted POST', async () => {
  await endpointFixture(async ({ send, requests, store, setBeforeReturn }) => {
    store.dispatch(addComposerQuote({ target: 'chain:chain1', quote: quote() }));
    setBeforeReturn(() => store.dispatch(keyringCleared()));
    const result = await send(); assert.equal(result.data, undefined);
    assert.equal(requests.filter((r: any) => r.method === 'POST').length, 0);
    assert.deepEqual(store.getState().composerContext.byTarget, {});
  });
});
test('locked quote send fails before any network call', async () => {
  await endpointFixture(async ({ send, requests, store }) => {
    store.dispatch(keyringCleared());
    const result = await send(); assert.match(result.error.error, /Unlock Vault/);
    assert.equal(requests.length, 0);
  });
});
