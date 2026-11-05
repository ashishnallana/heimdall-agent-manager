// NewConversationPage rewrite (new-conversation redesign spec §3.4, §4 #11-#14, step 7).
// The page mounts in jsdom against a vault-unlocked store with a recording fetch, so the
// tests see the real API calls: launching a conversation (POST /chats with the same
// payload as before, the 420ms launch transition, onLaunched), launching a shell
// (POST /shells), the remembered mode (localStorage heimdall:new-pane-mode) with the
// composerSwap body swap, and the issues line (rewritten copy, send disabled).
//
// Components are imported inside the DOM (react-dom decides input-event support when it
// is first evaluated). DOM nodes are compared with assert.ok(a === b), never assert.equal.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_new_conversation_page_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { makeVaultStore, unlockVault } from './helpers/vaultEndpointHarness.ts';

const TEST_KEY = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const BOOT_ID = 'b1'.repeat(16);
const ONLINE = { status: 'online', runtime_connected: true, reconfiguration_supported: true };
const RIVER = { bridge_id: 'b_river', label: 'riverwood', machine_os: 'linux', ...ONLINE };
const DAWN = { bridge_id: 'b_dawn', label: 'dawnstar', machine_os: 'linux', ...ONLINE };
const RIVER_OFF = { bridge_id: 'b_river', label: 'riverwood', machine_os: 'linux', status: 'offline', runtime_connected: false };
const AGENTS = [
  { agent_id: 'agt_coord', name: 'coordinator', slug: 'coordinator', state: 'active' },
  { agent_id: 'agt_solo', name: 'soloist', slug: 'soloist', state: 'active' },
];
const PROJECTS = [
  { project_id: 'p_conv', name: 'Conversation', slug: 'conversation', state: 'active' },
  { project_id: 'p_ham', name: 'heimdall-agent-manager', state: 'active', default_path: '/srv/ham', bridge_paths: [{ bridge_id: 'b_river', path: '/srv/ham' }] },
];
const PROVIDERS = {
  bridge_id: 'b_river',
  providers: [{ provider: 'claude', enabled: true, state: 'present', catalog_state: 'active', models: [{ model_id: 'opus', state: 'active' }] }],
};

type Call = { method: string; url: string; body: any };
type Ctx = {
  doc: Document;
  win: any;
  calls: Call[];
  animations: Array<{ keyframes: any; options: any }>;
  launched: string[];
  act: (fn: () => Promise<void> | void) => Promise<void>;
  render: (props?: Record<string, unknown>) => Promise<void>;
  settle: (ms?: number) => Promise<void>;
};

async function withPage(
  setup: { bridges?: any[]; prefs?: Record<string, unknown>; reducedMotion?: boolean; storage?: Record<string, string>; failPreferenceWrites?: boolean; width?: number },
  run: (ctx: Ctx) => Promise<void>,
) {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><main><div id="root"></div></main></body></html>', { url: 'http://localhost/' });
  const win = dom.window as any;
  Object.defineProperty(win, 'innerWidth', { value: setup.width ?? 1280, configurable: true });
  win.matchMedia = (q: string) => ({
    matches: Boolean(setup.reducedMotion) && q.includes('prefers-reduced-motion'),
    media: q, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {},
  });
  win.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
  const animations: Ctx['animations'] = [];
  win.HTMLElement.prototype.animate = function animate(keyframes: any, options: any) {
    animations.push({ keyframes, options });
    return { finished: Promise.resolve(), cancel() {} };
  };
  for (const [k, v] of Object.entries(setup.storage || {})) win.localStorage.setItem(k, v);

  const keys = ['window', 'document', 'HTMLElement', 'Node', 'KeyboardEvent', 'MouseEvent', 'localStorage', 'ResizeObserver'] as const;
  const saved: Record<string, unknown> = {};
  for (const k of keys) saved[k] = (globalThis as any)[k];
  const savedNavigator = (globalThis as any).navigator;
  const savedFetch = (globalThis as any).fetch;
  const savedRaf = (globalThis as any).requestAnimationFrame;
  const savedCaf = (globalThis as any).cancelAnimationFrame;
  for (const k of keys) (globalThis as any)[k] = k === 'window' ? win : k === 'document' ? win.document : win[k];
  Object.defineProperty(globalThis, 'navigator', { value: win.navigator, configurable: true });
  (globalThis as any).requestAnimationFrame = (cb: any) => setTimeout(cb, 0);
  (globalThis as any).cancelAnimationFrame = (id: any) => clearTimeout(id);
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

  const bridges = setup.bridges ?? [RIVER];
  const prefs = { agent_id: 'agt_coord', project_id: 'p_ham', bridge_id: 'b_river', favorite_agent_ids: ['agt_coord', 'agt_solo'], pinned_agent_ids: ['agt_coord', 'agt_solo'], ...setup.prefs };
  const calls: Call[] = [];
  const createdProjects: any[] = [];
  (globalThis as any).fetch = async (input: any, init: any = {}) => {
    const url = String(input?.url ?? input);
    const method = String(init?.method || input?.method || 'GET').toUpperCase();
    const raw = init?.body ?? (typeof input?.clone === 'function' && method !== 'GET' ? await input.clone().text() : '');
    let body: any = {};
    try { body = raw ? JSON.parse(String(raw)) : {}; } catch { body = raw; }
    calls.push({ method, url, body });
    const path = new URL(url, 'http://localhost').pathname;
    if (setup.failPreferenceWrites && method === 'PATCH' && path.endsWith('/me/conversation-launch')) {
      const failure = JSON.stringify({ error: { code: 'unavailable', message: 'Preferences are unavailable.' } });
      return { ok: false, status: 503, headers: { get: () => 'application/json' }, text: async () => failure, json: async () => JSON.parse(failure) } as any;
    }
    let data: any = {};
    if (path.endsWith('/me/conversation-launch')) data = prefs;
    else if (path.endsWith('/agents') && method === 'GET') data = AGENTS;
    else if (path.endsWith('/agents') && method === 'POST') data = { agent_id: 'agt_new', name: body.name, state: 'active' };
    else if (path.endsWith('/projects') && method === 'POST') {
      const created = { project_id: 'p_new', name: body.name, description: body.description, default_path: body.default_path, vcs_kind: body.vcs_kind, state: 'active' };
      createdProjects.push(created); data = created;
    }
    else if (path.endsWith('/projects')) data = { projects: [...PROJECTS, ...createdProjects] };
    else if (/\/bridges\/[^/]+\/fs$/.test(path)) data = { ok: true, path: new URL(url, 'http://localhost').searchParams.get('path') || '/srv', root: '/srv', parent: '', entries: [{ name: '.git', is_dir: true, hidden: true }], truncated: false };
    else if (/\/bridges\/[^/]+\/fs\/file$/.test(path)) data = { ok: false, path: '', viewable: false, error: { code: 'not_found', cause: 'path_not_found', message: 'Path does not exist' } };
    else if (path.endsWith('/bridges')) data = { bridges };
    else if (path.endsWith('/provider-status')) data = PROVIDERS;
    else if (path.endsWith('/bridge-support')) data = { entries: [] };
    else if (path.endsWith('/templates')) data = [];
    else if (path.endsWith('/me/experiments')) data = { flags: {} };
    else if (path.endsWith('/chats') && method === 'POST') data = { agent_instance_id: 'inst_new' };
    else if (path.includes('/agent-instances/')) data = { agent_instance_id: 'inst_new' };
    else if (path.endsWith('/shells') && method === 'POST') data = { session: { session_id: body.session_id, kind: 'shell', status: 'running' } };
    else if (path.includes('/public-key')) data = { unseal_boot_id: BOOT_ID };
    const text = JSON.stringify({ data });
    return { ok: true, status: 200, headers: { get: () => 'application/json' }, text: async () => text, json: async () => JSON.parse(text) } as any;
  };

  const { Provider } = await import('react-redux');
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { default: NewConversationPage } = await import('../src/ui/components/chat/NewConversationPage.tsx');
  const store = await makeVaultStore();
  await unlockVault(store, TEST_KEY);
  const root = createRoot(win.document.getElementById('root')!);
  const launched: string[] = [];
  const settle = async (ms = 40) => { await act(async () => { await new Promise((resolve) => setTimeout(resolve, ms)); }); };
  try {
    await run({
      doc: win.document,
      win,
      calls,
      animations,
      launched,
      act: async (fn) => { await act(async () => { await fn(); }); },
      settle,
      render: async (props = {}) => {
        await act(async () => {
          root.render(React.createElement(Provider, { store }, React.createElement(NewConversationPage, { onLaunched: (id: string) => launched.push(id), ...props })));
        });
        await settle(80);
      },
    });
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    (await import('../src/ui/utils/vaultCrypto.ts')).setActiveVaultKey(null);
    dom.window.close();
    for (const k of keys) (globalThis as any)[k] = saved[k];
    Object.defineProperty(globalThis, 'navigator', { value: savedNavigator, configurable: true });
    (globalThis as any).fetch = savedFetch;
    (globalThis as any).requestAnimationFrame = savedRaf;
    (globalThis as any).cancelAnimationFrame = savedCaf;
  }
}

const q = (doc: Document, id: string) => doc.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
const squash = (text: string | null | undefined) => String(text ?? '').replace(/\s+/g, ' ').trim();

async function until(ctx: Ctx, pred: () => boolean, label: string, ms = 3000) {
  const end = Date.now() + ms;
  while (!pred()) {
    if (Date.now() > end) assert.fail(`timed out waiting for: ${label}`);
    await ctx.settle(20);
  }
}

async function click(ctx: Ctx, el: HTMLElement | null) {
  assert.ok(el, 'element to click exists');
  await ctx.act(() => { el!.dispatchEvent(new ctx.win.MouseEvent('click', { bubbles: true, cancelable: true })); });
  await ctx.settle();
}

async function type(ctx: Ctx, el: HTMLElement | null, value: string) {
  assert.ok(el, 'field exists');
  const setter = Object.getOwnPropertyDescriptor(ctx.win.HTMLTextAreaElement.prototype, 'value')!.set!;
  await ctx.act(() => { setter.call(el, value); el!.dispatchEvent(new ctx.win.Event('input', { bubbles: true })); });
  await ctx.settle();
}

async function pickMode(ctx: Ctx, mode: 'agent' | 'shell') {
  await click(ctx, q(ctx.doc, 'new-convo-mode-token'));
  await click(ctx, q(ctx.doc, `new-convo-mode-option-${mode}`));
}

const sendButton = (doc: Document) => q(doc, 'new-convo-composer-send-btn') as HTMLButtonElement | null;
const issuesText = (doc: Document) => squash(q(doc, 'new-convo-launch-issues')?.textContent);

test('page renders headline -> meta -> composer -> issues -> footer, without the old launcher', async () => {
  await withPage({}, async (ctx) => {
    await ctx.render({ footer: React.createElement('div', { 'data-debug-id': 'test-footer' }, 'Home footer') });
    await until(ctx, () => !/Loading/.test(issuesText(ctx.doc)) && Boolean(q(ctx.doc, 'new-convo-runtime-picker')), 'hydration');
    for (const gone of ['new-convo-greeting', 'new-convo-subtitle', 'new-convo-mode-switch', 'new-convo-favorite-agents', 'new-convo-edit-favorites-btn', 'new-convo-project-select', 'new-convo-new-project-btn', 'new-convo-runtime-modal', 'new-convo-favorites-modal', 'new-convo-composer-bridge-btn', 'new-convo-shell-panel']) {
      assert.equal(q(ctx.doc, gone), null, `${gone} is gone`);
    }
    const order = ['new-convo-headline', 'new-convo-meta', 'new-convo-composer-shell', 'new-convo-launch-issues', 'test-footer'].map((id) => q(ctx.doc, id));
    order.forEach((el, i) => assert.ok(el, `region ${i} rendered`));
    for (let i = 1; i < order.length; i += 1) {
      assert.ok(order[i - 1]!.compareDocumentPosition(order[i]!) & ctx.win.Node.DOCUMENT_POSITION_FOLLOWING, `region ${i - 1} precedes region ${i}`);
    }
    // Composer look (spec §3.4) and its conversation body.
    const composer = q(ctx.doc, 'new-convo-composer-shell')!;
    for (const cls of ['bg-subtle', 'border-strong', 'rounded-[var(--radius-xl)]', 'px-4', 'pt-4', 'pb-3', 'focus-within:border-accent', 'focus-within:shadow-[0_0_0_1px_var(--color-accent)]']) {
      assert.ok(composer.className.split(/\s+/).includes(cls), `composer has ${cls}`);
    }
    const input = q(ctx.doc, 'new-convo-composer-input') as HTMLTextAreaElement;
    assert.equal(input.placeholder, 'Message the agent');
    assert.ok(q(ctx.doc, 'new-convo-attach-btn'));
    assert.ok(q(ctx.doc, 'new-convo-agent-picker'), 'agent chip');
    assert.equal(squash(q(ctx.doc, 'new-convo-send-shortcut')?.textContent), 'Ctrl Enter');
    assert.match(squash(q(ctx.doc, 'new-convo-runtime-picker')?.textContent), /Claude.*opus/i);
    assert.equal(sendButton(ctx.doc)?.getAttribute('aria-label'), 'Start conversation');
    assert.ok(sendButton(ctx.doc)!.className.includes('bg-accent'), 'accent send (IconButton variant=primary)');
    assert.equal(sendButton(ctx.doc)!.getAttribute('type'), 'submit');
    assert.equal(issuesText(ctx.doc), '', 'no issues once hydrated');
  });
});

test('launching a conversation makes the same API calls, keeps the 420ms launch transition and calls onLaunched', async () => {
  // The saved preferences differ from what hydration picks for the bridge, so one
  // remember() PATCH is expected, exactly as before the rewrite.
  await withPage({ prefs: { bridge_id: '' } }, async (ctx) => {
    await ctx.render();
    await until(ctx, () => !/Loading|Checking/.test(issuesText(ctx.doc)) && issuesText(ctx.doc) === '', 'hydration');
    const patches = ctx.calls.filter((c) => c.method === 'PATCH' && c.url.includes('/me/conversation-launch'));
    assert.deepEqual(patches.map((c) => c.body), [{ bridge_id: 'b_river' }]);

    assert.ok(sendButton(ctx.doc)!.disabled, 'send disabled with an empty draft');
    await type(ctx, q(ctx.doc, 'new-convo-composer-input'), '  Fix the flaky test  ');
    assert.ok(!sendButton(ctx.doc)!.disabled, 'send enabled with a draft');
    await click(ctx, sendButton(ctx.doc));
    await until(ctx, () => ctx.launched.length > 0, 'onLaunched');

    const posts = ctx.calls.filter((c) => c.method === 'POST' && new URL(c.url, 'http://localhost').pathname.endsWith('/chats'));
    assert.equal(posts.length, 1);
    const { initial_message, ...payload } = posts[0].body;
    assert.deepEqual(payload, { agent_id: 'agt_coord', artifact_ids: [], project_id: 'p_ham', bridge_id: 'b_river', provider: 'claude', model: 'opus' });
    const { decryptVaultText } = await import('../src/ui/utils/vaultCrypto.ts');
    assert.equal(await decryptVaultText(String(initial_message.body)), 'Fix the flaky test');
    assert.deepEqual(ctx.launched, ['inst_new']);

    assert.equal(ctx.animations.length, 1, 'one launch transition');
    assert.equal(ctx.animations[0].options.duration, 420);
    assert.equal(ctx.animations[0].options.easing, 'cubic-bezier(0.22, 1, 0.36, 1)');
    assert.equal(ctx.animations[0].options.fill, 'forwards');
  });
});

test('mode switch swaps the composer body with composerSwap, persists heimdall:new-pane-mode, and opens a shell', async () => {
  await withPage({}, async (ctx) => {
    await ctx.render();
    await until(ctx, () => issuesText(ctx.doc) === '', 'hydration');
    const composer = q(ctx.doc, 'new-convo-composer-shell')!;
    const body = () => composer.querySelector('[data-composer-body]') as HTMLElement;
    assert.equal(body().dataset.composerBody, 'agent');
    assert.ok(!body().className.includes('animate-composer-swap'), 'no swap animation on first render');

    await pickMode(ctx, 'shell');
    assert.equal(ctx.win.localStorage.getItem('heimdall:new-pane-mode'), 'shell');
    assert.ok(q(ctx.doc, 'new-convo-composer-shell') === composer, 'the container (and its border) stays mounted');
    assert.equal(body().dataset.composerBody, 'shell');
    assert.ok(body().className.includes('animate-composer-swap'), 'the new body plays composerSwap');
    assert.equal(q(ctx.doc, 'new-convo-composer-input'), null);
    const command = q(ctx.doc, 'new-shell-command') as HTMLTextAreaElement;
    assert.equal(command.placeholder, 'Run a command, or leave empty for an interactive shell');
    assert.ok(command.className.includes('font-mono'));
    assert.equal(squash(q(ctx.doc, 'new-shell-kind')?.textContent), 'zsh');
    const prompt = q(ctx.doc, 'new-shell-prompt')!;
    const promptClasses = prompt.className.split(/\s+/);
    assert.ok(promptClasses.includes('text-accent'), 'the $ prompt is accent');
    assert.ok(!promptClasses.includes('text-primary'), 'the $ prompt carries no competing primary tone');
    assert.equal(squash(q(ctx.doc, 'new-shell-hint')?.textContent), 'Opens in the project folder on riverwood');
    assert.equal(squash(q(ctx.doc, 'new-convo-mode-token')?.textContent), 'shell');

    await type(ctx, command, 'npm test');
    const open = q(ctx.doc, 'new-shell-open') as HTMLButtonElement;
    await until(ctx, () => !open.disabled, 'Open shell enabled');
    await click(ctx, open);
    await until(ctx, () => ctx.launched.length > 0, 'shell onLaunched');
    const shellPosts = ctx.calls.filter((c) => c.method === 'POST' && new URL(c.url, 'http://localhost').pathname.endsWith('/shells'));
    assert.equal(shellPosts.length, 1);
    assert.equal(shellPosts[0].body.kind, 'shell');
    assert.equal(shellPosts[0].body.project_id, 'p_ham');
    const { decryptVaultText } = await import('../src/ui/utils/vaultCrypto.ts');
    const spec = JSON.parse(await decryptVaultText(String(shellPosts[0].body.enc_spec)));
    assert.equal(spec.cmd, 'npm test');
    assert.equal(spec.cwd, '/srv/ham');
    assert.deepEqual(ctx.launched, [shellPosts[0].body.session_id]);
    assert.equal(ctx.calls.filter((c) => c.url.includes('/chats') && c.method === 'POST').length, 0, 'no conversation launched');

    await pickMode(ctx, 'agent');
    assert.equal(ctx.win.localStorage.getItem('heimdall:new-pane-mode'), 'agent');
    assert.equal(body().dataset.composerBody, 'agent');
  });
});

test('the remembered mode is restored on mount; a launch intent wins without rewriting it', async () => {
  await withPage({ storage: { 'heimdall:new-pane-mode': 'shell' } }, async (ctx) => {
    await ctx.render();
    assert.ok(q(ctx.doc, 'new-shell-command'), 'starts in shell mode');
    assert.equal(squash(q(ctx.doc, 'new-convo-mode-token')?.textContent).replace(/\s/g, ''), 'shell');
  });
  await withPage({ storage: { 'heimdall:new-pane-mode': 'shell' } }, async (ctx) => {
    await ctx.render({ launchIntent: 'agent' });
    assert.ok(q(ctx.doc, 'new-convo-composer-input'), 'the intent selects conversation mode');
    assert.equal(ctx.win.localStorage.getItem('heimdall:new-pane-mode'), 'shell', 'the saved preference is untouched');
  });
});

test('reduced motion: the mode swap applies no animation class', async () => {
  await withPage({ reducedMotion: true }, async (ctx) => {
    await ctx.render();
    await pickMode(ctx, 'shell');
    const body = q(ctx.doc, 'new-convo-composer-shell')!.querySelector('[data-composer-body]') as HTMLElement;
    assert.equal(body.dataset.composerBody, 'shell');
    assert.ok(!body.className.includes('animate-'), 'no animate-* class under reduced motion');
  });
});

test('issues render as a quiet status line with rewritten copy, and send stays disabled', async () => {
  // One bridge, offline: the `on [bridge]` clause is hidden. T8: on a cold start
  // that is the full no-bridge screen, so mount embedded (banner case). The banner
  // says what is wrong, so the quiet line does not repeat it; send stays disabled.
  await withPage({ bridges: [RIVER_OFF] }, async (ctx) => {
    const { bridgeIssueText } = await import('../src/ui/components/chat/NewConversationPage.tsx');
    assert.equal(bridgeIssueText('agent', true), 'Choose a connected bridge above.');
    assert.equal(bridgeIssueText('shell', true), 'Choose a connected bridge above.');
    assert.equal(bridgeIssueText('shell', false), 'No bridge is online. Start a bridge to launch a shell.');
    assert.equal(bridgeIssueText('agent', false), 'No bridge is online. Start a bridge to start a conversation.');
    await ctx.render({ embedded: true });
    await until(ctx, () => Boolean(q(ctx.doc, 'no-bridge-banner')) && !/Loading/.test(issuesText(ctx.doc)), 'banner');
    const line = q(ctx.doc, 'new-convo-launch-issues')!;
    assert.equal(line.getAttribute('role'), 'status');
    assert.doesNotMatch(issuesText(ctx.doc), /No bridge is online/, 'the banner carries it');
    assert.doesNotMatch(issuesText(ctx.doc), /Agent settings/);
    await type(ctx, q(ctx.doc, 'new-convo-composer-input'), 'hello');
    assert.ok(sendButton(ctx.doc)!.disabled, 'send disabled while issues exist');
    await ctx.act(() => { q(ctx.doc, 'new-convo-composer-shell')!.dispatchEvent(new ctx.win.Event('submit', { bubbles: true, cancelable: true })); });
    await ctx.settle();
    assert.equal(ctx.calls.filter((c) => c.url.includes('/chats') && c.method === 'POST').length, 0, 'a forced submit launches nothing');

    await pickMode(ctx, 'shell');
    assert.ok(q(ctx.doc, 'no-bridge-banner'), 'banner in shell mode too');
    assert.ok((q(ctx.doc, 'new-shell-open') as HTMLButtonElement).disabled, 'Open shell disabled while issues exist');
  });
  // Two bridges with one online, the chosen one offline: point at the headline token.
  await withPage({ bridges: [RIVER_OFF, DAWN] }, async (ctx) => {
    await ctx.render();
    await until(ctx, () => /Choose a connected bridge above\./.test(issuesText(ctx.doc)), 'bridge issue above');
    assert.ok(q(ctx.doc, 'new-convo-machine-token'), 'the bridge clause is shown');
    assert.doesNotMatch(issuesText(ctx.doc), /Agent settings/);
    await type(ctx, q(ctx.doc, 'new-convo-composer-input'), 'hello');
    assert.ok(sendButton(ctx.doc)!.disabled);
  });
});

test('a failed preference save shows its error and Retry in shell mode too', async () => {
  await withPage({ failPreferenceWrites: true, storage: { 'heimdall:new-pane-mode': 'shell' } }, async (ctx) => {
    await ctx.render();
    await until(ctx, () => Boolean(q(ctx.doc, 'new-shell-command')) && Boolean(q(ctx.doc, 'new-convo-project-token')), 'shell mode');
    await click(ctx, q(ctx.doc, 'new-convo-project-token'));
    await click(ctx, q(ctx.doc, 'new-convo-project-option-none'));
    await until(ctx, () => Boolean(q(ctx.doc, 'new-convo-launch-error')), 'preference error alert');
    assert.ok(q(ctx.doc, 'new-shell-command'), 'still in shell mode');
    assert.ok(q(ctx.doc, 'new-convo-retry-preferences-btn'), 'Retry saving selections is offered in shell mode');
    const patches = () => ctx.calls.filter((c) => c.method === 'PATCH' && c.url.includes('/me/conversation-launch'));
    const before = patches().length;
    const retry = q(ctx.doc, 'new-convo-retry-preferences-btn') as HTMLButtonElement;
    await until(ctx, () => !retry.disabled, 'Retry enabled');
    await click(ctx, retry);
    await until(ctx, () => patches().length > before, 'retry re-sends the preference write');
  });
});

// Spec §3.7 (T9): below 768px every launcher menu is a bottom sheet, and the composer
// docks to the bottom (sticky, above --ui-bottom-chrome) except while a sheet is open.
test('mobile (390px): all five menus open as bottom sheets and the composer undocks while one is open', async () => {
  await withPage({ width: 390, bridges: [RIVER, DAWN] }, async (ctx) => {
    await ctx.render();
    await until(ctx, () => !/Loading/.test(issuesText(ctx.doc)) && Boolean(q(ctx.doc, 'new-convo-runtime-picker')), 'hydration');
    const dock = q(ctx.doc, 'new-convo-launch-dock')!;
    const docked = () => dock.hasAttribute('data-docked') && dock.className.includes('max-md:sticky');
    assert.ok(docked(), 'composer docked at rest');
    for (const cls of ['max-md:bottom-[max(var(--ui-bottom-chrome,0px),env(safe-area-inset-bottom,0px))]', 'max-md:z-sticky', 'max-md:bg-canvas']) {
      assert.ok(dock.className.includes(cls), `dock has ${cls}`);
    }
    // Page padding 24px 16px 0 on mobile (120px top from md); the page fills the height
    // and the dock is pushed to the bottom (max-md:mt-auto).
    const classes = (el: Element) => el.className.split(/\s+/);
    const column = q(ctx.doc, 'new-convo-headline')!.closest('div.mx-auto') as HTMLElement;
    for (const cls of ['pt-6', 'md:pt-[120px]', 'pb-0', 'md:pb-16', 'max-md:flex-1']) assert.ok(classes(column).includes(cls), `column has ${cls}`);
    assert.ok(!classes(column).includes('pt-12'), 'no 48px top padding on mobile');
    const page = q(ctx.doc, 'new-conversation-page')!;
    for (const cls of ['px-4', 'max-md:flex', 'max-md:flex-1', 'max-md:flex-col']) assert.ok(classes(page).includes(cls), `page has ${cls}`);
    assert.ok(classes(dock).includes('max-md:mt-auto'), 'dock sits at the bottom of the column');
    assert.ok(!q(ctx.doc, 'new-convo-footer'), 'no empty footer under the docked composer');
    // The toolbar is one row: it never wraps, the buttons keep their size and the chips shrink and truncate.
    const toolbar = q(ctx.doc, 'new-convo-composer-toolbar')!;
    assert.ok(classes(toolbar).includes('flex-nowrap') && !classes(toolbar).includes('flex-wrap'), 'toolbar never wraps');
    for (const id of ['new-convo-attach-btn', 'new-convo-composer-send-btn']) assert.ok(classes(q(ctx.doc, id)!).includes('shrink-0'), `${id} keeps its size`);
    for (const id of ['new-convo-agent-picker', 'new-convo-runtime-picker']) {
      const chip = q(ctx.doc, id)!;
      for (const cls of ['min-w-0', 'shrink', 'h-10', 'max-w-[9rem]']) assert.ok(classes(chip).includes(cls), `${id} has ${cls}`);
      assert.ok(classes(chip.querySelector('[data-token-value]')!).includes('truncate'), `${id} value truncates`);
    }
    const providerName = q(ctx.doc, 'new-convo-runtime-picker')!.querySelector('[data-runtime-chip-provider]') as HTMLElement | null;
    if (providerName) assert.ok(classes(providerName).includes('max-[439px]:sr-only'), 'provider chip is icon-only at phone widths');
    // No Kbd hint; the model name is hidden on the chip below md.
    assert.ok(!q(ctx.doc, 'new-convo-send-shortcut'), 'no Kbd on mobile');
    await until(ctx, () => Boolean(q(ctx.doc, 'new-convo-runtime-picker')!.querySelector('[data-runtime-chip-model]')), 'model on the chip');
    const model = q(ctx.doc, 'new-convo-runtime-picker')!.querySelector('[data-runtime-chip-model]') as HTMLElement;
    assert.ok(model && model.className.includes('hidden') && model.className.includes('md:inline'), 'model name hidden below md');
    // 44px touch targets on the attach and send buttons and the headline tokens; the chips are 40px.
    for (const id of ['new-convo-attach-btn', 'new-convo-composer-send-btn']) assert.ok(q(ctx.doc, id)!.className.includes('h-11'), `${id} is 44px`);

    for (const token of ['new-convo-mode-token', 'new-convo-project-token', 'new-convo-machine-token', 'new-convo-agent-picker', 'new-convo-runtime-picker']) {
      const trigger = q(ctx.doc, token);
      assert.ok(trigger, `${token} rendered`);
      const chip = token === 'new-convo-agent-picker' || token === 'new-convo-runtime-picker';
      assert.ok((chip ? /(^|\s)h-10(\s|$)/ : /(^|\s)min-h-11(\s|$)/).test(trigger!.className), `${token} is ${chip ? '40px' : '>= 44px'}`);
      await click(ctx, trigger);
      const sheet = ctx.doc.querySelector('[role="dialog"]') as HTMLElement | null;
      assert.ok(sheet, `${token} opens a sheet`);
      for (const cls of ['rounded-t-[var(--radius-xl)]', 'pb-[env(safe-area-inset-bottom)]', 'animate-sheet-in']) {
        assert.ok(sheet!.className.includes(cls), `${token} sheet has ${cls}`);
      }
      assert.ok(sheet!.parentElement!.className.includes('bg-scrim'), `${token} sheet has a scrim`);
      const handle = sheet!.querySelector('span[aria-hidden="true"]') as HTMLElement | null;
      assert.ok(handle && handle.className.includes('w-9') && handle.className.includes('h-1'), `${token} sheet has a handle`);
      if (token === 'new-convo-runtime-picker') {
        const columns = q(ctx.doc, 'new-convo-model-column')!.parentElement as HTMLElement;
        assert.ok(columns.className.includes('flex-col') || columns.className.includes('grid-cols-1'), 'provider menu columns stack');
      }
      assert.ok(!docked(), `${token}: composer is static while the sheet is open`);
      await ctx.act(() => { ctx.doc.activeElement!.dispatchEvent(new ctx.win.KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); });
      await ctx.settle();
      const closing = ctx.doc.querySelector('[role="dialog"]');
      if (closing) await ctx.act(() => { closing.dispatchEvent(new ctx.win.Event('animationend', { bubbles: true })); });
      await ctx.settle();
      assert.ok(!ctx.doc.querySelector('[role="dialog"]'), `${token} sheet closed`);
      assert.ok(docked(), `${token}: composer docks again after close`);
    }
  });
});

test('mobile (390px): creating a favorite agent from the agent sheet closes it and re-docks the composer', async () => {
  await withPage({ width: 390 }, async (ctx) => {
    await ctx.render();
    await until(ctx, () => !/Loading/.test(issuesText(ctx.doc)) && Boolean(q(ctx.doc, 'new-convo-agent-picker')), 'hydration');
    const dock = q(ctx.doc, 'new-convo-launch-dock')!;
    const docked = () => dock.hasAttribute('data-docked') && dock.className.includes('max-md:sticky');
    await click(ctx, q(ctx.doc, 'new-convo-agent-picker'));
    await click(ctx, q(ctx.doc, 'new-convo-edit-favorites'));
    await click(ctx, q(ctx.doc, 'new-convo-create-agent-toggle'));
    assert.ok(!docked(), 'composer is static while the agent sheet is open');
    const input = q(ctx.doc, 'new-convo-agent-name-input') as HTMLInputElement;
    const setter = Object.getOwnPropertyDescriptor(ctx.win.HTMLInputElement.prototype, 'value')!.set!;
    await ctx.act(() => { setter.call(input, 'Helper'); input.dispatchEvent(new ctx.win.Event('input', { bubbles: true })); });
    await click(ctx, q(ctx.doc, 'new-convo-create-favorite-agent-btn'));
    await until(ctx, () => ctx.calls.some((c) => c.method === 'POST' && new URL(c.url, 'http://localhost').pathname.endsWith('/agents')), 'agent created');
    await ctx.settle();
    const closing = ctx.doc.querySelector('[role="dialog"]');
    if (closing) await ctx.act(() => { closing.dispatchEvent(new ctx.win.Event('animationend', { bubbles: true })); });
    await ctx.settle();
    assert.ok(!ctx.doc.querySelector('[role="dialog"]'), 'agent sheet closed after creating');
    assert.ok(docked(), 'composer docks again after creating an agent');
  });
});

test('desktop (1280px): the composer is not docked by mobile rules and the Kbd hint shows', async () => {
  await withPage({}, async (ctx) => {
    await ctx.render();
    await until(ctx, () => Boolean(q(ctx.doc, 'new-convo-runtime-picker')), 'hydration');
    assert.ok(q(ctx.doc, 'new-convo-send-shortcut'), 'Kbd on desktop');
    // The dock classes are all max-md: scoped, so nothing applies at >= 768px.
    const dock = q(ctx.doc, 'new-convo-launch-dock')!;
    assert.ok(dock.className.split(/\s+/).filter((c) => /sticky|bottom-|bg-canvas/.test(c)).every((c) => c.startsWith('max-md:')));
  });
});

test('New project: opened from the project menu, browses the chosen bridge, creates with default_path and selects the project', async () => {
  await withPage({}, async (ctx) => {
    await ctx.render();
    await until(ctx, () => !/Loading/.test(issuesText(ctx.doc)) && Boolean(q(ctx.doc, 'new-convo-project-token')), 'hydration');
    await click(ctx, q(ctx.doc, 'new-convo-project-token'));
    await click(ctx, q(ctx.doc, 'new-convo-new-project'));
    await until(ctx, () => Boolean(q(ctx.doc, 'new-convo-project-form')), 'modal open');
    assert.match(squash(q(ctx.doc, 'new-convo-project-form')!.textContent), /Folder on riverwood/);
    const folder = q(ctx.doc, 'new-convo-project-folder-input') as HTMLInputElement;
    const setter = Object.getOwnPropertyDescriptor(ctx.win.HTMLInputElement.prototype, 'value')!.set!;
    await ctx.act(() => { setter.call(folder, '/srv/newthing'); folder.dispatchEvent(new ctx.win.Event('input', { bubbles: true })); });
    await ctx.act(() => { folder.dispatchEvent(new ctx.win.KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true })); });
    await until(ctx, () => /Detected: Git/.test(squash(q(ctx.doc, 'new-convo-project-form')?.textContent)), 'detection');
    assert.ok(ctx.calls.some((c) => c.url.includes('/bridges/b_river/fs')), 'browses the headline bridge');
    await click(ctx, q(ctx.doc, 'new-convo-create-project-btn'));
    await until(ctx, () => !q(ctx.doc, 'new-convo-project-form'), 'modal closes');
    const post = ctx.calls.find((c) => c.method === 'POST' && c.url.endsWith('/projects'))!;
    assert.equal(post.body.default_path, '/srv/newthing');
    assert.equal(post.body.vcs_kind, 'git');
    await until(ctx, () => /newthing/.test(squash(q(ctx.doc, 'new-convo-project-token')?.textContent)), 'new project selected');
  });
});
