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
import { AgentChatPane } from '../src/ui/components/workbench/AgentChatPane.tsx';
import { ShortcutProvider } from '../src/ui/services/shortcuts/ShortcutContext.tsx';
import type { QuoteContext } from '../src/ui/utils/quoteContext.ts';

// REQ-MORPH (conversation page): AgentChatPane opts in to the morphing composer. Every open
// condition the pane owns (focus, raw draft incl. restored whitespace, attachments, the
// native file chooser, quotes, borrowed tray modes, owned menus, pending reconfiguration,
// read-only) must hold the card open, and the classic controls/IDs must survive.

const sampleQuote: QuoteContext = { version: 1, id: 'q1', selectedText: 'quoted words', capturedAt: 1,
  source: { kind: 'agent_message', messageId: 'm1', conversationId: 'workerchat', chainId: 'c', agentInstanceId: 'worker', author: 'Worker', createdUnixMs: 1, href: '#/conversations/worker?msg=m1' } };

type Options = { draft?: string; attention?: boolean; recovery?: boolean; aux?: boolean; onOpenAuxTab?: (content: any, title?: string) => void };

async function fixture(options: Options, run: (ctx: any) => Promise<void>) {
  const dom = new JSDOM('<div id="root"></div><button id="outside">outside</button>', { url: 'http://localhost/#/conversations/worker', pretendToBeVisual: true });
  const saved = new Map<string, PropertyDescriptor | undefined>();
  const install = (name: string, value: any) => { saved.set(name, Object.getOwnPropertyDescriptor(globalThis, name)); Object.defineProperty(globalThis, name, { value, configurable: true, writable: true }); };
  class RO { observe() {} unobserve() {} disconnect() {} }
  const frames = new Set<ReturnType<typeof setTimeout>>();
  dom.window.requestAnimationFrame = (cb: FrameRequestCallback) => {
    const timer = setTimeout(() => { frames.delete(timer); cb(Date.now()); }, 1);
    frames.add(timer); return timer as any;
  };
  dom.window.cancelAnimationFrame = (id: any) => { clearTimeout(id); frames.delete(id); };
  dom.window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }) as any;
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
  await unlockVault(store, '63'.repeat(32));
  const previousFetch = globalThis.fetch;
  globalThis.fetch = (async (input: any) => {
    const url = new URL(String(input), 'http://localhost'); const path = url.pathname;
    let data: any = {};
    if (path.includes('/chats/by-instance/')) data = { conversation_id: 'workerchat', agent_instance_id: 'worker', agent_id: 'worker-identity', chain_id: 'c', runtime_status: 'running' };
    else if (path.endsWith('/messages')) data = [];
    else if (path.endsWith('/conversation')) data = { chain_id: 'c', coordinator_agent_instance_id: 'coord', conversation_id: 'coordchat', replaced_coordinator_instance_ids: [] };
    else if (/\/agent-instances\/[^/]+$/.test(path)) data = { agent_instance_id: 'worker', agent_id: 'identity', provider: 'claude', model: 'opus', bridge_id: 'b', runtime_status: 'running' };
    else if (path.endsWith('/reconfigurations')) data = { operations: options.recovery ? [{ operation_id: 'op1', agent_instance_id: 'worker', phase: 'recovery_required', revision: 1,
      failure_code: 'launch_failed', failure_message: 'launch failed', source: { bridge_id: 'b', provider: 'claude', model: 'opus' }, destination: { bridge_id: 'b', provider: 'claude', model: 'sonnet' } }] : [] };
    else if (path.endsWith('/provider-status')) data = { providers: [{ provider: 'claude', enabled: true, state: 'present', catalog_state: 'active', models: [{ model_id: 'opus', state: 'active' }] }] };
    else if (path.endsWith('/bridges')) data = [{ bridge_id: 'b', status: 'online', runtime_connected: true, reconfiguration_supported: true }];
    else if (path.endsWith('/agents/live')) data = [];
    else if (path.endsWith('/task-chains/c')) data = { chain_id: 'c', title: 'Test chain', coordinator_agent_instance_id: 'coord', members: [] };
    else if (path.endsWith('/tasks')) data = [];
    else if (path.endsWith('/attention')) data = { items: options.attention && url.searchParams.get('kind') === 'task' ? [{
      card_id: 'crd_review', kind: 'task', provider: 'task_validation', title: 'Review task', status: 'pending', snoozed: false,
      urgency: 'warn', operations: [], action_refs: { chain_id: 'c', task_id: 'task_review' },
      details: { attention: 'review', status: 'in_review', priority: 'p2' }, context: { chain_title: 'Test chain' },
    }] : [] };
    return { ok: true, status: 200, headers: { get: () => 'application/json' }, text: async () => JSON.stringify({ data }), json: async () => ({ data }) } as any;
  }) as any;
  if (options.draft !== undefined) dom.window.localStorage.setItem('heimdall:composer:draft:worker', options.draft);
  const root = createRoot(dom.window.document.getElementById('root')!);
  const q = (id: string) => dom.window.document.querySelector('[data-debug-id="' + id + '"]') as HTMLElement;
  const wait = async (fn: () => boolean, label = '') => { for (let i = 0; i < 150; i++) { if (fn()) return; await act(async () => { await new Promise(r => setTimeout(r, 10)); }); } assert.ok(fn(), label); };
  const expanded = () => q('conversation-composer-card')?.getAttribute('data-expanded');
  const focusIn = async (el: HTMLElement) => act(async () => { el.focus(); });
  const blurTo = async (el: HTMLElement) => act(async () => { el.focus(); });
  try {
    let content: React.ReactElement = React.createElement(AgentChatPane, { agentInstanceId: 'worker', paneId: 'test-pane', isMobile: false, onOpenAuxTab: options.onOpenAuxTab } as any);
    if (options.aux) {
      // The REAL aux mount path: the mobile sheet -> AuxTabContent -> AgentChatPane variant auxSubagent.
      const { AuxDock } = await import('../src/ui/components/auxiliary/AuxDock.tsx');
      const { openAuxTab } = await import('../src/ui/store/auxPanesSlice.ts');
      const treeId = { kind: 'agent' as const, agentInstanceId: 'coord' };
      store.dispatch(openAuxTab({ treeId, content: { type: 'subagentChat', agentInstanceId: 'worker' } as any }));
      content = React.createElement(AuxDock, { treeId, isMobile: true, shown: true, ctx: { agentInstanceId: 'coord', conversationId: 'coordchat', title: 'Coord', chainId: 'c',
        projectId: '', projectName: '', bridgeId: 'b', defaultCwd: '', shellDefaultCwd: undefined, shellCwdReady: true, projectVcsEnabled: false,
        projectExplorerAccess: 'disabled', directories: [], members: [], participantIds: null, isResolved: true } as any } as any);
    }
    await act(async () => root.render(React.createElement(Provider, { store, children: React.createElement(ShortcutProvider, { children: content }) })));
    await wait(() => Boolean(q('conversation-composer-card') || q('action-tray')), 'composer or action tray rendered');
    await run({ dom, store, q, wait, expanded, focusIn, blurTo, outside: dom.window.document.getElementById('outside')! });
  } finally {
    await act(async () => { root.unmount(); store.dispatch(heimdallApi.util.resetApiState()); await new Promise(r => setTimeout(r, 60)); });
    globalThis.fetch = previousFetch; await clearActiveKey();
    for (const frame of frames) clearTimeout(frame);
    dom.window.close(); for (const [name, descriptor] of saved) { if (descriptor) Object.defineProperty(globalThis, name, descriptor); else delete (globalThis as any)[name]; }
  }
}

test('conversation composer is the morph shell: collapsed pill keeps classic IDs; focus opens, leaving collapses, empty Escape closes', async () => {
  await fixture({}, async ({ q, expanded, focusIn, blurTo, outside, dom }) => {
    const card = q('conversation-composer-card');
    assert.equal(card.hasAttribute('data-composer-morph'), true);
    assert.equal(expanded(), 'false');
    assert.ok(card.classList.contains('ui-frost-card'), 'frost rim kept');
    for (const id of ['conversation-composer-shell', 'conversation-composer-frost', 'conversation-composer-context', 'conversation-composer-bridge-chip',
      'conversation-runtime-status-chip', 'conversation-composer-status', 'conversation-composer-input', 'conversation-composer-toolbar', 'conversation-attach-btn',
      'conversation-attach-input', 'conversation-request-pane-btn', 'conversation-tasks-btn', 'conversation-runtime-menu-btn', 'conversation-composer-send-btn',
      'conversation-composer-morph-context', 'conversation-composer-morph-tools', 'conversation-composer-morph-trailing', 'conversation-composer-morph-spacer']) {
      assert.ok(q(id), `${id} rendered`);
    }
    assert.equal(q('conversation-composer-input').hasAttribute('data-composer-morph-field'), true);
    assert.equal(q('conversation-composer-morph-tools').getAttribute('inert'), '', 'collapsed tools are inert');
    assert.equal(q('conversation-composer-morph-context').getAttribute('aria-hidden'), 'true');
    await focusIn(q('conversation-composer-input'));
    assert.equal(expanded(), 'true');
    assert.equal(q('conversation-composer-morph-tools').hasAttribute('inert'), false);
    // Owned controls keep it open; leaving the composer collapses it.
    await focusIn(q('conversation-attach-btn'));
    assert.equal(expanded(), 'true');
    await blurTo(outside);
    assert.equal(expanded(), 'false');
    await focusIn(q('conversation-composer-input'));
    await act(async () => { q('conversation-composer-input').dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); });
    assert.equal(expanded(), 'false', 'Escape on the empty field collapses');
    assert.notEqual(dom.window.document.activeElement, q('conversation-composer-input'));
  });
});

test('restored whitespace-only draft holds the composer open without focus; Cmd/Ctrl+Enter path is untouched', async () => {
  await fixture({ draft: '   ' }, async ({ q, wait, expanded }) => {
    await wait(() => (q('conversation-composer-input') as HTMLTextAreaElement).value === '   ', 'restored draft');
    assert.equal(expanded(), 'true');
    assert.equal((q('conversation-composer-send-btn') as HTMLButtonElement).disabled, true, 'whitespace still cannot be sent');
  });
});

test('quotes, attachments chooser lifecycle, owned status menu and mention popup each hold it open', async () => {
  await fixture({}, async ({ q, store, wait, expanded, focusIn, blurTo, outside, dom }) => {
    // Quote chip (chat target of this pane): quoting focuses the field; the quote alone also
    // holds it open once focus leaves.
    await act(async () => store.dispatch(addComposerQuote({ target: 'worker', quote: sampleQuote })));
    await wait(() => Boolean(q('composer-quote-chips')), 'quote chip');
    await blurTo(outside);
    assert.equal(expanded(), 'true', 'quotes hold it open');
    await act(async () => q('composer-quote-remove-q1').click());
    await blurTo(outside);
    assert.equal(expanded(), 'false', 'removing the last quote releases it');
    // Native file chooser: open from the tools, window loses focus, focus lands elsewhere.
    await focusIn(q('conversation-composer-input'));
    const fileInput = q('conversation-attach-input') as HTMLInputElement;
    let chooserOpened = 0; fileInput.click = () => { chooserOpened++; };
    await act(async () => q('conversation-attach-btn').click());
    assert.equal(chooserOpened, 1);
    await blurTo(outside);
    assert.equal(expanded(), 'true', 'file chooser holds it open');
    await act(async () => { fileInput.dispatchEvent(new dom.window.Event('cancel')); });
    assert.equal(expanded(), 'false', 'cancelling the chooser releases it');
    // Owned runtime status menu (start/stop), opened and then focus moved away.
    await focusIn(q('conversation-composer-input'));
    await act(async () => q('conversation-runtime-status-chip').click());
    await wait(() => Boolean(q('conversation-runtime-status-toggle-btn')), 'status menu open');
    await blurTo(outside);
    assert.equal(expanded(), 'true', 'open owned menu holds it open');
    await act(async () => { dom.window.document.dispatchEvent(new dom.window.MouseEvent('mousedown', { bubbles: true })); });
    await wait(() => !q('conversation-runtime-status-toggle-btn'), 'status menu closed');
    assert.equal(expanded(), 'false');
    // Mention popup: typing "@" opens it (and the draft holds it open too); Escape closes the
    // popup first without blurring the composer.
    const { Simulate } = await import('react-dom/test-utils');
    await focusIn(q('conversation-composer-input'));
    await act(async () => Simulate.change(q('conversation-composer-input'), { target: { value: '@', selectionStart: 1 } } as any));
    await act(async () => { q('conversation-composer-input').dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); });
    assert.equal(dom.window.document.activeElement, q('conversation-composer-input'), 'Escape with a draft never blurs');
    assert.equal(expanded(), 'true');
  });
});

test('borrowed Request changes tray mode holds it open with an empty tray draft and Escape cancels the mode first', async () => {
  await fixture({ attention: true }, async ({ q, wait, expanded, blurTo, outside, dom }) => {
    await wait(() => Boolean(q('action-tray-request-changes')) || Boolean(q('action-tray-need-you-pill')), 'action tray');
    if (!q('action-tray-request-changes')) await act(async () => q('action-tray-need-you-pill').click());
    await act(async () => q('action-tray-request-changes').click());
    await wait(() => Boolean(q('conversation-composer-tray-mode')), 'borrowed mode');
    await blurTo(outside);
    assert.equal((q('conversation-composer-input') as HTMLTextAreaElement).value, '');
    assert.equal(expanded(), 'true', 'borrowed tray mode holds it open');
    q('conversation-composer-input').focus();
    await act(async () => { q('conversation-composer-input').dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); });
    await wait(() => !q('conversation-composer-tray-mode'), 'Escape cancels the borrowed mode');
    assert.equal(dom.window.document.activeElement, q('conversation-composer-input') ?? dom.window.document.activeElement);
  });
});

test('pending reconfiguration (recovery, read-only) keeps Reset/Apply and the read-only notice visible at full size while unfocused', async () => {
  await fixture({ recovery: true }, async ({ q, wait, expanded }) => {
    await wait(() => Boolean(q('conversation-reconfigure-apply-btn')), 'pending actions');
    assert.ok(q('conversation-reconfigure-reset-btn'));
    assert.ok(q('conversation-configuration-read-only'), 'read-only notice replaces the field and stays visible');
    assert.equal(q('conversation-composer-send-btn'), null, 'pending actions replace send');
    assert.equal(q('conversation-composer-morph-tools'), null, 'no tools beside pending actions');
    assert.equal(expanded(), 'true', 'pending actions hold it open');
  });
});

test('aux sub-agent chat: the mobile sheet is the visible region and the chat sizes from it (no second viewport correction)', async () => {
  await fixture({ aux: true }, async ({ dom, q, wait, expanded, focusIn, outside }) => {
    const dock = q('aux-dock');
    assert.equal(dock.getAttribute('data-aux-mobile-sheet'), 'true');
    const cls = dock.className.split(/\s+/);
    // REQ-VIEWPORT-ORIGIN-1: placed and sized by the shared utility (origin + height), not
    // `inset-0`, whose bottom edge is the layout viewport's — behind the soft keyboard.
    for (const c of ['fixed', 'inset-x-0', 'top-0', 'app-viewport-height', 'z-[70]']) assert.ok(cls.includes(c), `aux sheet has ${c}`);
    for (const c of ['inset-0', 'bottom-0', 'h-screen', 'h-full']) assert.ok(!cls.includes(c), `aux sheet does not use ${c}`);
    assert.match(dock.className, /translate-x-0/, 'shown sheet still slides in from the right');

    const card = q('conversation-composer-card');
    const composerDock = q('conversation-thread-composer-dock');
    assert.ok(card && composerDock && dock.contains(composerDock) && composerDock.contains(card), 'aux chat composer mounts inside the aux sheet');
    // Pane-owned layout: the composer floats at the bottom of its pane, and nothing between it
    // and the sheet is viewport-positioned or reads the viewport vars again.
    assert.match(composerDock.className, /(^|\s)absolute(\s|$)/);
    assert.match(composerDock.className, /(^|\s)bottom-0(\s|$)/);
    for (let el: HTMLElement | null = composerDock.parentElement; el && el !== dock; el = el.parentElement) {
      assert.ok(!/(^|\s)fixed(\s|$)/.test(el.className), `no fixed box between composer and sheet: ${el.className}`);
      assert.ok(!/app-viewport|--app-viewport/.test(el.className + (el.getAttribute('style') || '')), `no second viewport correction: ${el.className}`);
    }
    // The transcript scroller (scroll owner) lives in the same pane as the composer.
    const scroller = dock.querySelector('.chat-scrollbar') as HTMLElement;
    assert.ok(scroller && /overflow-y-auto/.test(scroller.className), 'transcript owns vertical scrolling inside the sheet');
    assert.ok(composerDock.parentElement!.contains(scroller), 'scroller and composer share the pane');

    // Morph behaviour is intact in the aux variant.
    assert.equal(expanded(), 'false');
    await focusIn(q('conversation-composer-input'));
    await wait(() => expanded() === 'true', 'focus opens the aux composer');
    await focusIn(outside);
    await wait(() => expanded() === 'false', 'leaving collapses it');
    void dom;
  });
});

// WebKit (Safari, iOS) never focuses a pressed <button>: the field blurs to <body> with
// relatedTarget null. Before the press hold, that collapsed the card and made the tools
// inert between the press and its click, so + and the terminal button "disappeared". The
// click is only dispatched when the target is not inert (a browser never delivers it into an
// inert subtree; jsdom does not model inert, so it is checked at dispatch time).
for (const aux of [false, true]) {
  test(`${aux ? 'aux sub-agent' : 'main'} chat: WebKit-style presses on + and terminal run their handlers; the card stays open until a press outside`, async () => {
    const opened: string[] = [];
    // Main chat: the workbench owns the aux dock, so the pane's opener is a prop. Aux: the
    // real AuxDock opener adds a tab to the store.
    await fixture({ aux, onOpenAuxTab: aux ? undefined : (content: any) => opened.push(content.type) }, async ({ q, store, wait, expanded, focusIn, outside, dom }) => {
      const doc = dom.window.document as Document;
      const press = async (target: HTMLElement) => {
        const fire = (type: string) => act(async () => {
          const event = new dom.window.MouseEvent(type, { bubbles: true, cancelable: true, button: 0 });
          // jsdom has no PointerEvent; desktop Safari order, so a mouse pointer.
          if (type.startsWith('pointer')) Object.defineProperties(event, { pointerType: { value: 'mouse' }, isPrimary: { value: true } });
          target.dispatchEvent(event);
        });
        await fire('pointerdown'); await fire('mousedown');
        await act(async () => { (doc.activeElement as HTMLElement | null)?.blur(); });
        await fire('pointerup'); await fire('mouseup');
        if (target.closest('[inert]')) return false;
        await act(async () => { target.click(); });
        return true;
      };
      await wait(() => Boolean(q('conversation-composer-input')), 'composer input');
      await focusIn(q('conversation-composer-input'));
      assert.equal(expanded(), 'true');
      const fileInput = q('conversation-attach-input') as HTMLInputElement;
      let chooserOpened = 0; fileInput.click = () => { chooserOpened++; };
      assert.equal(await press(q('conversation-attach-btn')), true, '+ was inert when its click was dispatched');
      assert.equal(chooserOpened, 1, '+ opened the file chooser');
      await act(async () => { fileInput.dispatchEvent(new dom.window.Event('cancel')); });
      assert.equal(expanded(), 'true', 'still engaged after the chooser closes: focus never left for somewhere else');
      await press(outside);
      assert.equal(expanded(), 'false', 'a press outside the composer collapses it');
      // Terminal: open the card again, press it, and the handler must run.
      await focusIn(q('conversation-composer-input'));
      const terminal = q('conversation-request-pane-btn');
      assert.ok(terminal, 'terminal button rendered');
      const before = JSON.stringify(store.getState().auxPanes);
      assert.equal(await press(terminal), true, 'terminal was inert when its click was dispatched');
      if (aux) {
        // In the aux dock the terminal opens as the active tab, replacing this chat.
        assert.notEqual(JSON.stringify(store.getState().auxPanes), before);
        assert.match(JSON.stringify(store.getState().auxPanes), /"activeTabId":"pty__worker"/, 'terminal button opened the terminal tab');
      } else {
        assert.deepEqual(opened, ['agentPty'], 'terminal button opened a terminal tab');
        assert.equal(expanded(), 'true', 'still engaged after the terminal press');
        await press(outside);
        assert.equal(expanded(), 'false');
      }
    });
  });
}
