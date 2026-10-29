import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { JSDOM } from 'jsdom';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import context, { addComposerQuote } from '../src/ui/store/composerContextSlice.ts';
import { heimdallApi } from '../src/ui/api/heimdallApi.ts';
import { vaultCacheInvalidationMiddleware } from '../src/ui/api/vaultCacheInvalidation.ts';
import { unlockVault, clearActiveKey } from './helpers/vaultEndpointHarness.ts';
import { encryptVaultText } from '../src/ui/utils/vaultContent.ts';
import { keyringCleared } from '../src/ui/store/vaultSlice.ts';
import { readMarkdownSelection } from '../src/ui/components/MarkdownBody.tsx';
import { ThreadMessageBody, AgentChatPane } from '../src/ui/components/workbench/AgentChatPane.tsx';
import ComposerContextChips from '../src/ui/components/chat/ComposerContextChips.tsx';
import { ShortcutProvider } from '../src/ui/services/shortcuts/ShortcutContext.tsx';
import type { QuoteContext } from '../src/ui/utils/quoteContext.ts';
const sample: QuoteContext = { version: 1, id: 'q1', selectedText: 'one two three four five six seven', capturedAt: 1,
  source: { kind: 'agent_message', messageId: 'm1', conversationId: 'workerchat', chainId: 'c', agentInstanceId: 'worker', author: 'Worker', createdUnixMs: 1, href: '#/conversations/worker?msg=m1' } };
async function fixture(run: (ctx: any) => Promise<void>) {
  const dom = new JSDOM('<div id="root"></div>', { url: 'http://localhost/#/conversations/worker', pretendToBeVisual: true });
  const saved = new Map<string, PropertyDescriptor | undefined>();
  const install = (name: string, value: any) => { saved.set(name, Object.getOwnPropertyDescriptor(globalThis, name)); Object.defineProperty(globalThis, name, { value, configurable: true, writable: true }); };
  class RO { observe() {} unobserve() {} disconnect() {} }
  const frames = new Set<ReturnType<typeof setTimeout>>();
  dom.window.requestAnimationFrame = (cb: FrameRequestCallback) => {
    const timer = setTimeout(() => { frames.delete(timer); cb(Date.now()); }, 1);
    frames.add(timer); return timer as any;
  };
  dom.window.cancelAnimationFrame = (id: any) => { clearTimeout(id); frames.delete(id); };
  dom.window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {} }) as any;
  dom.window.HTMLElement.prototype.scrollIntoView = () => {};
  dom.window.HTMLElement.prototype.scrollTo = () => {};
  (dom.window.HTMLElement.prototype as any).attachEvent = () => {};
  (dom.window.HTMLElement.prototype as any).detachEvent = () => {};
  for (const [k, v] of Object.entries({ window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, Element: dom.window.Element,
    navigator: dom.window.navigator, localStorage: dom.window.localStorage, sessionStorage: dom.window.sessionStorage, ResizeObserver: RO,
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window), cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window), IS_REACT_ACT_ENVIRONMENT: true })) install(k, v);
  const reducers: any = { composerContext: context };
  const modules: Record<string, string> = { chat: 'chatSlice', vault: 'vaultSlice', tasks: 'taskSlice', memory: 'memorySlice', projects: 'projectSlice',
    home: 'homeSlice', chainView: 'chainViewSlice', attention: 'attentionSlice', cards: 'cardsSlice', toasts: 'toastSlice', notifications: 'notificationsSlice',
    workspaceLayout: 'workspaceLayoutSlice', auxPanes: 'auxPanesSlice', workspaceChrome: 'workspaceChromeSlice', inputPreferences: 'inputPreferencesSlice',
    searchTitle: 'searchTitleSlice', agentActivity: 'agentActivitySlice', toolActivity: 'toolActivitySlice', deviceVault: 'deviceVaultSlice', shells: 'shellSlice', theme: 'themeSlice' };
  for (const [key, file] of Object.entries(modules)) reducers[key] = (await import('../src/ui/store/' + file + '.ts')).default;
  const store = configureStore({ reducer: { ...reducers, [heimdallApi.reducerPath]: heimdallApi.reducer },
    enhancers: (g: any) => g({ autoBatch: false }),
    middleware: (g: any) => g({ serializableCheck: false, immutableCheck: false }).concat(vaultCacheInvalidationMiddleware, heimdallApi.middleware) });
  const key = await unlockVault(store, '63'.repeat(32));
  const root = createRoot(dom.window.document.getElementById('root')!);
  const q = (id: string) => dom.window.document.querySelector('[data-debug-id="' + id + '"]') as HTMLElement;
  const render = async (content: React.ReactNode) => act(async () => root.render(React.createElement(Provider, { store, children: React.createElement(ShortcutProvider, { children: content }) })));
  const wait = async (fn: () => boolean) => { for (let i = 0; i < 100; i++) { if (fn()) return; await act(async () => { await new Promise(r => setTimeout(r, 10)); }); } assert.ok(fn(), dom.window.document.body.textContent?.slice(-1600)); };
  const select = async (node: Node, event = 'mouseup') => { const range = dom.window.document.createRange(); range.selectNodeContents(node);
    const selection = dom.window.getSelection()!; selection.removeAllRanges(); selection.addRange(range);
    await act(async () => { node.parentElement?.dispatchEvent(new dom.window.Event(event, { bubbles: true })); dom.window.document.dispatchEvent(new dom.window.Event('selectionchange')); });
  };
  const previousFetch = globalThis.fetch;
  try { await run({ dom, store, key, q, render, wait, select }); }
  finally { await act(async () => { root.unmount(); store.dispatch(heimdallApi.util.resetApiState()); await new Promise(r => setTimeout(r, 60)); }); globalThis.fetch = previousFetch; await clearActiveKey();
    for (const frame of frames) clearTimeout(frame);
    dom.window.close(); for (const [name, descriptor] of saved) { if (descriptor) Object.defineProperty(globalThis, name, descriptor); else delete (globalThis as any)[name]; } }
}

test('partial selection preserves line breaks, rejects cross-root/control ranges and collapsed selection', async () => {
  await fixture(async ({ dom, render }) => {
    await render(React.createElement('div', {}, React.createElement('div', { id: 'one' }, 'first\n  second', React.createElement('button', {}, 'Copy')), React.createElement('div', { id: 'two' }, 'other')));
    const one = dom.window.document.getElementById('one')!;
    const text = one.firstChild!; const selection = dom.window.getSelection()!;
    const range = dom.window.document.createRange(); range.setStart(text, 2); range.setEnd(text, 12); selection.addRange(range);
    assert.equal(readMarkdownSelection(one)?.selectedText, 'rst\n  seco');
    const originalGetSelection = dom.window.getSelection.bind(dom.window);
    dom.window.getSelection = () => ({ rangeCount: 2, isCollapsed: false, getRangeAt: () => range, toString: () => 'other message too' }) as any;
    assert.equal(readMarkdownSelection(one), null, 'multi-range selections cannot smuggle another message');
    dom.window.getSelection = originalGetSelection;
    range.setEnd(dom.window.document.getElementById('two')!.firstChild!, 3);
    assert.equal(readMarkdownSelection(one), null);
    range.selectNodeContents(one); assert.equal(readMarkdownSelection(one), null, 'range includes control');
    range.selectNodeContents(one.querySelector('button')!); assert.equal(readMarkdownSelection(one), null);
    selection.removeAllRanges(); assert.equal(readMarkdownSelection(one), null);
  });
});
test('real decrypted message selection shows Quote for mouse/keyboard/touch; chip label and removal are separate from draft', async () => {
  await fixture(async ({ dom, key, render, select, q, wait }) => {
    const selected: string[] = [];
    let chips = [sample];
    const body = await encryptVaultText('A partial message\n\n\`\`\`js\n  const n = 1;\n  n++;\n\`\`\`', key);
    const view = () => React.createElement('div', {}, React.createElement(ThreadMessageBody, { body, onQuote: async text => { selected.push(text); } }),
      React.createElement('textarea', { id: 'draft', defaultValue: 'keep my draft' }),
      React.createElement(ComposerContextChips, { quotes: chips, onRemove: id => { chips = chips.filter(q => q.id !== id); void render(view()); } }));
    await render(view()); await wait(() => Boolean(dom.window.document.querySelector('code')));
    for (const event of ['mouseup', 'keyup', 'touchend']) {
      await select(dom.window.document.querySelector('code')!, event);
      assert.ok(q('message-quote-btn'));
      await act(async () => q('message-quote-btn').click());
      assert.equal(selected.at(-1), '  const n = 1;\n  n++;');
      assert.equal((dom.window.document.getElementById('draft') as HTMLTextAreaElement).value, 'keep my draft');
    }
    assert.match(q('composer-quote-details-q1').textContent || '', /one two three four five six…/);
    await act(async () => q('composer-quote-remove-q1').click());
    assert.equal(q('composer-quote-chip-q1'), null);
    assert.equal(selected.length, 3, 'only explicit Quote clicks capture text');
  });
});
test('selection popover dismisses on escape, collapse, scroll, source changes and Vault purge', async () => {
  await fixture(async ({ dom, key, store, render, select, q, wait }) => {
    let body = await encryptVaultText('select this', key);
    const view = () => React.createElement(ThreadMessageBody, { body, onQuote: async () => { throw new Error('should not capture automatically'); } });
    await render(view()); await wait(() => Boolean(dom.window.document.querySelector('.markdown p')));
    await select(dom.window.document.querySelector('.markdown p')!);
    await act(async () => dom.window.document.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true })));
    assert.equal(q('message-quote-popover'), null);
    await select(dom.window.document.querySelector('.markdown p')!);
    await act(async () => dom.window.dispatchEvent(new dom.window.Event('scroll')));
    assert.equal(q('message-quote-popover'), null);
    await select(dom.window.document.querySelector('.markdown p')!);
    await act(async () => { dom.window.getSelection()!.removeAllRanges(); dom.window.document.dispatchEvent(new dom.window.Event('selectionchange')); });
    assert.equal(q('message-quote-popover'), null);
    await select(dom.window.document.querySelector('.markdown p')!);
    body = await encryptVaultText('different source', key); await render(view());
    assert.equal(q('message-quote-popover'), null);
    await wait(() => dom.window.document.querySelector('.markdown p')?.textContent === 'different source');
    await select(dom.window.document.querySelector('.markdown p')!);
    await act(async () => store.dispatch(keyringCleared()));
    assert.equal(q('message-quote-popover'), null);
    await select(dom.window.document.body);
    assert.equal(q('message-quote-btn'), null);
  });
});
test('unresolved coordinator explains disabled Quote', async () => {
  await fixture(async ({ dom, key, render, select, q, wait }) => {
    const body = await encryptVaultText('message text', key);
    await render(React.createElement(ThreadMessageBody, { body, quoteDisabledReason: 'This message has no chain coordinator.', onQuote: async () => {} }));
    await wait(() => dom.window.document.querySelector('.markdown p')?.textContent === 'message text');
    await select(dom.window.document.querySelector('.markdown p')!);
    assert.equal((q('message-quote-btn') as HTMLButtonElement).disabled, true);
    assert.match(q('message-quote-status').textContent || '', /no chain coordinator/);
  });
});

test('a message that cannot decrypt never offers Quote', async () => {
  await fixture(async ({ dom, render, select, q }) => {
    const { keyringFromHex } = await import('./helpers/vaultTestKeyring.ts');
    const wrongKey = await keyringFromHex('99'.repeat(32));
    const body = await encryptVaultText('unreadable secret', wrongKey);
    await render(React.createElement(ThreadMessageBody, { body, onQuote: async () => { throw new Error('must not capture'); } }));
    await act(async () => { await new Promise(r => setTimeout(r, 30)); });
    await select(dom.window.document.querySelector('.markdown')!);
    assert.equal(q('message-quote-btn'), null);
    assert.equal(dom.window.document.body.textContent?.includes('unreadable secret'), false);
  });
});
test('whole chat pane routes worker Quote into coordinator draft, retains it on failed send and clears only after successful retry', async () => {
  await fixture(async ({ dom, store, key, render, select, q, wait }) => {
    const posts: any[] = [];
    let failPost = true;
    const wireMessages: any[] = [];
    let postRelease: (() => void) | undefined;
    let holdPost = false;
    globalThis.fetch = (async (input: any, init: any = {}) => {
      const url = new URL(String(input), 'http://localhost'); const path = url.pathname; const method = init.method || 'GET';
      let data: any = {};
      let ok = true;
      if (method === 'POST' && /\/messages$/.test(path)) {
        posts.push({ path, body: JSON.parse(init.body) }); ok = !failPost;
        if (holdPost) await new Promise<void>(r => postRelease = r);
        data = ok ? { message_id: 'sent1' } : { error: { message: 'temporary failure' } };
        return { ok, status: ok ? 200 : 503, headers: { get: () => 'application/json' }, text: async () => JSON.stringify(data), json: async () => data } as any;
      }
      if (path.includes('/chats/by-instance/')) {
        const id = path.split('/').at(-1);
        data = { conversation_id: id + 'chat', agent_instance_id: id, agent_id: id + '-identity', chain_id: 'c', runtime_status: 'running' };
      } else if (path.endsWith('/messages')) {
        const isWorker = path.includes('/workerchat/');
        data = isWorker ? [{ message_id: 'm1', direction: 'agent_to_user', sender_agent_instance_id: 'worker', body: 'Quote just this selected message text', created_unix_ms: 100 }] : wireMessages;
        return { ok: true, status: 200, headers: { get: () => 'application/json' }, text: async () => JSON.stringify({ data }), json: async () => ({ data }) } as any;
      } else if (path.endsWith('/conversation')) data = { chain_id: 'c', coordinator_agent_instance_id: 'coord', conversation_id: 'coordchat', replaced_coordinator_instance_ids: [] };
      else if (/\/agent-instances\/[^/]+$/.test(path)) data = { agent_instance_id: path.split('/').at(-1), agent_id: 'identity', provider: 'claude', model: 'opus', bridge_id: 'b', runtime_status: 'running' };
      else if (path.endsWith('/reconfigurations')) data = { operations: [] };
      else if (path.endsWith('/provider-status')) data = { providers: [{ provider: 'claude', enabled: true, state: 'present', catalog_state: 'active', models: [{ model_id: 'opus', state: 'active' }] }] };
      else if (path.endsWith('/bridges')) data = [{ bridge_id: 'b', status: 'online', runtime_connected: true, reconfiguration_supported: true }];
      else if (path.endsWith('/agents/live')) data = [];
      else if (path.endsWith('/task-chains/c')) data = { chain_id: 'c', title: 'Test chain', coordinator_agent_instance_id: 'coord', members: [{ agent_instance_id: 'coord', role: 'coordinator' }] };
      else if (path.endsWith('/tasks')) data = [];
      else if (path.endsWith('/attention')) data = { items: url.searchParams.get('kind') === 'task' ? [{
        card_id: 'crd_review', kind: 'task', provider: 'task_validation', title: 'Review task', status: 'pending', snoozed: false,
        urgency: 'warn', operations: [], action_refs: { chain_id: 'c', task_id: 'task_review' },
        details: { attention: 'review', status: 'in_review', priority: 'p2' }, context: { chain_title: 'Test chain' },
      }] : [] };
      return { ok, status: 200, headers: { get: () => 'application/json' }, text: async () => JSON.stringify({ data }), json: async () => ({ data }) } as any;
    }) as any;
    dom.window.localStorage.setItem('heimdall:composer:draft:coord', 'Keep this coordinator draft');
    function View() {
      const [route, setRoute] = React.useState('worker');
      return React.createElement(AgentChatPane, { agentInstanceId: route, chainTarget: route === 'coord' ? { chainId: 'c' } : undefined,
        paneId: 'test-pane', isMobile: false, onSwitchAgent: target => { assert.equal(target, 'chain:c'); setRoute('coord'); } });
    }
    await render(React.createElement(View));
    await wait(() => dom.window.document.querySelector('.markdown p')?.textContent === 'Quote just this selected message text');
    await select(dom.window.document.querySelector('.markdown p')!);
    await act(async () => q('message-quote-btn').click());
    await wait(() => Boolean(q('composer-quote-chips')));
    await wait(() => (q('conversation-composer-input') as HTMLTextAreaElement)?.value === 'Keep this coordinator draft');
    await wait(() => !(q('conversation-composer-send-btn') as HTMLButtonElement)?.disabled);
    assert.ok(q('action-tray-need-you-pill'), 'pending review is present but Quote opens normal composer');
    await act(async () => q('action-tray-need-you-pill').click());
    await act(async () => q('action-tray-request-changes').click());
    const { Simulate } = await import('react-dom/test-utils');
    await act(async () => Simulate.change(q('conversation-composer-input'), { target: { value: 'Keep this task response' } } as any));
    assert.equal(q('composer-quote-chips'), null, 'task response does not include chat quote chips');
    await act(async () => store.dispatch(addComposerQuote({ target: 'chain:c', quote: sample })));
    assert.equal((q('conversation-composer-input') as HTMLTextAreaElement).value, 'Keep this coordinator draft');
    await act(async () => q('action-tray-need-you-pill').click());
    await act(async () => q('action-tray-request-changes').click());
    assert.equal((q('conversation-composer-input') as HTMLTextAreaElement).value, 'Keep this task response', 'borrowed response survives Quote switching to normal chat');
    await act(async () => q('conversation-composer-tray-mode-cancel').click());
    await act(async () => q('action-tray-show-composer').click());
    await act(async () => q('composer-quote-remove-q1').click());
    assert.equal(posts.length, 0, 'Quote only stages context');
    assert.equal(Object.values(dom.window.localStorage).some(v => String(v).includes('Quote just this selected message text')), false, 'selected text is not persisted');
    assert.equal(store.getState().composerContext.byTarget['chain:c'].length, 1);
    await act(async () => q('conversation-composer-send-btn').click());
    await wait(() => posts.length === 1 && !(q('conversation-composer-send-btn') as HTMLButtonElement).disabled);
    assert.equal((q('conversation-composer-input') as HTMLTextAreaElement).value, 'Keep this coordinator draft');
    assert.ok(q('composer-quote-chips'));
    const { decryptVaultText } = await import('../src/ui/utils/vaultContent.ts');
    const plain = await decryptVaultText(posts[0].body.body, key);
    assert.match(plain, /^Keep this coordinator draft/);
    assert.match(plain, /Quote just this selected message text/);
    assert.match(plain, /"conversationId": "workerchat"/);
    assert.equal(posts[0].path, '/api/v1/chats/coordchat/messages');
    failPost = false; holdPost = true;
    await act(async () => q('conversation-composer-send-btn').click());
    await wait(() => posts.length === 2 && Boolean(postRelease));
    await act(async () => q('conversation-composer-shell').dispatchEvent(new dom.window.Event('submit', { bubbles: true, cancelable: true })));
    assert.equal(posts.length, 2, 'duplicate submit is blocked while pending');
    assert.equal((q('conversation-composer-input') as HTMLTextAreaElement).disabled, true);
    await act(async () => postRelease!());
    await wait(() => !q('composer-quote-chips') && (q('conversation-composer-input') as HTMLTextAreaElement).value === '');
    assert.equal(await decryptVaultText(posts[1].body.body, key), plain, 'retry preserves identical message snapshot');
    assert.equal(store.getState().composerContext.byTarget['chain:c'].length, 0);
    holdPost = true;
    postRelease = undefined;
    await act(async () => store.dispatch(addComposerQuote({ target: 'chain:c', quote: { ...sample, id: 'quote-only' } })));
    await wait(() => !(q('conversation-composer-send-btn') as HTMLButtonElement).disabled);
    await act(async () => q('conversation-composer-send-btn').click());
    await wait(() => posts.length === 3 && Boolean(postRelease));
    dom.window.localStorage.setItem('heimdall:composer:draft:coord', 'Newer draft from another pane');
    await act(async () => store.dispatch(addComposerQuote({ target: 'chain:c', quote: { ...sample, id: 'newer', selectedText: 'A newer quote' } })));
    await act(async () => postRelease!());
    await wait(() => !(q('conversation-composer-send-btn') as HTMLButtonElement).disabled);
    assert.match(await decryptVaultText(posts[2].body.body, key), /^Quoted context/, 'quote-only normal Send works');
    assert.equal((q('conversation-composer-input') as HTMLTextAreaElement).value, 'Newer draft from another pane');
    assert.deepEqual(store.getState().composerContext.byTarget['chain:c'].map((q: QuoteContext) => q.id), ['newer'], 'success consumes only submitted chips');
  });
});
