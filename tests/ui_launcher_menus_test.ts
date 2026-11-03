// Launcher headline menus (new-conversation redesign spec §3.1/§3.3): ModeMenu,
// ProjectMenu, BridgeMenu on SentenceToken, plus the @ui IconWell primitive.
// DOM nodes are compared with assert.ok(a === b): assert.equal on two jsdom nodes
// deep-inspects them on failure and can hang the run.
import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';

async function withDom<T>(fn: (doc: Document, win: any) => Promise<T>, width = 1280): Promise<T> {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', { url: 'http://localhost/' });
  const win = dom.window as any;
  Object.defineProperty(win, 'innerWidth', { value: width, configurable: true });
  win.matchMedia = (q: string) => ({ matches: false, media: q, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
  const keys = ['window', 'document', 'HTMLElement', 'Node', 'KeyboardEvent', 'MouseEvent', 'localStorage'] as const;
  const prev: Record<string, unknown> = {};
  for (const k of keys) prev[k] = (globalThis as any)[k];
  const prevNavigator = (globalThis as any).navigator;
  for (const k of keys) (globalThis as any)[k] = k === 'window' ? win : k === 'document' ? win.document : win[k];
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
  const root = createRoot(doc.getElementById('root')!);
  await act(async () => root.render(element));
  return { act, rerender: (next: React.ReactElement) => act(async () => root.render(next)), unmount: () => act(async () => root.unmount()) };
}

const q = (doc: Document, id: string) => doc.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
const rowTitles = (doc: Document) => Array.from(doc.querySelectorAll('[role="menuitemradio"] .font-medium')).map((n) => n.textContent);
const tokenText = (doc: Document, id: string) => q(doc, id)!.querySelector('[data-token-value]')!.textContent;

async function type(win: any, ui: { act: any }, input: HTMLInputElement, text: string) {
  const setter = Object.getOwnPropertyDescriptor(win.HTMLInputElement.prototype, 'value')!.set!;
  await ui.act(async () => {
    setter.call(input, text);
    input.dispatchEvent(new win.Event('input', { bubbles: true }));
  });
}

const PROJECTS = [
  { project_id: 'p_alpha', name: 'Alpha', state: 'active', default_path: '/src/alpha' },
  { project_id: 'p_conv', name: 'Conversation', slug: 'conversation', state: 'active' },
  { project_id: 'p_old', name: 'Old', state: 'archived', default_path: '/src/old' },
  { project_id: 'p_beta', name: 'Beta', state: 'active', default_path: '/home/me/beta-repo' },
];

const ONLINE = { status: 'online', runtime_connected: true, reconfiguration_supported: true };
const BRIDGES = [
  { bridge_id: 'b_river', label: 'riverwood', machine_os: 'linux', ...ONLINE },
  { bridge_id: 'b_mac', label: 'mac', machine_os: 'darwin', status: 'offline', last_seen_at: new Date(Date.now() - 3 * 3600_000).toISOString() },
  { bridge_id: 'b_gone', label: 'gone', machine_os: 'linux', status: 'revoked' },
  { bridge_id: 'b_arch', label: 'archived', status: 'online', runtime_connected: true, revoked_at: '2026-01-01T00:00:00Z' },
  { bridge_id: 'b_plan', label: 'plan', machine_os: 'windows', ...ONLINE, plan_disabled_at: '2026-01-01T00:00:00Z' },
  { bridge_id: 'b_dawn', label: 'dawnstar', machine_os: 'linux', ...ONLINE, reconfiguration_supported: false },
];

test('projectMenuOptions: "No project" first (default by flag or slug), archived excluded, path in mono', async () => {
  // Inside a DOM: react-dom decides input-event support when first evaluated.
  await withDom(async () => {
    const { projectMenuOptions, isDefaultConversationProject } = await import('../src/ui/components/chat/launcher/ProjectMenu.tsx');
    const rows = projectMenuOptions(PROJECTS);
    assert.deepEqual(rows.map((r) => r.value), ['p_conv', 'p_alpha', 'p_beta']);
    assert.equal(rows[0].label, 'No project');
    assert.equal(rows[0].tokenLabel, 'without a project');
    assert.equal(rows[0].description, 'A plain conversation, not tied to a repo');
    assert.equal(rows[1].description, '/src/alpha');
    assert.equal(rows[1].descriptionMono, true);
    assert.ok(isDefaultConversationProject({ project_id: 'x', is_default_conversations: true }));
    assert.ok(!isDefaultConversationProject({ project_id: 'x', slug: 'other' }));
    // The flag wins wherever the project sits in the list.
    const flagged = projectMenuOptions([PROJECTS[0], { project_id: 'p_home', name: 'Home', state: 'active', is_default_conversations: true }]);
    assert.deepEqual(flagged.map((r) => r.label), ['No project', 'Alpha']);
    // Locked (vault-armored) names never leak ciphertext.
    const { VAULT_ARMOR_PREFIX } = await import('../src/ui/utils/vaultCrypto.ts');
    assert.equal(projectMenuOptions([{ ...PROJECTS[0], name: `${VAULT_ARMOR_PREFIX}abc` }])[0].label, 'Locked name');
  });
});

test('ProjectMenu: token reads "without a project", search filters by name and path, empty text, pick and New project', async () => {
  await withDom(async (doc, win) => {
    const { ProjectMenu } = await import('../src/ui/components/chat/launcher/ProjectMenu.tsx');
    const picks: string[] = [];
    let newProject = 0;
    function Harness() {
      const [value, setValue] = React.useState('p_conv');
      return React.createElement(ProjectMenu, { projects: PROJECTS, value, onChange: (id: string) => { picks.push(id); setValue(id); }, onNewProject: () => { newProject += 1; } });
    }
    const ui = await mount(doc, React.createElement(Harness));
    assert.equal(tokenText(doc, 'new-convo-project-token'), 'without a project');
    assert.ok(!q(doc, 'new-convo-project-token')!.textContent!.includes('Conversation'));

    await ui.act(async () => q(doc, 'new-convo-project-token')!.click());
    assert.equal(q(doc, 'new-convo-project-token-menu')!.style.width, '380px');
    const input = q(doc, 'new-convo-project-search') as HTMLInputElement;
    assert.ok(doc.activeElement === input, 'search focused on open');
    assert.equal(input.placeholder, 'Find a project');
    assert.deepEqual(rowTitles(doc), ['No project', 'Alpha', 'Beta']);
    assert.ok(!rowTitles(doc).includes('Conversation'));
    assert.equal(doc.querySelector('[role="menuitemradio"][aria-checked="true"] .font-medium')!.textContent, 'No project');
    assert.equal(q(doc, 'new-convo-project-option-p_beta')!.querySelector('.font-mono')!.textContent, '/home/me/beta-repo');

    await type(win, ui, input, 'bet');
    assert.deepEqual(rowTitles(doc), ['Beta']);
    await type(win, ui, input, 'beta-repo');
    assert.deepEqual(rowTitles(doc), ['Beta'], 'matches default_path');
    await type(win, ui, input, 'zzz');
    assert.deepEqual(rowTitles(doc), []);
    assert.ok(doc.body.textContent!.includes('No project matches that name.'));
    assert.ok(q(doc, 'new-convo-new-project'), 'footer stays while filtering');

    await type(win, ui, input, '');
    await ui.act(async () => q(doc, 'new-convo-project-option-p_alpha')!.click());
    assert.deepEqual(picks, ['p_alpha']);
    assert.equal(q(doc, 'new-convo-project-token')!.getAttribute('aria-expanded'), 'false');
    assert.equal(tokenText(doc, 'new-convo-project-token'), 'Alpha');

    await ui.act(async () => q(doc, 'new-convo-project-token')!.click());
    const footer = q(doc, 'new-convo-new-project')!;
    assert.equal(footer.getAttribute('role'), 'menuitem');
    assert.equal(footer.textContent, 'New project');
    await ui.act(async () => footer.click());
    assert.equal(newProject, 1);
    assert.equal(q(doc, 'new-convo-project-token')!.getAttribute('aria-expanded'), 'false');
    await ui.unmount();
  });
});

test('ProjectMenu: New project row hidden without a handler and disabled on request', async () => {
  await withDom(async (doc) => {
    const { ProjectMenu } = await import('../src/ui/components/chat/launcher/ProjectMenu.tsx');
    const ui = await mount(doc, React.createElement(ProjectMenu, { projects: PROJECTS, value: 'p_alpha', onChange() {} }));
    await ui.act(async () => q(doc, 'new-convo-project-token')!.click());
    assert.equal(q(doc, 'new-convo-new-project'), null);
    await ui.act(async () => q(doc, 'new-convo-project-token')!.click());
    await ui.rerender(React.createElement(ProjectMenu, { projects: PROJECTS, value: 'p_alpha', onChange() {}, onNewProject() {}, newProjectDisabled: true }));
    await ui.act(async () => q(doc, 'new-convo-project-token')!.click());
    assert.equal((q(doc, 'new-convo-new-project') as HTMLButtonElement).disabled, true);
    await ui.unmount();
  });
});

test('bridgeMenuOptions: revoked/archived excluded, unusable disabled, status words', async () => {
  // Inside a DOM: react-dom decides input-event support when first evaluated.
  await withDom(async () => {
    const { bridgeMenuOptions, bridgeOsLabel, bridgeStatusWord } = await import('../src/ui/components/chat/launcher/BridgeMenu.tsx');
    const { COMPOSER_BRIDGE_STATUS_LABEL } = await import('../src/ui/utils/composerBridgeOptions.ts');
    const rows = bridgeMenuOptions(BRIDGES, { requireReconfiguration: true });
    assert.deepEqual(rows.map((r) => r.value), ['b_river', 'b_mac', 'b_plan', 'b_dawn']);
    assert.deepEqual(rows.map((r) => !!r.disabled), [false, true, true, true]);
    assert.equal(rows[0].description, 'Linux');
    assert.equal(rows[1].description, 'macOS · last seen 3 h ago');
    assert.equal(bridgeOsLabel({ os: 'windows' }), 'Windows');
    assert.equal(bridgeOsLabel({}), '');
    assert.equal(bridgeStatusWord(null), 'Online');
    assert.equal(bridgeStatusWord('offline'), 'Offline');
    assert.equal(bridgeStatusWord('update_required'), COMPOSER_BRIDGE_STATUS_LABEL.update_required);
    assert.equal(bridgeStatusWord('plan_limit'), COMPOSER_BRIDGE_STATUS_LABEL.plan_limit);
    // Without the reconfiguration requirement an old bridge is usable.
    assert.equal(bridgeMenuOptions(BRIDGES).find((r) => r.value === 'b_dawn')!.disabled, false);
  });
});

test('BridgeMenu: label, pills, disabled rows and pick feeds chooseRuntime({ ...runtime, bridgeId })', async () => {
  await withDom(async (doc) => {
    const { BridgeMenu } = await import('../src/ui/components/chat/launcher/BridgeMenu.tsx');
    const runtime = { bridgeId: 'b_river', provider: 'claude', providerProfile: 'claude-work', model: 'opus' };
    const calls: any[] = [];
    const ui = await mount(doc, React.createElement(BridgeMenu, { bridges: [...BRIDGES, { bridge_id: 'b_dawn2', label: 'dawn2', machine_os: 'linux', ...ONLINE }], runtime, onChange: (next: any) => calls.push(next), requireReconfiguration: true }));
    const token = q(doc, 'new-convo-machine-token')!;
    assert.equal(tokenText(doc, 'new-convo-machine-token'), 'riverwood');
    assert.equal(token.querySelector('[role="img"]')!.getAttribute('aria-label'), 'Online');

    await ui.act(async () => token.click());
    const menu = q(doc, 'new-convo-machine-token-menu')!;
    assert.equal(menu.style.width, '360px');
    assert.ok(menu.textContent!.startsWith('Bridges'));
    assert.deepEqual(rowTitles(doc), ['riverwood', 'mac', 'plan', 'dawnstar', 'dawn2']);
    assert.ok(!rowTitles(doc).includes('gone') && !rowTitles(doc).includes('archived'));

    const status = (id: string) => q(doc, `new-convo-machine-option-${id}`)!.querySelector('[data-bridge-status]')!.textContent;
    assert.equal(status('b_river'), 'Online');
    assert.equal(status('b_mac'), 'Offline');
    assert.equal(status('b_dawn'), 'Update required');
    assert.ok(status('b_plan')!.startsWith('Disabled'));

    for (const id of ['b_mac', 'b_plan', 'b_dawn']) {
      const row = q(doc, `new-convo-machine-option-${id}`) as HTMLButtonElement;
      assert.equal(row.disabled, true, id);
      assert.equal(row.getAttribute('aria-disabled'), 'true');
      assert.ok(row.className.includes('disabled:opacity-[.45]'));
    }
    (q(doc, 'new-convo-machine-option-b_mac') as HTMLButtonElement).click();
    assert.equal(calls.length, 0, 'a disabled row does nothing');

    await ui.act(async () => q(doc, 'new-convo-machine-option-b_dawn2')!.click());
    assert.deepEqual(calls, [{ ...runtime, bridgeId: 'b_dawn2' }]);
    await ui.unmount();
  });
});

test('BridgeMenu: an unknown or offline chosen bridge shows a neutral dot', async () => {
  await withDom(async (doc) => {
    const { BridgeMenu } = await import('../src/ui/components/chat/launcher/BridgeMenu.tsx');
    const ui = await mount(doc, React.createElement(BridgeMenu, { bridges: BRIDGES, runtime: { bridgeId: 'b_mac', provider: '', model: '' }, onChange() {} }));
    assert.equal(q(doc, 'new-convo-machine-token')!.querySelector('[role="img"]')!.getAttribute('aria-label'), 'Offline');
    await ui.rerender(React.createElement(BridgeMenu, { bridges: BRIDGES, runtime: { bridgeId: 'b_gone', provider: '', model: '' }, onChange() {} }));
    assert.equal(tokenText(doc, 'new-convo-machine-token'), 'a bridge');
    await ui.unmount();
  });
});

test('ModeMenu: 300px, Conversation/Shell rows with chat/terminal wells, pick calls the setter', async () => {
  await withDom(async (doc) => {
    const { ModeMenu } = await import('../src/ui/components/chat/launcher/ModeMenu.tsx');
    const picks: string[] = [];
    function Harness() {
      const [mode, setMode] = React.useState<'agent' | 'shell'>('agent');
      return React.createElement(ModeMenu, { value: mode, onChange: (m: 'agent' | 'shell') => { picks.push(m); setMode(m); } });
    }
    const ui = await mount(doc, React.createElement(Harness));
    assert.equal(tokenText(doc, 'new-convo-mode-token'), 'conversation');
    await ui.act(async () => q(doc, 'new-convo-mode-token')!.click());
    assert.equal(q(doc, 'new-convo-mode-token-menu')!.style.width, '300px');
    assert.deepEqual(rowTitles(doc), ['Conversation', 'Shell']);
    const agent = q(doc, 'new-convo-mode-option-agent')!;
    const shell = q(doc, 'new-convo-mode-option-shell')!;
    assert.ok(agent.textContent!.includes('Chat with an agent that works in the project'));
    assert.ok(shell.textContent!.includes('A terminal in the project folder'));
    assert.equal(agent.querySelector('[data-icon-well]')!.getAttribute('data-icon-well'), 'md');
    assert.ok(shell.querySelector('[data-icon-well]'));
    assert.equal(agent.getAttribute('aria-checked'), 'true');
    await ui.act(async () => shell.click());
    assert.deepEqual(picks, ['shell']);
    assert.equal(tokenText(doc, 'new-convo-mode-token'), 'shell');
    await ui.unmount();
  });
});

test('IconWell: decorative, sized and toned from tokens', async () => {
  await withDom(async (doc) => {
    const { IconWell } = await import('../src/ui/components/ui/primitives/IconWell.tsx');
    const ui = await mount(doc, React.createElement('div', null, React.createElement(IconWell, { icon: 'chat' }), React.createElement(IconWell, { icon: 'alert', size: 'lg', tone: 'warning' })));
    const [md, lg] = Array.from(doc.querySelectorAll('[data-icon-well]')) as HTMLElement[];
    assert.equal(md.getAttribute('aria-hidden'), 'true');
    assert.ok(md.className.includes('h-8 w-8') && md.className.includes('bg-neutral-soft'));
    assert.ok(lg.className.includes('h-14 w-14') && lg.className.includes('bg-warning-soft') && lg.className.includes('text-warning'));
    assert.ok(md.querySelector('svg'));
    await ui.unmount();
  });
});
