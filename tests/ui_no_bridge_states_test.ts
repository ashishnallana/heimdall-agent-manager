// T8: the launcher's no-bridge states (spec §3.5 inline banner, §3.6 full screen).
// Trigger rule (user-confirmed): §3.6 on a cold start with zero online non-revoked
// bridges and not embedded; §3.5 when the chosen bridge drops while on the page.
// No bridge start command anywhere; the setup-wizard action is desktop-only and only
// for this host's bridge (or "Set up this machine" when none is installed).
//
// Components are imported inside the DOM (react-dom decides input-event support
// when it is first evaluated), the same harness as ui_new_conversation_page_test.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_no_bridge_states_test.ts
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
  setBridges: (rows: any[]) => void;
  pushBridges: (rows: any[]) => Promise<void>;
  store: any;
  settle: (ms?: number) => Promise<void>;
};

async function withPage(
  setup: { bridges?: any[]; prefs?: Record<string, unknown>; reducedMotion?: boolean; storage?: Record<string, string>; failPreferenceWrites?: boolean; desktopManager?: any },
  run: (ctx: Ctx) => Promise<void>,
) {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><main><div id="root"></div></main></body></html>', { url: 'http://localhost/' });
  const win = dom.window as any;
  Object.defineProperty(win, 'innerWidth', { value: 1280, configurable: true });
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

  let bridges = setup.bridges ?? [RIVER];
  if (setup.desktopManager) win.odinApi = { bridgeManager: setup.desktopManager };
  const prefs = { agent_id: 'agt_coord', project_id: 'p_ham', bridge_id: 'b_river', favorite_agent_ids: ['agt_coord', 'agt_solo'], pinned_agent_ids: ['agt_coord', 'agt_solo'], ...setup.prefs };
  const calls: Call[] = [];
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
    else if (path.endsWith('/projects')) data = { projects: PROJECTS };
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
      store,
      setBridges: (rows) => { bridges = rows; },
      // What a bridge resource event does: invalidate the list so it refetches.
      pushBridges: async (rows) => { bridges = rows; await act(async () => { store.dispatch(heimdallApi.util.invalidateTags([{ type: 'Bridges', id: 'LIST' }] as any)); }); },
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

const HOUR = 3600_000;
const seen = (msAgo: number) => new Date(Date.now() - msAgo).toISOString();
const DAWN_OFF = { bridge_id: 'b_dawn', label: 'dawnstar', machine_os: 'linux', status: 'offline', runtime_connected: false, last_seen_at: seen(26 * HOUR) };
const RIVER_OFF_SEEN = { ...RIVER_OFF, last_seen_at: seen(3 * HOUR) };
const REVOKED = { bridge_id: 'b_old', label: 'oldbox', machine_os: 'windows', status: 'revoked', runtime_connected: false };

/** A desktop bridge manager whose installed profile is `bridgeId` ('' = nothing installed). */
function fakeManager(bridgeId: string) {
  const hub = 'http://localhost';
  const profile = { installed: true, supported: true, hub, profile: '', bridge_id: bridgeId, state: 'stopped' };
  return {
    getConfig: async () => ({ ok: true, supported: true, hubUrl: hub }),
    setHubUrl: async () => ({ ok: true }),
    list: async () => ({ ok: true, profiles: bridgeId ? [profile] : [] }),
    getStatus: async () => ({ ...profile }),
    run: async () => ({ ok: true }),
    cancel: async () => ({ ok: true }),
    openLog: async () => ({ ok: true }),
    onEvent: () => () => {},
  };
}

const noCommand = (doc: Document) => {
  const text = squash(doc.body.textContent);
  assert.doesNotMatch(text, /heimdall-bridge|ham-bridge|bridge start|run this on that machine|\[bridge start command\]/i, 'no bridge start command is shown');
  assert.ok(!doc.querySelector('code'), 'no command box');
};

test('pure helpers: zero-online rule ignores revoked bridges; last-seen line picks the most recent', async () => {
  await withPage({ bridges: [] }, async () => {
    const m = await import('../src/ui/components/chat/launcher/NoBridgeOnline.tsx');
    const page = await import('../src/ui/components/chat/NewConversationPage.tsx');
    assert.equal(m.noBridgeOnline([]), true);
    assert.equal(m.noBridgeOnline([RIVER_OFF, REVOKED]), true);
    assert.equal(m.noBridgeOnline([RIVER_OFF, DAWN]), false);
    assert.equal(m.noBridgeOnline([{ ...RIVER, plan_disabled_at: '2026-01-01' }]), true, 'a plan-disabled bridge is not usable');
    assert.deepEqual(m.noBridgeRows([RIVER_OFF, REVOKED]).map((b: any) => b.bridge_id), ['b_river']);
    assert.equal(m.mostRecentlySeenLine([DAWN_OFF, RIVER_OFF_SEEN]), 'riverwood was last seen 3 h ago.');
    assert.equal(m.mostRecentlySeenLine([RIVER_OFF]), '');
    assert.equal(page.initialNoBridgeScreen([RIVER_OFF], false), 'full');
    assert.equal(page.initialNoBridgeScreen([RIVER_OFF], true), 'launcher', 'embedded never takes the full screen');
    assert.equal(page.initialNoBridgeScreen([RIVER], false), 'launcher');
    assert.equal(m.thisMachineSetupAction(null, ['b_river']), null, 'browser: no action');
    assert.deepEqual(m.thisMachineSetupAction({ phase: 'absent', bridgeId: '' }, ['b_river']), { kind: 'install' });
    assert.deepEqual(m.thisMachineSetupAction({ phase: 'present', bridgeId: 'b_river' }, ['b_river']), { kind: 'open', bridgeId: 'b_river' });
    assert.equal(m.thisMachineSetupAction({ phase: 'present', bridgeId: 'b_other' }, ['b_river']), null, 'not this host\'s bridge');
    assert.equal(m.thisMachineSetupAction({ phase: 'loading', bridgeId: '' }, ['b_river']), null);
    assert.equal(m.thisMachineSetupAction({ phase: 'error', bridgeId: '' }, ['b_river']), null);
  });
});

test('cold start with zero online bridges shows the full screen with copy, panel, actions and waiting line (browser: no setup action)', async () => {
  await withPage({ bridges: [RIVER_OFF_SEEN, DAWN_OFF, REVOKED] }, async (ctx) => {
    await ctx.render();
    await until(ctx, () => Boolean(q(ctx.doc, 'no-bridge-screen')), 'full screen');
    const screen = q(ctx.doc, 'no-bridge-screen')!;
    assert.ok(!q(ctx.doc, 'new-convo-headline'), 'the launcher is replaced');
    assert.ok(!q(ctx.doc, 'new-convo-composer-shell'));
    const h1 = screen.querySelector('h1')!;
    assert.equal(squash(h1.textContent), 'No bridge is online');
    assert.match(h1.className, /text-headline/);
    assert.match(squash(screen.textContent), /You can't start a conversation or a shell right now\. They run through a bridge on one of your machines, and none of yours is connected\. Start one and this page picks it up\./);
    assert.ok(screen.querySelector('[data-icon-well="lg"]')?.className.includes('bg-warning-soft'), 'warning-tint 56px well');
    assert.match(screen.className, /max-w-\[560px\]/);
    assert.match(screen.className, /animate-composer-swap/);
    const panel = q(ctx.doc, 'no-bridge-panel')!;
    assert.match(squash(panel.textContent), /^Your bridges/);
    assert.equal(squash(q(ctx.doc, 'no-bridge-online-count')!.textContent), '0 of 2 online', 'revoked bridges are not counted');
    assert.ok(!q(ctx.doc, 'no-bridge-row-b_old'));
    assert.equal(squash(q(ctx.doc, 'no-bridge-row-b_river')!.textContent), 'riverwoodLinux · last seen 3 h agoOffline');
    assert.equal(squash(q(ctx.doc, 'no-bridge-row-b_dawn')!.textContent), 'dawnstarLinux · last seen 26 h agoOffline');
    assert.ok(q(ctx.doc, 'no-bridge-row-b_river')!.querySelector('[data-bridge-status="offline"]'), 'Offline pill');
    const check = q(ctx.doc, 'no-bridge-check-again')!;
    assert.equal(check.tagName, 'BUTTON');
    assert.match(check.className, /bg-accent/, 'Check again is primary');
    const download = q(ctx.doc, 'no-bridge-download') as HTMLAnchorElement;
    assert.equal(download.tagName, 'A');
    assert.equal(download.getAttribute('href'), 'https://www.ninjy.ai/download');
    assert.equal(download.getAttribute('target'), '_blank');
    assert.equal(download.getAttribute('rel'), 'noopener');
    assert.match(squash(download.textContent), /Download the bridge/);
    assert.match(squash(screen.textContent), /New machine\? Get the bridge at ninjy\.ai\/download, install it, and sign in\./);
    const waiting = q(ctx.doc, 'no-bridge-waiting')!;
    assert.equal(waiting.getAttribute('role'), 'status');
    assert.equal(squash(waiting.textContent), 'Waiting for a bridge to connect');
    assert.ok(waiting.querySelector('.animate-breathe'), 'breathing dot (#16)');
    assert.ok(!q(ctx.doc, 'no-bridge-setup-wizard'), 'browser: no setup action');
    noCommand(ctx.doc);
  });
});

test('Check again refetches the bridge list', async () => {
  await withPage({ bridges: [RIVER_OFF] }, async (ctx) => {
    await ctx.render();
    await until(ctx, () => Boolean(q(ctx.doc, 'no-bridge-check-again')), 'check again');
    const before = ctx.calls.filter(c => c.method === 'GET' && new URL(c.url, 'http://localhost').pathname.endsWith('/bridges')).length;
    await click(ctx, q(ctx.doc, 'no-bridge-check-again'));
    await until(ctx, () => ctx.calls.filter(c => c.method === 'GET' && new URL(c.url, 'http://localhost').pathname.endsWith('/bridges')).length > before, 'bridges refetched');
  });
});

test('a bridge coming online cross-fades back to the launcher and selects it', async () => {
  await withPage({ bridges: [RIVER_OFF], prefs: { bridge_id: '' } }, async (ctx) => {
    await ctx.render();
    await until(ctx, () => Boolean(q(ctx.doc, 'no-bridge-screen')), 'full screen');
    await ctx.pushBridges([RIVER]);
    await until(ctx, () => /animate-fade-out/.test(q(ctx.doc, 'no-bridge-screen')?.className || ''), 'empty state fades out (#19)');
    await until(ctx, () => Boolean(q(ctx.doc, 'new-convo-headline')), 'launcher back');
    assert.ok(!q(ctx.doc, 'no-bridge-screen'));
    assert.ok(!q(ctx.doc, 'no-bridge-banner'));
    const column = q(ctx.doc, 'new-convo-headline')!.closest('section')!.firstElementChild as HTMLElement;
    assert.match(column.className, /animate-composer-swap/, 'launcher swaps in (#19)');
    assert.equal(q(ctx.doc, 'new-convo-composer-shell')!.getAttribute('aria-disabled'), null);
    await until(ctx, () => ctx.calls.some(c => c.method === 'PATCH' && c.url.includes('/me/conversation-launch') && c.body?.bridge_id === 'b_river'), 'the online bridge is chosen');
    await until(ctx, () => !/No bridge is online/.test(squash(q(ctx.doc, 'new-convo-launch-issues')?.textContent)), 'bridge issue clears');
  });
});

test('embedded cold start with zero online shows the banner, not the full screen', async () => {
  await withPage({ bridges: [RIVER_OFF_SEEN] }, async (ctx) => {
    await ctx.render({ embedded: true });
    await until(ctx, () => Boolean(q(ctx.doc, 'no-bridge-banner')), 'banner');
    assert.ok(!q(ctx.doc, 'no-bridge-screen'));
  });
});

test('the chosen bridge dropping mid-session shows the banner, disables the composer and keeps the typed text', async () => {
  await withPage({ bridges: [RIVER_OFF_SEEN], storage: {} }, async (ctx) => {
    ctx.setBridges([{ ...RIVER, last_seen_at: seen(0) }]);
    await ctx.render();
    await until(ctx, () => Boolean(q(ctx.doc, 'new-convo-composer-input')), 'launcher');
    await type(ctx, q(ctx.doc, 'new-convo-composer-input'), 'keep me');
    await ctx.pushBridges([RIVER_OFF_SEEN]);
    await until(ctx, () => Boolean(q(ctx.doc, 'no-bridge-banner')), 'banner');
    assert.ok(!q(ctx.doc, 'no-bridge-screen'), 'not the full screen mid-session');
    const banner = q(ctx.doc, 'no-bridge-banner')!;
    assert.match(banner.className, /animate-composer-swap/, '#15');
    assert.equal(banner.firstElementChild!.getAttribute('role'), 'status');
    assert.match(banner.firstElementChild!.className, /bg-warning-soft/);
    assert.equal(squash(banner.textContent), 'No machine is onlineConversations and shells run through a bridge on one of your machines. Start one and it shows up here.riverwood was last seen 3 h ago.Check againDownload the bridge');
    assert.ok(banner.querySelector('[data-debug-id="no-bridge-check-again"]'));
    const download = banner.querySelector('[data-debug-id="no-bridge-download"]') as HTMLAnchorElement;
    assert.equal(download.getAttribute('href'), 'https://www.ninjy.ai/download');
    assert.equal(download.getAttribute('target'), '_blank');
    assert.equal(download.getAttribute('rel'), 'noopener');
    const composer = q(ctx.doc, 'new-convo-composer-shell')!;
    assert.equal(composer.getAttribute('aria-disabled'), 'true');
    assert.match(composer.className, /opacity-\[\.45\]/);
    assert.match(composer.className, /pointer-events-none/);
    assert.equal((q(ctx.doc, 'new-convo-composer-input') as HTMLTextAreaElement).value, 'keep me', 'typed text is kept');
    assert.ok(!/ on /.test(squash(q(ctx.doc, 'new-convo-headline')!.textContent)) || !q(ctx.doc, 'new-convo-machine-token'), 'bridge clause hidden');
    assert.ok(!q(ctx.doc, 'new-convo-machine-token'));
    assert.ok(!q(ctx.doc, 'no-bridge-setup-wizard'), 'browser: no setup action');
    noCommand(ctx.doc);
    // Recovery: the banner leaves and the composer is usable again with the text intact.
    await ctx.pushBridges([RIVER]);
    await until(ctx, () => !q(ctx.doc, 'no-bridge-banner'), 'banner gone');
    assert.equal(q(ctx.doc, 'new-convo-composer-shell')!.getAttribute('aria-disabled'), null);
    assert.equal((q(ctx.doc, 'new-convo-composer-input') as HTMLTextAreaElement).value, 'keep me');
  });
});

test('desktop app: "Open setup wizard" only on this host\'s offline bridge row, and it navigates to /setup', async () => {
  await withPage({ bridges: [RIVER_OFF_SEEN, DAWN_OFF], desktopManager: fakeManager('b_river') }, async (ctx) => {
    await ctx.render();
    await until(ctx, () => Boolean(q(ctx.doc, 'no-bridge-setup-wizard')), 'setup action');
    const actions = ctx.doc.querySelectorAll('[data-debug-id="no-bridge-setup-wizard"]');
    assert.equal(actions.length, 1);
    const action = actions[0] as HTMLElement;
    assert.ok(q(ctx.doc, 'no-bridge-row-b_river')!.contains(action), 'on this host\'s row');
    assert.ok(!q(ctx.doc, 'no-bridge-row-b_dawn')!.contains(action));
    assert.equal(squash(action.textContent), 'Open setup wizard');
    noCommand(ctx.doc);
    await click(ctx, action);
    assert.equal(ctx.win.location.hash, '#/setup');
  });
});

test('desktop app with no bridge installed here offers "Set up this machine"; another host\'s bridge gets nothing', async () => {
  await withPage({ bridges: [DAWN_OFF], desktopManager: fakeManager('') }, async (ctx) => {
    await ctx.render();
    await until(ctx, () => Boolean(q(ctx.doc, 'no-bridge-setup-wizard')), 'setup action');
    const action = q(ctx.doc, 'no-bridge-setup-wizard')!;
    assert.equal(squash(action.textContent), 'Set up this machine');
    assert.ok(!q(ctx.doc, 'no-bridge-row-b_dawn')!.contains(action), 'in the panel, not on another host\'s row');
    await click(ctx, action);
    assert.equal(ctx.win.location.hash, '#/setup');
  });
  await withPage({ bridges: [DAWN_OFF], desktopManager: fakeManager('b_elsewhere') }, async (ctx) => {
    await ctx.render();
    await until(ctx, () => Boolean(q(ctx.doc, 'no-bridge-screen')), 'full screen');
    // A profile installed here for another account is not this account's bridge:
    // the account has nothing on this machine, so it is the install action, never
    // "Open setup wizard" on another host's row.
    await until(ctx, () => Boolean(q(ctx.doc, 'no-bridge-setup-wizard')), 'setup action');
    assert.equal(q(ctx.doc, 'no-bridge-setup-wizard')!.getAttribute('data-setup-kind'), 'install');
    assert.ok(!q(ctx.doc, 'no-bridge-row-b_dawn')!.querySelector('[data-debug-id="no-bridge-setup-wizard"]'));
  });
});

test('desktop banner shows the setup action for this host\'s dropped bridge', async () => {
  await withPage({ bridges: [RIVER], desktopManager: fakeManager('b_river') }, async (ctx) => {
    await ctx.render();
    await until(ctx, () => Boolean(q(ctx.doc, 'new-convo-composer-input')), 'launcher');
    await ctx.pushBridges([RIVER_OFF_SEEN]);
    await until(ctx, () => Boolean(q(ctx.doc, 'no-bridge-banner')?.querySelector('[data-debug-id="no-bridge-setup-wizard"]')), 'banner setup action');
    noCommand(ctx.doc);
  });
});

test('reduced motion: the motion utilities are guarded and the launcher returns without waiting', async () => {
  const fs = await import('node:fs');
  const css = fs.readFileSync(new URL('../src/ui/styles.css', import.meta.url), 'utf8');
  const guard = css.slice(css.indexOf('Conversation launcher motion'));
  for (const cls of ['.animate-composer-swap', '.animate-fade-out']) assert.ok(guard.includes(cls), `${cls} is in the reduced-motion guard`);
  assert.match(guard, /\.animate-breathe\s*\{\s*animation:\s*none !important;/);
  await withPage({ bridges: [RIVER_OFF], reducedMotion: true, prefs: { bridge_id: '' } }, async (ctx) => {
    await ctx.render();
    await until(ctx, () => Boolean(q(ctx.doc, 'no-bridge-screen')), 'full screen');
    await ctx.pushBridges([RIVER]);
    await until(ctx, () => Boolean(q(ctx.doc, 'new-convo-headline')), 'launcher back', 1000);
  });
});
