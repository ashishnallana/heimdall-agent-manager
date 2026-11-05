// LaunchHeadline (new-conversation redesign spec §3.1): template table, the
// "without a project" mapping, the `on [bridge]` clause rule and the meta line.
// Every test that imports a component runs inside withDom (react-dom decides
// input-event support when first evaluated). DOM nodes are compared with
// assert.ok(a === b), never assert.equal (that can hang on failure).
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
const squash = (text: string | null | undefined) => String(text ?? '').replace(/\s+/g, ' ').trim();
const headlineText = (doc: Document) => squash(q(doc, 'new-convo-headline')!.textContent);

const PROJECTS = [
  { project_id: 'p_conv', name: 'Conversation', slug: 'conversation', state: 'active' },
  { project_id: 'p_ham', name: 'heimdall-agent-manager', state: 'active', default_path: '/var/home/tanmay/heimdall-agent-manager' },
  { project_id: 'p_nopath', name: 'Scratch', state: 'active' },
  { project_id: 'p_flag', name: 'Inbox', is_default_conversations: true, state: 'active' },
];
const ONLINE = { status: 'online', runtime_connected: true, reconfiguration_supported: true };
const RIVER = { bridge_id: 'b_river', label: 'riverwood', machine_os: 'linux', ...ONLINE };
const MAC_OFF = { bridge_id: 'b_mac', label: 'mac', machine_os: 'darwin', status: 'offline' };
const DAWN = { bridge_id: 'b_dawn', label: 'dawnstar', machine_os: 'linux', ...ONLINE };
const REVOKED = { bridge_id: 'b_gone', label: 'gone', status: 'revoked' };
const ARCHIVED = { bridge_id: 'b_arch', label: 'archived', ...ONLINE, revoked_at: '2026-01-01T00:00:00Z' };

async function load() {
  return import('../src/ui/components/chat/launcher/LaunchHeadline.tsx');
}

function props(overrides: Record<string, unknown> = {}) {
  return {
    mode: 'agent' as const,
    onModeChange: () => {},
    projects: PROJECTS,
    projectId: 'p_ham',
    onProjectChange: () => {},
    bridges: [RIVER, DAWN],
    runtime: { bridgeId: 'b_river', provider: 'claude', model: '' },
    onRuntimeChange: () => {},
    ...overrides,
  };
}

test('pure helpers: template pick, segments per template, bridge clause rule, meta', async () => {
  await withDom(async () => {
    const { pickHeadlineTemplate, headlineSegments, shouldShowBridgeClause, headlineMeta, HEADLINE_TEMPLATE_IDS } = await load();
    assert.deepEqual([...HEADLINE_TEMPLATE_IDS], ['spin', 'going', 'start']);
    assert.equal(pickHeadlineTemplate(() => 0), 'spin');
    assert.equal(pickHeadlineTemplate(() => 0.5), 'going');
    assert.equal(pickHeadlineTemplate(() => 0.9999), 'start');
    assert.equal(pickHeadlineTemplate(() => 1), 'start');

    const slot = (s: 'mode' | 'project' | 'bridge') => ({ slot: s });
    assert.deepEqual(headlineSegments('spin', { hasProject: true, showBridge: true }), ['Spin up a', slot('mode'), 'in', slot('project'), 'on', slot('bridge')]);
    assert.deepEqual(headlineSegments('spin', { hasProject: false, showBridge: true }), ['Spin up a', slot('mode'), slot('project'), 'on', slot('bridge')]);
    assert.deepEqual(headlineSegments('going', { hasProject: true, showBridge: true }), ["Let's get a", slot('mode'), 'going in', slot('project'), 'on', slot('bridge')]);
    assert.deepEqual(headlineSegments('going', { hasProject: false, showBridge: false }), ["Let's get a", slot('mode'), 'going', slot('project')]);
    assert.deepEqual(headlineSegments('start', { hasProject: true, showBridge: false }), ['Start a new', slot('mode'), 'in', slot('project')]);
    assert.deepEqual(headlineSegments('start', { hasProject: false, showBridge: true }), ['Start a new', slot('mode'), slot('project'), 'on', slot('bridge')]);
    // Order is always mode -> project -> bridge.
    for (const id of HEADLINE_TEMPLATE_IDS) {
      for (const hasProject of [true, false]) {
        const slots = headlineSegments(id, { hasProject, showBridge: true }).filter((s) => typeof s !== 'string').map((s: any) => s.slot);
        assert.deepEqual(slots, ['mode', 'project', 'bridge']);
      }
    }

    assert.equal(shouldShowBridgeClause([]), false, 'no bridges');
    assert.equal(shouldShowBridgeClause(undefined), false);
    assert.equal(shouldShowBridgeClause([RIVER]), false, 'exactly one bridge: implied');
    assert.equal(shouldShowBridgeClause([RIVER, REVOKED, ARCHIVED]), false, 'revoked/archived do not count');
    assert.equal(shouldShowBridgeClause([MAC_OFF, { ...DAWN, status: 'offline' }]), false, 'none online');
    assert.equal(shouldShowBridgeClause([MAC_OFF, { ...DAWN, runtime_connected: false }]), false, 'online at hub without runtime is not online');
    assert.equal(shouldShowBridgeClause([RIVER, MAC_OFF]), true, 'two bridges, one online');
    assert.equal(shouldShowBridgeClause([RIVER, DAWN]), true);

    assert.deepEqual(headlineMeta(PROJECTS[1], RIVER, 'main'), { kind: 'project', location: 'riverwood:/var/home/tanmay/heimdall-agent-manager', branch: 'main' });
    assert.deepEqual(headlineMeta(PROJECTS[1], undefined, ''), { kind: 'project', location: '/var/home/tanmay/heimdall-agent-manager', branch: '' });
    assert.deepEqual(headlineMeta(PROJECTS[2], RIVER, ' feat/x '), { kind: 'project', location: '', branch: 'feat/x' });
    assert.deepEqual(headlineMeta(PROJECTS[0], RIVER, 'main'), { kind: 'none' });
    assert.deepEqual(headlineMeta(PROJECTS[3], RIVER, 'main'), { kind: 'none' });
    assert.deepEqual(headlineMeta(null, RIVER, 'main'), { kind: 'none' });
  });
});

test('all three templates render with and without a project; the default project reads "without a project", never "Conversation"', async () => {
  await withDom(async (doc) => {
    const { LaunchHeadline } = await load();
    const expected: Record<string, [string, string]> = {
      spin: ['Spin up a conversation in heimdall-agent-manager on riverwood', 'Spin up a conversation without a project on riverwood'],
      going: ["Let's get a conversation going in heimdall-agent-manager on riverwood", "Let's get a conversation going without a project on riverwood"],
      start: ['Start a new conversation in heimdall-agent-manager on riverwood', 'Start a new conversation without a project on riverwood'],
    };
    for (const [template, [withProject, withoutProject]] of Object.entries(expected)) {
      const ui = await mount(doc, React.createElement(LaunchHeadline, props({ template }) as any));
      assert.equal(headlineText(doc), withProject);
      const h1 = q(doc, 'new-convo-headline')!;
      assert.equal(h1.tagName, 'H1');
      assert.equal(h1.parentElement!.getAttribute('data-headline-template'), template);
      // The default project, found by slug and (in its own list) by flag.
      for (const [projectId, projects] of [['p_conv', PROJECTS.slice(0, 3)], ['p_flag', PROJECTS.slice(1)]] as const) {
        await ui.rerender(React.createElement(LaunchHeadline, props({ template, projectId, projects }) as any));
        assert.equal(headlineText(doc), withoutProject);
        assert.ok(!/Conversation/.test(h1.textContent || ''), 'never the word "Conversation"');
        assert.equal(squash(q(doc, 'new-convo-project-token')!.querySelector('[data-token-value]')!.textContent), 'without a project');
      }
      // Shell mode keeps the same template and order.
      await ui.rerender(React.createElement(LaunchHeadline, props({ template, mode: 'shell' }) as any));
      assert.equal(headlineText(doc), withProject.replace('conversation', 'shell'));
      await ui.unmount();
    }
  });
});

test('template is picked once per mount (random) and is stable across re-renders', async () => {
  await withDom(async (doc) => {
    const { LaunchHeadline } = await load();
    const realRandom = Math.random;
    try {
      Math.random = () => 0.5; // -> going
      const ui = await mount(doc, React.createElement(LaunchHeadline, props() as any));
      const hero = q(doc, 'new-convo-headline')!.parentElement!;
      assert.equal(hero.getAttribute('data-headline-template'), 'going');
      Math.random = () => 0; // a re-pick would give 'spin'
      for (const projectId of ['p_conv', 'p_ham', 'p_nopath']) {
        await ui.rerender(React.createElement(LaunchHeadline, props({ projectId, mode: 'shell' }) as any));
        assert.equal(hero.getAttribute('data-headline-template'), 'going');
        assert.ok(headlineText(doc).startsWith("Let's get a shell going"));
      }
      await ui.unmount();
      // A fresh mount picks again.
      const ui2 = await mount(doc, React.createElement(LaunchHeadline, props() as any));
      assert.equal(q(doc, 'new-convo-headline')!.parentElement!.getAttribute('data-headline-template'), 'spin');
      await ui2.unmount();
    } finally {
      Math.random = realRandom;
    }
  });
});

test('the on [bridge] clause: hidden with one bridge and with none online, shown with 2+ and one online', async () => {
  await withDom(async (doc) => {
    const { LaunchHeadline } = await load();
    const ui = await mount(doc, React.createElement(LaunchHeadline, props({ template: 'start', bridges: [RIVER] }) as any));
    assert.equal(q(doc, 'new-convo-machine-token'), null, 'one bridge: implied');
    assert.equal(headlineText(doc), 'Start a new conversation in heimdall-agent-manager');

    await ui.rerender(React.createElement(LaunchHeadline, props({ template: 'start', bridges: [RIVER, REVOKED, ARCHIVED] }) as any));
    assert.equal(q(doc, 'new-convo-machine-token'), null, 'revoked/archived are not counted');

    await ui.rerender(React.createElement(LaunchHeadline, props({ template: 'start', bridges: [] }) as any));
    assert.equal(q(doc, 'new-convo-machine-token'), null, 'no bridges');

    await ui.rerender(React.createElement(LaunchHeadline, props({ template: 'start', bridges: [MAC_OFF, { ...RIVER, status: 'offline' }] }) as any));
    assert.equal(q(doc, 'new-convo-machine-token'), null, 'none online');

    await ui.rerender(React.createElement(LaunchHeadline, props({ template: 'start', bridges: [RIVER, MAC_OFF] }) as any));
    const token = q(doc, 'new-convo-machine-token');
    assert.ok(token, 'two bridges, one online');
    assert.equal(headlineText(doc), 'Start a new conversation in heimdall-agent-manager on riverwood');
    // Order mode -> project -> bridge in the DOM.
    const slots = Array.from(doc.querySelectorAll('[data-headline-slot]')).map((n) => n.getAttribute('data-headline-slot'));
    assert.deepEqual(slots, ['mode', 'project', 'bridge']);
    await ui.unmount();
  });
});

test('meta line: bridge:path and branch in mono 12px, unknown items omitted; no-project hint', async () => {
  await withDom(async (doc) => {
    const { LaunchHeadline, NO_PROJECT_META } = await load();
    const ui = await mount(doc, React.createElement(LaunchHeadline, props({ branch: 'main', bridges: [RIVER] }) as any));
    const meta = () => q(doc, 'new-convo-meta');
    const item = (name: string) => meta()?.querySelector(`[data-meta-item="${name}"]`) as HTMLElement | null;
    assert.equal(squash(item('location')!.textContent), 'riverwood:/var/home/tanmay/heimdall-agent-manager', 'bridge prefix shown even when the clause is hidden');
    assert.equal(squash(item('branch')!.textContent), 'main');
    for (const el of [item('location')!, item('branch')!]) {
      assert.ok(el.className.includes('font-mono') && el.className.includes('text-code-sm'), el.className);
      assert.ok(el.className.includes('text-muted'));
      assert.ok(el.querySelector('svg'), 'icon');
    }

    await ui.rerender(React.createElement(LaunchHeadline, props({ branch: '' }) as any));
    assert.equal(item('branch'), null, 'unknown branch omitted');
    assert.ok(item('location'));

    await ui.rerender(React.createElement(LaunchHeadline, props({ projectId: 'p_nopath', branch: 'dev' }) as any));
    assert.equal(item('location'), null, 'unknown path omitted');
    assert.equal(squash(item('branch')!.textContent), 'dev');

    await ui.rerender(React.createElement(LaunchHeadline, props({ projectId: 'p_nopath' }) as any));
    assert.equal(meta(), null, 'nothing known: no meta line');

    await ui.rerender(React.createElement(LaunchHeadline, props({ projectId: 'p_conv', branch: 'main' }) as any));
    assert.equal(squash(meta()!.textContent), NO_PROJECT_META);
    assert.equal(NO_PROJECT_META, 'Not tied to a repo. Pick a project above to work in its code.');
    assert.equal(meta()!.querySelector('[data-meta-item]'), null);
    await ui.unmount();
  });
});

test('mobile wrapping: each connector\'s last word stays with its token, values truncate, meta items stay on one line', async () => {
  await withDom(async (doc) => {
    const { LaunchHeadline } = await load();
    const ui = await mount(doc, React.createElement(LaunchHeadline, props({ template: 'going', branch: 'feature/a-very-long-branch-name' }) as any));
    const h1 = q(doc, 'new-convo-headline')!;
    assert.ok(h1.className.split(' ').includes('max-md:[text-wrap:balance]'), h1.className);
    assert.equal(headlineText(doc), "Let's get a conversation going in heimdall-agent-manager on riverwood", 'text unchanged');
    // "a" + mode, "in" + project ("going" stays outside), "on" + bridge: one no-wrap group each.
    const groups = Array.from(h1.querySelectorAll('[data-headline-group]')) as HTMLElement[];
    assert.deepEqual(groups.map((g) => [g.getAttribute('data-headline-group'), squash(g.firstElementChild!.textContent)]), [['mode', 'a'], ['project', 'in'], ['bridge', 'on']]);
    for (const g of groups) {
      assert.ok(g.className.split(' ').includes('whitespace-nowrap'), g.className);
      assert.ok(g.querySelector('[data-headline-slot]'), 'the token is inside the group');
    }
    assert.ok(!groups[1].textContent!.includes('going'), '"going" is not glued to the project token');
    // Each value truncates beside its chevron below md (desktop keeps the plain inline value).
    for (const id of ['new-convo-mode-token', 'new-convo-project-token', 'new-convo-machine-token']) {
      const value = q(doc, id)!.querySelector('[data-token-value]') as HTMLElement;
      for (const cls of ['max-md:min-w-0', 'max-md:truncate']) assert.ok(value.className.split(' ').includes(cls), `${id} value has ${cls}`);
    }
    // Path and branch: one line, ellipsis, full text in the title, icon never squeezed.
    for (const [name, full] of [['location', 'riverwood:/var/home/tanmay/heimdall-agent-manager'], ['branch', 'feature/a-very-long-branch-name']] as const) {
      const item = q(doc, 'new-convo-meta')!.querySelector(`[data-meta-item="${name}"]`) as HTMLElement;
      assert.equal(item.getAttribute('title'), full);
      for (const cls of ['min-w-0', 'max-w-full']) assert.ok(item.className.split(' ').includes(cls), `${name} has ${cls}`);
      const text = item.querySelector('span') as HTMLElement;
      assert.ok(text.className.split(' ').includes('truncate') && text.className.split(' ').includes('min-w-0'), `${name} text truncates`);
      assert.ok(item.querySelector('svg')!.getAttribute('class')!.includes('shrink-0'), `${name} icon is shrink-0`);
    }
    await ui.unmount();
  });
});

test('typography and token wiring: serif headline role, muted connectors, primary tokens, menus open one at a time', async () => {
  await withDom(async (doc, win) => {
    const { LaunchHeadline } = await load();
    const changes: Array<string | null> = [];
    const ui = await mount(doc, React.createElement(LaunchHeadline, props({ onMenuOpenChange: (m: string | null) => changes.push(m) }) as any));
    const h1 = q(doc, 'new-convo-headline')!;
    for (const cls of ['text-headline-sm', 'md:text-headline', 'text-muted']) assert.ok(h1.className.split(' ').includes(cls), `${cls} in ${h1.className}`);
    for (const id of ['new-convo-mode-token', 'new-convo-project-token', 'new-convo-machine-token']) {
      const token = q(doc, id)!;
      assert.equal(token.tagName, 'BUTTON');
      assert.ok(token.className.includes('text-primary'));
    }
    await ui.act(async () => {
      q(doc, 'new-convo-mode-token')!.dispatchEvent(new win.MouseEvent('click', { bubbles: true }));
    });
    assert.equal(q(doc, 'new-convo-mode-token')!.getAttribute('aria-expanded'), 'true');
    await ui.act(async () => {
      q(doc, 'new-convo-project-token')!.dispatchEvent(new win.MouseEvent('click', { bubbles: true }));
    });
    assert.equal(q(doc, 'new-convo-project-token')!.getAttribute('aria-expanded'), 'true');
    assert.equal(q(doc, 'new-convo-mode-token')!.getAttribute('aria-expanded'), 'false');
    assert.ok(changes.includes('mode') && changes.includes('project'), JSON.stringify(changes));
    await ui.unmount();
  });
});

test('@ui Text gains the headline and code-sm roles', async () => {
  await withDom(async (doc) => {
    const { Text } = await import('../src/ui/components/ui/primitives/Text.tsx');
    const ui = await mount(doc, React.createElement('div', null,
      React.createElement(Text, { role: 'headline', as: 'h1', id: 'h' }, 'x'),
      React.createElement(Text, { role: 'code-sm', id: 'c' }, 'y'),
    ));
    const h = doc.getElementById('h')!;
    assert.equal(h.tagName, 'H1');
    assert.equal(h.className, 'text-headline-sm md:text-headline text-primary');
    const c = doc.getElementById('c')!;
    assert.equal(c.tagName, 'CODE');
    assert.equal(c.className, 'text-code-sm font-mono text-primary');
    await ui.unmount();
  });
});
