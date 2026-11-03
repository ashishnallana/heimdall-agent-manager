// useShellLaunch (new-conversation redesign spec §3.4 shell, step 6): the launch logic
// extracted from ShellLaunchPanel. The panel must issue the SAME createShell request as
// before the extraction (kind=shell, project_id, cwd sealed in the spec, no cmd), and
// the hook's optional command reaches the sealed spec only when non-blank.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_use_shell_launch_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { makeVaultStore, unlockVault } from './helpers/vaultEndpointHarness.ts';
import { buildInteractiveShellRequest } from '../src/ui/components/shells/interactiveShellLaunch.ts';
import { shellLaunchBlock } from '../src/ui/components/shells/useShellLaunch.ts';

const SHELL_TEST_KEY = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const BOOT_ID = 'b1'.repeat(16);
const ONLINE = { status: 'online', runtime_connected: true };
const BRIDGES = [
  { bridge_id: 'bridge-off', name: 'Off', status: 'offline' },
  { bridge_id: 'bridge-a', name: 'A', ...ONLINE },
  { bridge_id: 'bridge-gone', name: 'Gone', status: 'revoked' },
];
const PROJECTS = [
  { project_id: 'project-a', name: 'Project A', state: 'active', bridge_paths: [{ bridge_id: 'bridge-a', path: ' /srv/project-a ' }] },
];

async function until(pred: () => boolean, ms = 5000): Promise<void> {
  const end = Date.now() + ms;
  while (!pred() && Date.now() < end) await new Promise((resolve) => setTimeout(resolve, 10));
}

test('builder forwards a trimmed command and omits a blank one', () => {
  assert.deepEqual(
    buildInteractiveShellRequest({ bridgeId: 'bridge-a', cmd: '  ls -la  ', projectId: 'project-a' }),
    { bridgeId: 'bridge-a', kind: 'shell', cmd: 'ls -la', project_id: 'project-a' },
  );
  const blank = buildInteractiveShellRequest({ bridgeId: 'bridge-a', cmd: '   ' });
  assert.deepEqual(blank, { bridgeId: 'bridge-a', kind: 'shell' });
  assert.equal('cmd' in blank, false, 'no command: the bridge starts the login shell');
});

test('block reasons are checked plan, then vault, then bridge', () => {
  const online = { ...ONLINE };
  assert.equal(shellLaunchBlock({ shellsEnabled: false, vaultUnlocked: false, bridge: undefined }), 'plan');
  assert.equal(shellLaunchBlock({ shellsEnabled: true, vaultUnlocked: false, bridge: undefined }), 'vault');
  assert.equal(shellLaunchBlock({ shellsEnabled: true, vaultUnlocked: true, bridge: undefined }), 'bridge');
  assert.equal(shellLaunchBlock({ shellsEnabled: true, vaultUnlocked: true, bridge: { status: 'offline' } }), 'bridge');
  assert.equal(shellLaunchBlock({ shellsEnabled: true, vaultUnlocked: true, bridge: { ...online, plan_disabled_at: 'x' } }), 'bridge');
  assert.equal(shellLaunchBlock({ shellsEnabled: true, vaultUnlocked: true, bridge: online }), '');
});

/** Mounts `element` in jsdom with a vault-unlocked store; captures shell POST bodies. */
async function withDom(run: (ctx: {
  render: (el: React.ReactElement) => Promise<void>;
  doc: Document;
  posts: Record<string, any>[];
  act: (fn: () => Promise<void> | void) => Promise<void>;
}) => Promise<void>) {
  const { JSDOM } = await import('jsdom');
  const { Provider } = await import('react-redux');
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');

  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', { url: 'http://localhost/' });
  const saved = {
    window: (globalThis as any).window,
    document: (globalThis as any).document,
    HTMLElement: (globalThis as any).HTMLElement,
    navigator: (globalThis as any).navigator,
    fetch: (globalThis as any).fetch,
    raf: (globalThis as any).requestAnimationFrame,
    caf: (globalThis as any).cancelAnimationFrame,
  };
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).requestAnimationFrame = (cb: any) => setTimeout(cb, 0);
  (globalThis as any).cancelAnimationFrame = (id: any) => clearTimeout(id);
  Object.defineProperty(globalThis, 'navigator', { value: dom.window.navigator, configurable: true });
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

  const posts: Record<string, any>[] = [];
  (globalThis as any).fetch = async (input: any, init: any = {}) => {
    const url = String(input?.url ?? input);
    const method = String(init?.method || input?.method || 'GET').toUpperCase();
    let body: any = { data: { sessions: [] } };
    if (method === 'POST' && url.includes('/shells')) {
      const raw = init?.body || (typeof input?.clone === 'function' ? await input.clone().text() : '');
      const parsed = JSON.parse(String(raw || '{}'));
      posts.push(parsed);
      body = { data: { session: { session_id: parsed.session_id, kind: 'shell', status: 'running' } } };
    } else if (url.includes('/public-key')) {
      body = { data: { unseal_boot_id: BOOT_ID } };
    }
    return {
      ok: true,
      status: 200,
      headers: { get: () => 'application/json' },
      text: async () => JSON.stringify(body),
      json: async () => body,
    } as any;
  };

  const store = await makeVaultStore();
  await unlockVault(store, SHELL_TEST_KEY);
  const root = createRoot(dom.window.document.getElementById('root')!);
  try {
    await run({
      doc: dom.window.document,
      posts,
      act: async (fn) => { await act(async () => { await fn(); }); },
      render: async (el) => {
        await act(async () => {
          root.render(React.createElement(Provider, { store }, el));
          await new Promise((resolve) => setTimeout(resolve, 30));
        });
      },
    });
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    (await import('../src/ui/utils/vaultCrypto.ts')).setActiveVaultKey(null);
    dom.window.close();
    (globalThis as any).window = saved.window;
    (globalThis as any).document = saved.document;
    (globalThis as any).HTMLElement = saved.HTMLElement;
    (globalThis as any).fetch = saved.fetch;
    (globalThis as any).requestAnimationFrame = saved.raf;
    (globalThis as any).cancelAnimationFrame = saved.caf;
    Object.defineProperty(globalThis, 'navigator', { value: saved.navigator, configurable: true });
  }
}

async function openSpec(post: Record<string, any>) {
  const { decryptVaultText } = await import('../src/ui/utils/vaultCrypto.ts');
  return JSON.parse(await decryptVaultText(String(post.enc_spec)));
}

test('ShellLaunchPanel Start issues the same interactive shell request as before the extraction', async () => {
  const { ShellLaunchPanel } = await import('../src/ui/components/chat/ShellLaunchPanel.tsx');
  await withDom(async ({ render, doc, posts, act }) => {
    const opened: string[] = [];
    await render(React.createElement(ShellLaunchPanel, {
      projects: PROJECTS,
      bridges: BRIDGES,
      projectId: 'project-a',
      onProjectChange: () => {},
      initialBridgeId: 'bridge-off',
      isMobile: false,
      onOpenShell: (id: string) => { opened.push(id); },
    }));

    const select = doc.querySelector('[data-debug-id="new-convo-shell-bridge-select"]') as HTMLSelectElement;
    assert.equal(select.value, 'bridge-a', 'an offline preferred bridge falls back to the first online one');
    assert.deepEqual([...select.options].map((o) => o.value), ['bridge-a', 'bridge-off'], 'revoked hidden, online first');
    const cwd = doc.querySelector('[data-debug-id="new-convo-shell-cwd-input"]') as HTMLInputElement;
    assert.equal(cwd.value, '/srv/project-a', "cwd defaults to the project's path on the bridge");

    const startBtn = doc.querySelector('[data-debug-id="new-convo-shell-start-btn"]') as HTMLButtonElement;
    assert.equal(startBtn.disabled, false);
    await act(async () => { startBtn.click(); });
    await until(() => opened.length > 0);
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 10)); });

    assert.equal(posts.length, 1, 'exactly one shell start');
    const { enc_spec, session_id, ...plain } = posts[0];
    assert.deepEqual(plain, { kind: 'shell', project_id: 'project-a' });
    const spec = await openSpec(posts[0]);
    assert.equal(spec.cwd, '/srv/project-a');
    assert.equal(spec.cmd, '', 'the panel never sends a command: the login shell');
    assert.deepEqual([spec.bridge_id, spec.kind, spec.boot_id], ['bridge-a', 'shell', BOOT_ID]);
    assert.deepEqual(opened, [session_id], 'the started session opens');
  });
});

test('useShellLaunch exposes command, busy and block state and seals a typed command', async () => {
  const { useShellLaunch } = await import('../src/ui/components/shells/useShellLaunch.ts');
  await withDom(async ({ render, posts, act }) => {
    let launch: any = null;
    const opened: string[] = [];
    const Probe = (props: { bridges: any[] }) => {
      launch = useShellLaunch({ projects: PROJECTS, bridges: props.bridges, projectId: 'project-a', onStarted: (id) => { opened.push(id); } });
      return null;
    };

    // No online bridge: blocked, and start() is a no-op.
    await render(React.createElement(Probe, { bridges: [BRIDGES[0]] }));
    assert.equal(launch.blocked, 'bridge');
    assert.equal(launch.canStart, false);
    await act(async () => { await launch.start(); });
    assert.equal(posts.length, 0, 'a blocked launch sends nothing');

    await render(React.createElement(Probe, { bridges: BRIDGES }));
    assert.equal(launch.blocked, '');
    assert.equal(launch.bridgeId, 'bridge-a');
    assert.equal(launch.defaultCwd, '/srv/project-a');
    assert.equal(launch.command, '');
    assert.equal(launch.busy, false);
    assert.equal(launch.errorMessage, '');
    assert.equal(launch.upgradeDetails, null);
    assert.equal(launch.canStart, true);

    await act(async () => { launch.setCommand('  htop  '); launch.setCwd(' /tmp '); });
    await act(async () => { await launch.start(); });
    await until(() => opened.length > 0);

    assert.equal(posts.length, 1);
    const { enc_spec, session_id, ...plain } = posts[0];
    assert.deepEqual(plain, { kind: 'shell', project_id: 'project-a' }, 'cmd and cwd never travel in clear');
    const spec = await openSpec(posts[0]);
    assert.equal(spec.cmd, 'htop');
    assert.equal(spec.cwd, '/tmp');
    assert.deepEqual(opened, [session_id]);
  });
});
