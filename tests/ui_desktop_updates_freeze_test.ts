import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { JSDOM } from 'jsdom';
import { configureStore } from '@reduxjs/toolkit';
import fs from 'node:fs';
import vm from 'node:vm';
import { transformSync } from 'esbuild';
import { desktopUpdatePreparation, desktopUpdateMutationGuard, installDesktopUpdatePreparation } from '../src/ui/utils/desktopUpdatePreparation.ts';

const deferred = <T,>() => { let resolve!: (value: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { promise, resolve }; };
const tick = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };

test('held preparation synchronously excludes real shortcuts, RTK lifecycle and requests until native completion', async () => {
  const dom = new JSDOM('<!doctype html><div id="root"></div>', { url: 'https://fixture.test' });
  const previous = new Map<string, PropertyDescriptor | undefined>();
  for (const [key, value] of Object.entries({ window: dom.window, document: dom.window.document,
    navigator: dom.window.navigator, HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true })) {
    previous.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { configurable: true, writable: true, value });
  }
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { ShortcutProvider, useShortcuts } = await import('../src/ui/services/shortcuts/ShortcutContext.tsx');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { cookieMutation, cookieJsonFetch } = await import('../src/ui/api/cookieFetch.ts');
  const daemonApi = await import('../src/ui/api/daemonApi.ts');
  let shortcutCalls = 0; let mutationCalls = 0; let lifecycleCalls = 0; let requests = 0;
  let shortcuts: ReturnType<typeof useShortcuts>;
  function Probe() {
    shortcuts = useShortcuts();
    React.useEffect(() => shortcuts.registerActions([{
      id: 'fixture.new-work', title: 'New work', category: 'Fixture', sequence: ['n'],
      run: () => { shortcutCalls++; },
    }]), [shortcuts.registerActions]);
    return null;
  }
  const api = heimdallApi.injectEndpoints({ endpoints: build => ({
    freezeFixtureMutation: build.mutation<any, void>({
      queryFn: async () => { mutationCalls++; return { data: await cookieMutation('/fixture') }; },
      onQueryStarted: () => { lifecycleCalls++; },
    }),
  }) });
  const store = configureStore({ reducer: { [api.reducerPath]: api.reducer },
    middleware: getDefault => getDefault().prepend(desktopUpdateMutationGuard).concat(api.middleware) });
  const root = createRoot(dom.window.document.getElementById('root')!);
  const oldFetch = globalThis.fetch;
  globalThis.fetch = async () => { requests++; return { ok: true, text: async () => '{}', json: async () => ({}) } as any; };
  let prepare!: (arg: any) => Promise<void>; let release!: (arg: any) => void;
  let acknowledge: ReturnType<typeof deferred<boolean>>;
  let restart: any;
  const removeSurface = desktopUpdatePreparation.register({ flush: () => {} });
  const stop = installDesktopUpdatePreparation({
    schemaVersion: 1,
    onPrepare: (fn: any) => { prepare = fn; return () => {}; },
    onRelease: (fn: any) => { release = fn; return () => {}; },
    preparationResult: ({ ready }: any) => { if (ready) acknowledge.resolve(true); else restart.abort('Renderer invalidated'); },
  }, dom.window.document);
  const module = { exports: {} as any };
  vm.runInNewContext(transformSync(fs.readFileSync(new URL('../src/ui/electron/desktopUpdateRestart.cts', import.meta.url), 'utf8'),
    { loader: 'ts', format: 'cjs' }).code, { module, exports: module.exports, setTimeout, clearTimeout });
  const native = deferred<void>(); let finalGate!: () => boolean; let installs = 0; let phase = 'downloaded';
  restart = module.exports.createDesktopUpdateRestart({
    controller: { getState: () => ({ phase, targetVersion: '1.2.4' }),
      beginRestart: () => { phase = 'preparing-restart'; return true; }, abortRestart: () => { phase = 'downloaded'; } },
    bridgeBusy: () => false, eligibility: () => true, document: () => dom.window.document,
    prepare: (epoch: number) => { acknowledge = deferred<boolean>(); void prepare({ epoch }); return acknowledge.promise; },
    release: (epoch: number) => release({ epoch }), confirm: async () => true,
    install: (gate: () => boolean) => { finalGate = gate; return native.promise; }, cancelInstall: () => {},
  });
  try {
    await act(async () => root.render(React.createElement(ShortcutProvider, {}, React.createElement(Probe))));
    await act(async () => { dom.window.document.body.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'n', bubbles: true })); });
    assert.equal(shortcutCalls, 1, 'real window-capture shortcut works before preparation');
    const pending = restart.restart();
    await tick();
    assert.equal(desktopUpdatePreparation.validate(), true);
    assert.equal(typeof finalGate, 'function', 'native staging remains delayed after renderer ack and consent');

    await act(async () => {
      dom.window.document.body.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'n', bubbles: true, cancelable: true }));
      assert.equal(shortcuts.runAction('fixture.new-work'), false, 'programmatic action path is frozen too');
    });
    assert.equal(shortcutCalls, 1);
    // A later callback starts a real RTK mutation after readiness, before native completion.
    const oldError = console.error;
    console.error = () => {};
    try {
      const result = await Promise.resolve().then(() => store.dispatch(api.endpoints.freezeFixtureMutation.initiate()));
      assert.ok(result.error, 'RTK resolves to a rejected result instead of starting queryFn');
    } finally { console.error = oldError; }
    assert.equal(mutationCalls, 0);
    assert.equal(lifecycleCalls, 0);
    assert.equal(requests, 0);
    await assert.rejects(cookieMutation('/delayed-direct'), /restart is preparing/);
    await assert.rejects(cookieJsonFetch('/delayed-init', { method: 'POST' }), /restart is preparing/);
    await assert.rejects(daemonApi.createTaskChain({ daemonUrl: 'https://fixture.test' }), /restart is preparing/);
    assert.equal(requests, 0, 'direct mutation transport cannot bypass the thunk guard');

    // Invalidation synchronously revokes main authorization; no observer tick needed.
    const removeLate = desktopUpdatePreparation.register({ flush: () => {} });
    assert.equal((await pending).ok, false);
    if (finalGate()) installs++;
    native.resolve();
    assert.equal(installs, 0, 'late native completion cannot consume invalid authorization');
    assert.equal(desktopUpdatePreparation.frozen(), false);
    removeLate();
    await act(async () => { assert.equal(shortcuts.runAction('fixture.new-work'), true); });
    const retry = await store.dispatch(api.endpoints.freezeFixtureMutation.initiate());
    assert.ok('data' in retry);
    assert.equal(mutationCalls, 1); assert.equal(lifecycleCalls, 1); assert.equal(requests, 1);
  } finally {
    restart.abort(); stop(); removeSurface();
    await act(async () => root.unmount());
    store.dispatch(api.util.resetApiState());
    globalThis.fetch = oldFetch;
    dom.window.close();
    for (const [key, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete (globalThis as any)[key];
    }
  }
});
