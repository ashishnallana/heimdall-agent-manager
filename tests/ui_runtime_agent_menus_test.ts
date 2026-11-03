// RuntimeMenu (provider + model) and AgentMenu (favorites list / edit) for the
// new-conversation launcher (spec §3.3, §3.7, motion §4 #8 #9 #10), the shared
// useRuntimeProviderModels hook, and the opt-in @ui extensions they use
// (IconButton `pressed`, Menu `mode="dialog"`, SentenceToken `appearance="chip"`).
// DOM nodes are compared with assert.ok(a === b): assert.equal on two jsdom nodes
// deep-inspects them on failure and can hang the run.
import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';

type Env = { width?: number; reducedMotion?: boolean };

async function withDom<T>(env: Env, fn: (doc: Document, win: any) => Promise<T>): Promise<T> {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', { url: 'http://localhost/' });
  const win = dom.window as any;
  Object.defineProperty(win, 'innerWidth', { value: env.width ?? 1280, configurable: true });
  win.matchMedia = (q: string) => ({
    matches: Boolean(env.reducedMotion && q.includes('prefers-reduced-motion')),
    media: q,
    addEventListener() {},
    removeEventListener() {},
    addListener() {},
    removeListener() {},
  });
  const keys = ['window', 'document', 'HTMLElement', 'Node', 'KeyboardEvent', 'MouseEvent', 'localStorage', 'fetch'] as const;
  const prev: Record<string, unknown> = {};
  for (const k of keys) prev[k] = (globalThis as any)[k];
  const prevNavigator = (globalThis as any).navigator;
  (globalThis as any).window = win;
  (globalThis as any).document = win.document;
  (globalThis as any).HTMLElement = win.HTMLElement;
  (globalThis as any).Node = win.Node;
  (globalThis as any).KeyboardEvent = win.KeyboardEvent;
  (globalThis as any).MouseEvent = win.MouseEvent;
  (globalThis as any).localStorage = win.localStorage;
  // ProviderIcon fetches its glyph; no network in tests (it falls back to the Icon glyph).
  (globalThis as any).fetch = async () => ({ ok: false });
  Object.defineProperty(globalThis, 'navigator', { value: win.navigator, configurable: true });
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  try {
    return await fn(win.document, win);
  } finally {
    dom.window.close();
    for (const k of keys) (globalThis as any)[k] = prev[k];
    Object.defineProperty(globalThis, 'navigator', { value: prevNavigator, configurable: true });
  }
}

async function mount(doc: Document, element: React.ReactElement) {
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { configureStore } = await import('@reduxjs/toolkit');
  const { Provider } = await import('react-redux');
  const { default: vault } = await import('../src/ui/store/vaultSlice.ts');
  const store = configureStore({ reducer: { vault } });
  const root = createRoot(doc.getElementById('root')!);
  const wrap = (el: React.ReactElement) => React.createElement(Provider, { store, children: el } as any);
  await act(async () => {
    root.render(wrap(element));
  });
  return {
    act,
    rerender: async (next: React.ReactElement) => act(async () => root.render(wrap(next))),
    unmount: async () => act(async () => root.unmount()),
  };
}

function key(win: any, target: Element, k: string) {
  target.dispatchEvent(new win.KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
}

function typeInto(win: any, el: HTMLInputElement | HTMLTextAreaElement, value: string) {
  const proto = el.tagName === 'TEXTAREA' ? win.HTMLTextAreaElement.prototype : win.HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, 'value')!.set!.call(el, value);
  el.dispatchEvent(new win.Event('input', { bubbles: true }));
}

const $ = (doc: Document, id: string) => doc.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;

// ---------------------------------------------------------------------------
// RuntimeMenu
// ---------------------------------------------------------------------------

const CAPS = [
  { provider: 'claude', label: 'Claude Code', profile_id: 'claude', models: ['default', 'opus', 'sonnet'] },
  { provider: 'codex', models: ['gpt-5', 'gpt-5-mini'] },
];

function RuntimeHarness(props: { RuntimeMenu: any; log: any[]; initial?: any; caps?: any[] }) {
  const [selection, setSelection] = React.useState(props.initial ?? { bridgeId: 'b1', provider: 'claude', providerProfile: 'claude', model: 'sonnet' });
  return React.createElement(props.RuntimeMenu, {
    capabilities: props.caps ?? CAPS,
    bridgeLabel: 'riverwood',
    selection,
    onChange: (next: any) => {
      props.log.push(next);
      setSelection(next);
    },
  });
}

async function loadRuntime() {
  return (await import('../src/ui/components/chat/launcher/RuntimeMenu.tsx')).RuntimeMenu;
}

test('RuntimeMenu: chip shows provider + model; menu is 560px with providers and "{Provider} model" columns', async () => {
  await withDom({}, async (doc) => {
    const RuntimeMenu = await loadRuntime();
    const log: any[] = [];
    const ui = await mount(doc, React.createElement(RuntimeHarness, { RuntimeMenu, log, initial: { bridgeId: 'b1', provider: 'gemini', model: 'g1' } }));
    const chip = $(doc, 'new-convo-runtime-picker')!;
    assert.equal(chip.getAttribute('aria-haspopup'), 'menu');
    assert.match(chip.textContent || '', /gemini/);
    await ui.act(async () => chip.click());
    const menu = $(doc, 'new-convo-runtime-picker-menu')!;
    assert.ok(menu, 'menu opens');
    assert.equal(menu.style.width, '560px');
    const groups = Array.from(menu.querySelectorAll('[role="group"]')).map(g => g.getAttribute('aria-label'));
    assert.deepEqual(groups, ['Provider', 'gemini model']);
    // Installed providers: "Signed in on {bridge}"; the current-but-missing one: "Not installed", disabled.
    const claude = $(doc, 'new-convo-provider-option-claude')!;
    assert.match(claude.textContent || '', /Claude Code.*Signed in on riverwood/);
    const gemini = $(doc, 'new-convo-provider-option-gemini')!;
    assert.match(gemini.textContent || '', /Not installed on riverwood/);
    assert.equal((gemini as HTMLButtonElement).disabled, true);
    assert.equal(gemini.getAttribute('aria-checked'), 'true');
    await ui.unmount();
  });
});

test('RuntimeMenu: provider pick keeps the menu open and swaps the model column; model pick closes', async () => {
  await withDom({}, async (doc, win) => {
    const RuntimeMenu = await loadRuntime();
    const log: any[] = [];
    const ui = await mount(doc, React.createElement(RuntimeHarness, { RuntimeMenu, log }));
    await ui.act(async () => $(doc, 'new-convo-runtime-picker')!.click());
    const columnBefore = $(doc, 'new-convo-model-column')!;
    assert.match(columnBefore.className, /animate-fade-slide/);
    assert.equal(columnBefore.getAttribute('aria-label'), 'Claude Code model');

    await ui.act(async () => $(doc, 'new-convo-provider-option-codex')!.click());
    assert.deepEqual(log.at(-1), { bridgeId: 'b1', provider: 'codex', providerProfile: 'codex', model: 'gpt-5' });
    const menu = $(doc, 'new-convo-runtime-picker-menu')!;
    assert.equal(menu.getAttribute('data-state'), 'open', 'provider pick keeps the menu open');
    const columnAfter = $(doc, 'new-convo-model-column')!;
    assert.ok(columnAfter !== columnBefore, 'model column remounts (fadeSlide replays)');
    assert.equal(columnAfter.getAttribute('aria-label'), 'codex model');
    assert.ok($(doc, 'new-convo-model-option-gpt-5-mini'));
    assert.equal($(doc, 'new-convo-model-option-sonnet'), null);

    await ui.act(async () => $(doc, 'new-convo-model-option-gpt-5-mini')!.click());
    assert.deepEqual(log.at(-1), { bridgeId: 'b1', provider: 'codex', providerProfile: 'codex', model: 'gpt-5-mini' });
    const closing = $(doc, 'new-convo-runtime-picker-menu');
    assert.ok(!closing || closing.getAttribute('data-state') === 'closing', 'model pick closes the menu');
    const chip = $(doc, 'new-convo-runtime-picker')!;
    assert.equal(chip.getAttribute('aria-expanded'), 'false');
    assert.ok(doc.activeElement === chip, 'focus returns to the chip');
    assert.match(chip.textContent || '', /codex.*gpt-5-mini/);
    void win;
    await ui.unmount();
  });
});

test('RuntimeMenu: per-provider model memory restores the last model when switching back', async () => {
  await withDom({}, async (doc) => {
    const RuntimeMenu = await loadRuntime();
    const log: any[] = [];
    const ui = await mount(doc, React.createElement(RuntimeHarness, { RuntimeMenu, log }));
    await ui.act(async () => $(doc, 'new-convo-runtime-picker')!.click());
    await ui.act(async () => $(doc, 'new-convo-model-option-opus')!.click());
    assert.equal(log.at(-1).model, 'opus');
    await ui.act(async () => $(doc, 'new-convo-runtime-picker')!.click());
    await ui.act(async () => $(doc, 'new-convo-provider-option-codex')!.click());
    await ui.act(async () => $(doc, 'new-convo-model-option-gpt-5-mini')!.click());
    await ui.act(async () => $(doc, 'new-convo-runtime-picker')!.click());
    await ui.act(async () => $(doc, 'new-convo-provider-option-claude')!.click());
    assert.equal(log.at(-1).provider, 'claude');
    assert.equal(log.at(-1).model, 'opus', 'claude restores opus');
    await ui.act(async () => $(doc, 'new-convo-provider-option-codex')!.click());
    assert.equal(log.at(-1).model, 'gpt-5-mini', 'codex restores gpt-5-mini');
    await ui.unmount();
  });
});

test('RuntimeMenu: Esc closes and returns focus; arrows move through provider and model rows', async () => {
  await withDom({}, async (doc, win) => {
    const RuntimeMenu = await loadRuntime();
    const ui = await mount(doc, React.createElement(RuntimeHarness, { RuntimeMenu, log: [] }));
    const chip = $(doc, 'new-convo-runtime-picker')!;
    await ui.act(async () => chip.click());
    // Initial focus: the first checked row (the selected provider).
    assert.ok(doc.activeElement === $(doc, 'new-convo-provider-option-claude'));
    await ui.act(async () => key(win, doc.activeElement!, 'ArrowDown'));
    assert.ok(doc.activeElement === $(doc, 'new-convo-provider-option-codex'));
    await ui.act(async () => key(win, doc.activeElement!, 'End'));
    assert.ok(doc.activeElement === $(doc, 'new-convo-model-option-sonnet'));
    await ui.act(async () => key(win, doc.activeElement!, 'Escape'));
    assert.equal(chip.getAttribute('aria-expanded'), 'false');
    assert.ok(doc.activeElement === chip);
    await ui.unmount();
  });
});

test('RuntimeMenu: reduced motion drops fadeSlide; mobile stacks the columns in a sheet and hides the chip model', async () => {
  await withDom({ reducedMotion: true }, async (doc) => {
    const RuntimeMenu = await loadRuntime();
    const ui = await mount(doc, React.createElement(RuntimeHarness, { RuntimeMenu, log: [] }));
    await ui.act(async () => $(doc, 'new-convo-runtime-picker')!.click());
    assert.doesNotMatch($(doc, 'new-convo-model-column')!.className, /animate-/);
    await ui.unmount();
  });
  await withDom({ width: 390 }, async (doc) => {
    const RuntimeMenu = await loadRuntime();
    const ui = await mount(doc, React.createElement(RuntimeHarness, { RuntimeMenu, log: [] }));
    const model = doc.querySelector('[data-runtime-chip-model]')!;
    assert.match(model.className, /\bhidden\b/);
    assert.match(model.className, /md:inline/);
    await ui.act(async () => $(doc, 'new-convo-runtime-picker')!.click());
    const columns = $(doc, 'new-convo-runtime-menu-columns')!;
    assert.match(columns.className, /flex-col/);
    assert.ok(columns.closest('[aria-modal="true"]'), 'rendered inside the bottom sheet');
    await ui.unmount();
  });
});

test('useRuntimeProviderModels: shared by RuntimeConfigurationOptions (re-exported type) with the same pick rules', async () => {
  await withDom({}, async (doc) => {
    const { useRuntimeProviderModels } = await import('../src/ui/components/chat/useRuntimeProviderModels.ts');
    const source = await import('node:fs').then(fs => fs.readFileSync(new URL('../src/ui/components/chat/RuntimeConfigurationOptions.tsx', import.meta.url), 'utf8'));
    assert.match(source, /useRuntimeProviderModels\(caps, selection, onChange\)/);
    assert.match(source, /export type \{ RuntimeSelection \}/);
    let api: any;
    const log: any[] = [];
    function Probe() {
      const [selection, setSelection] = React.useState<any>({ bridgeId: 'b1', provider: 'claude', providerProfile: 'claude', model: 'opus' });
      api = useRuntimeProviderModels(CAPS as any, selection, (next) => { log.push(next); setSelection(next); });
      return null;
    }
    const ui = await mount(doc, React.createElement(Probe));
    assert.deepEqual(api.providers, ['claude', 'codex']);
    assert.equal(api.labelFor('claude'), 'Claude Code');
    await ui.act(async () => api.chooseProvider('claude'));
    assert.equal(log.length, 0, 'choosing the selected provider is a no-op');
    await ui.act(async () => api.chooseProvider('codex'));
    assert.equal(log.at(-1).model, 'gpt-5');
    assert.equal(api.rowModel('claude'), 'opus');
    await ui.unmount();
  });
});

// ---------------------------------------------------------------------------
// AgentMenu
// ---------------------------------------------------------------------------

const AGENTS = [
  { agent_id: 'agt_coord', name: 'Coordinator', slug: 'coordinator', state: 'active' },
  { agent_id: 'agt_solo', name: 'Soloist', slug: 'soloist', state: 'active' },
  { agent_id: 'agt_worker', name: 'Worker', state: 'active' },
  { agent_id: 'agt_rev', name: 'Reviewer', state: 'active' },
  { agent_id: 'agt_a', name: 'Alpha', state: 'active' },
  { agent_id: 'agt_b', name: 'Beta', state: 'active' },
  { agent_id: 'agt_c', name: 'Gamma', state: 'active' },
  { agent_id: 'agt_old', name: 'Archived', state: 'archived' },
];

type AgentLog = { selected: string[]; toggles: Array<[string, boolean]>; created: any[]; openChanges?: boolean[] };

function AgentHarness(props: { AgentMenu: any; log: AgentLog; favorites?: string[]; selected?: string; failToggle?: boolean }) {
  const [favorites, setFavorites] = React.useState(props.favorites ?? ['agt_solo', 'agt_coord']);
  const [selected, setSelected] = React.useState(props.selected ?? 'agt_coord');
  return React.createElement(props.AgentMenu, {
    agents: AGENTS,
    favoriteIds: favorites,
    pinnedIds: ['agt_solo', 'agt_coord'],
    selectedId: selected,
    onSelect: (id: string) => { props.log.selected.push(id); setSelected(id); },
    onToggleFavorite: async (id: string, favorite: boolean) => {
      props.log.toggles.push([id, favorite]);
      if (props.failToggle) return false;
      setFavorites(f => favorite ? [...f, id] : f.filter(x => x !== id));
      return true;
    },
    templates: [{ template_id: 'tmpl_worker', name: 'Worker' }],
    onCreateAgent: async (agent: any) => { props.log.created.push(agent); return 'agt_new'; },
    onOpenChange: (open: boolean) => { props.log.openChanges?.push(open); },
  });
}

async function loadAgent() {
  return import('../src/ui/components/chat/launcher/AgentMenu.tsx');
}

const newLog = (): AgentLog => ({ selected: [], toggles: [], created: [], openChanges: [] });

test('AgentMenu list view: header with n / 6, favorites with workflow labels, separator, Edit favorites; pick selects and closes', async () => {
  await withDom({}, async (doc) => {
    const { AgentMenu } = await loadAgent();
    const log = newLog();
    const ui = await mount(doc, React.createElement(AgentHarness, { AgentMenu, log }));
    const chip = $(doc, 'new-convo-agent-picker')!;
    assert.match(chip.textContent || '', /Coordinator/);
    await ui.act(async () => chip.click());
    const menu = $(doc, 'new-convo-agent-picker-menu')!;
    assert.equal(menu.style.width, '360px');
    assert.ok(menu.querySelector('[role="menu"]') || menu.getAttribute('role') === 'menu');
    assert.match(menu.textContent || '', /Favorite agents\s*2 \/ 6/);
    const solo = $(doc, 'new-convo-favorite-agent-agt_solo')!;
    assert.match(solo.textContent || '', /Soloist.*Single-agent workflow/);
    assert.match($(doc, 'new-convo-favorite-agent-agt_coord')!.textContent || '', /Multi-agent workflow/);
    assert.equal($(doc, 'new-convo-favorite-agent-agt_coord')!.getAttribute('aria-checked'), 'true');
    assert.ok(menu.querySelector('[role="separator"]'));
    assert.ok($(doc, 'new-convo-edit-favorites'));
    await ui.act(async () => solo.click());
    assert.deepEqual(log.selected, ['agt_solo']);
    assert.equal(chip.getAttribute('aria-expanded'), 'false');
    await ui.unmount();
  });
});

test('AgentMenu edit view swaps in place: Done, search by name or id, pinned "Always on" stars disabled', async () => {
  await withDom({}, async (doc, win) => {
    const { AgentMenu } = await loadAgent();
    const log = newLog();
    const ui = await mount(doc, React.createElement(AgentHarness, { AgentMenu, log }));
    const chip = $(doc, 'new-convo-agent-picker')!;
    await ui.act(async () => chip.click());
    const popup = $(doc, 'new-convo-agent-picker-menu')!;
    await ui.act(async () => $(doc, 'new-convo-edit-favorites')!.click());
    assert.ok($(doc, 'new-convo-agent-picker-menu') === popup, 'same popover, no modal');
    assert.equal(popup.getAttribute('role'), 'dialog');
    assert.equal(chip.getAttribute('aria-haspopup'), 'dialog');
    assert.equal(doc.querySelector('[aria-modal="true"]'), null);
    assert.match(popup.textContent || '', /Edit favorites\s*2 \/ 6/);
    const search = $(doc, 'new-convo-agent-search') as HTMLInputElement;
    assert.equal(search.placeholder, 'Find an agent by name or ID');
    assert.ok(doc.activeElement === search, 'search is focused after the swap');

    // Pinned agents: "Always on" and a disabled, pressed (filled) star.
    const soloRow = $(doc, 'new-convo-favorite-row-agt_solo')!;
    assert.match(soloRow.textContent || '', /Soloist\s*agt_solo\s*Always on/);
    const soloStar = $(doc, 'new-convo-favorite-toggle-agt_solo') as HTMLButtonElement;
    assert.equal(soloStar.getAttribute('aria-pressed'), 'true');
    assert.equal(soloStar.disabled, true);
    assert.equal(soloStar.getAttribute('aria-label'), 'Soloist is always a favorite');
    const workerStar = $(doc, 'new-convo-favorite-toggle-agt_worker') as HTMLButtonElement;
    assert.equal(workerStar.getAttribute('aria-pressed'), 'false');
    assert.equal(workerStar.disabled, false);
    assert.equal($(doc, 'new-convo-favorite-row-agt_old'), null, 'non-active, non-favorite agents are hidden');

    await ui.act(async () => typeInto(win, search, 'agt_rev'));
    const rows = Array.from(doc.querySelectorAll('[data-debug-id^="new-convo-favorite-row-"]')).map(r => r.getAttribute('data-debug-id'));
    assert.deepEqual(rows, ['new-convo-favorite-row-agt_rev']);
    await ui.act(async () => typeInto(win, search, 'gam'));
    assert.ok($(doc, 'new-convo-favorite-row-agt_c'));
    await ui.act(async () => typeInto(win, search, 'nobody'));
    assert.match(popup.textContent || '', /No agent matches that name or ID\./);

    // Tab stays inside the dialog view (does not close it).
    await ui.act(async () => key(win, search, 'Tab'));
    assert.equal(chip.getAttribute('aria-expanded'), 'true');

    await ui.act(async () => $(doc, 'new-convo-edit-favorites-done')!.click());
    assert.ok($(doc, 'new-convo-agent-menu-list'));
    assert.ok(doc.activeElement === $(doc, 'new-convo-edit-favorites'), 'focus returns to Edit favorites');
    assert.equal(chip.getAttribute('aria-haspopup'), 'menu');
    await ui.unmount();
  });
});

test('AgentMenu: starring calls changeFavorite; at 6 favorites empty stars are disabled with the hint', async () => {
  await withDom({}, async (doc) => {
    const { AgentMenu, FAVORITES_FULL_HINT } = await loadAgent();
    const log = newLog();
    const ui = await mount(doc, React.createElement(AgentHarness, { AgentMenu, log, favorites: ['agt_solo', 'agt_coord', 'agt_worker', 'agt_rev', 'agt_a'] }));
    await ui.act(async () => $(doc, 'new-convo-agent-picker')!.click());
    await ui.act(async () => $(doc, 'new-convo-edit-favorites')!.click());
    assert.doesNotMatch($(doc, 'new-convo-favorite-limit')!.textContent || '', /most allowed/);
    const beta = $(doc, 'new-convo-favorite-toggle-agt_b') as HTMLButtonElement;
    assert.equal(beta.getAttribute('aria-label'), 'Add Beta to favorites');
    await ui.act(async () => beta.click());
    assert.deepEqual(log.toggles, [['agt_b', true]]);
    // The filled glyph pops as it turns on (motion #9).
    const betaNow = $(doc, 'new-convo-favorite-toggle-agt_b')!;
    assert.equal(betaNow.getAttribute('aria-pressed'), 'true');
    assert.match(betaNow.querySelector('svg')!.getAttribute('class') || '', /animate-pop/);
    assert.match($(doc, 'new-convo-agent-picker-menu')!.textContent || '', /6 \/ 6/);
    assert.equal($(doc, 'new-convo-favorite-limit')!.textContent, FAVORITES_FULL_HINT);
    assert.equal(FAVORITES_FULL_HINT, 'You have 6 favorites, the most allowed. Remove one to add another.');
    const gamma = $(doc, 'new-convo-favorite-toggle-agt_c') as HTMLButtonElement;
    assert.equal(gamma.disabled, true, 'adding is blocked at 6');
    assert.equal(($(doc, 'new-convo-favorite-toggle-agt_worker') as HTMLButtonElement).disabled, false, 'removing still works');
    assert.equal(($(doc, 'new-convo-create-favorite-agent-btn') as HTMLButtonElement | null), null, 'create form starts collapsed');
    await ui.unmount();
  });
});

test('AgentMenu: removing the selected agent selects the first remaining favorite; a failed toggle changes nothing', async () => {
  await withDom({}, async (doc) => {
    const { AgentMenu, firstRemainingFavorite } = await loadAgent();
    assert.equal(firstRemainingFavorite(['agt_solo', 'agt_coord', 'agt_rev'], 'agt_solo', AGENTS), 'agt_coord');
    assert.equal(firstRemainingFavorite(['agt_old', 'agt_rev'], 'agt_x', AGENTS), 'agt_rev', 'skips inactive agents');
    assert.equal(firstRemainingFavorite(['agt_rev'], 'agt_rev', AGENTS), '');

    const log = newLog();
    const ui = await mount(doc, React.createElement(AgentHarness, { AgentMenu, log, favorites: ['agt_solo', 'agt_coord', 'agt_rev'], selected: 'agt_rev' }));
    await ui.act(async () => $(doc, 'new-convo-agent-picker')!.click());
    await ui.act(async () => $(doc, 'new-convo-edit-favorites')!.click());
    await ui.act(async () => $(doc, 'new-convo-favorite-toggle-agt_rev')!.click());
    assert.deepEqual(log.toggles, [['agt_rev', false]]);
    assert.deepEqual(log.selected, ['agt_solo']);
    assert.match($(doc, 'new-convo-agent-picker')!.textContent || '', /Soloist/);
    await ui.unmount();

    const failLog = newLog();
    const ui2 = await mount(doc, React.createElement(AgentHarness, { AgentMenu, log: failLog, favorites: ['agt_solo', 'agt_coord', 'agt_rev'], selected: 'agt_rev', failToggle: true }));
    await ui2.act(async () => $(doc, 'new-convo-agent-picker')!.click());
    await ui2.act(async () => $(doc, 'new-convo-edit-favorites')!.click());
    await ui2.act(async () => $(doc, 'new-convo-favorite-toggle-agt_rev')!.click());
    assert.deepEqual(failLog.selected, []);
    await ui2.unmount();
  });
});

test('AgentMenu: the create-favorite-agent form lives in a collapsible section of the edit view and submits', async () => {
  await withDom({}, async (doc, win) => {
    const { AgentMenu } = await loadAgent();
    const log = newLog();
    const ui = await mount(doc, React.createElement(AgentHarness, { AgentMenu, log }));
    const chip = $(doc, 'new-convo-agent-picker')!;
    await ui.act(async () => chip.click());
    await ui.act(async () => $(doc, 'new-convo-edit-favorites')!.click());
    const toggle = $(doc, 'new-convo-create-agent-toggle')!;
    assert.equal(toggle.getAttribute('aria-expanded'), 'false');
    assert.match(toggle.textContent || '', /Create a favorite agent/);
    await ui.act(async () => toggle.click());
    assert.equal(toggle.getAttribute('aria-expanded'), 'true');
    const submit = $(doc, 'new-convo-create-favorite-agent-btn') as HTMLButtonElement;
    assert.equal(submit.disabled, true, 'needs a name');
    await ui.act(async () => typeInto(win, $(doc, 'new-convo-agent-name-input') as HTMLInputElement, '  Helper  '));
    await ui.act(async () => typeInto(win, $(doc, 'new-convo-agent-instructions-input') as HTMLTextAreaElement, 'Be brief'));
    assert.equal(submit.disabled, false);
    await ui.act(async () => submit.click());
    assert.deepEqual(log.created, [{ name: 'Helper', templateId: 'tmpl_worker', instructions: 'Be brief' }]);
    assert.equal(chip.getAttribute('aria-expanded'), 'false', 'closes after creating');
    assert.deepEqual(log.openChanges, [true, false], 'onOpenChange hears the close after creating');
    await ui.unmount();
  });
});

test('AgentMenu: reduced motion leaves animation classes off the swapped views and stars', async () => {
  await withDom({ reducedMotion: true }, async (doc) => {
    const { AgentMenu } = await loadAgent();
    const ui = await mount(doc, React.createElement(AgentHarness, { AgentMenu, log: newLog() }));
    await ui.act(async () => $(doc, 'new-convo-agent-picker')!.click());
    await ui.act(async () => $(doc, 'new-convo-edit-favorites')!.click());
    const body = $(doc, 'new-convo-agent-menu-edit')!;
    assert.doesNotMatch(body.innerHTML, /animate-fade-in/);
    await ui.unmount();
  });
});

// ---------------------------------------------------------------------------
// @ui back-compat
// ---------------------------------------------------------------------------

test('@ui back-compat: IconButton without pressed has no aria-pressed; Menu default mode is a menu that Tab closes', async () => {
  await withDom({}, async (doc, win) => {
    const { IconButton, Menu } = await import('../src/ui/components/ui/index.ts');
    const ui = await mount(doc, React.createElement('div', null,
      React.createElement(IconButton, { icon: 'star', label: 'Plain', 'data-debug-id': 'plain' } as any),
      React.createElement(Menu, { trigger: React.createElement('button', { type: 'button', 'data-debug-id': 'trig' }, 'Open'), label: 'Actions' } as any,
        React.createElement(Menu.Item, { 'data-debug-id': 'item' } as any, 'Do it')),
    ));
    const plain = $(doc, 'plain')!;
    assert.equal(plain.hasAttribute('aria-pressed'), false);
    assert.doesNotMatch(plain.className, /text-accent/);
    const trig = $(doc, 'trig')!;
    assert.equal(trig.getAttribute('aria-haspopup'), 'menu');
    await ui.act(async () => trig.click());
    assert.ok(doc.querySelector('[role="menu"]'));
    await ui.act(async () => key(win, $(doc, 'item')!, 'Tab'));
    assert.equal(trig.getAttribute('aria-expanded'), 'false');
    await ui.unmount();
  });
});
