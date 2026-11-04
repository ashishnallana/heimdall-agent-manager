// T16: a directory listing that contains a file whose on-disk name is not valid
// UTF-8 must render in BridgeDirectoryPicker without a parse error. The bridge now
// sends such names as U+FFFD (`�` escapes) with name_lossy:true; the picker
// shows them but never navigates into them, since the lossy name does not address
// the entry on disk.
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_bridge_fs_lossy_names_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

// Verbatim shape of a fixed bridge's fs_list_dir_result (strict JSON escapes only).
const LISTING = String.raw`{"type":"fs_list_dir_result","command_id":"c1","ok":true,"path":"/home/u","root":"/home/u","parent":"","truncated":false,"has_more":false,"next_cursor":null,"entries":[`
  + String.raw`{"name":"dir_�","is_dir":true,"hidden":false,"has_git":false,"size":0,"modified_at":"2026-11-03T00:00:00Z","name_lossy":true},`
  + String.raw`{"name":"ok \"q\" \\ \u0001 😀","is_dir":true,"hidden":false,"has_git":false,"size":0,"modified_at":"2026-11-03T00:00:00Z","name_lossy":false},`
  + String.raw`{"name":"���","is_dir":false,"hidden":false,"has_git":false,"size":3,"modified_at":"2026-11-03T00:00:00Z","name_lossy":true}`
  + String.raw`],"error":{"code":"","class":"","cause":"","message":""}}`;

test('BridgeDirectoryPicker lists a folder with a non-UTF-8 name and disables it', async () => {
  const React = await import('react');
  const { act } = React;
  const { JSDOM } = await import('jsdom');
  const { createRoot } = await import('react-dom/client');
  const { Provider } = await import('react-redux');
  const { makeVaultStore } = await import('./helpers/vaultEndpointHarness.ts');
  const { default: BridgeDirectoryPicker } = await import('../src/ui/components/BridgeDirectoryPicker.tsx');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const dom = new JSDOM('<div id="root"></div>', { url: 'http://localhost/', pretendToBeVisual: true });
  const saved: any = {};
  for (const key of ['window', 'document', 'HTMLElement', 'Node', 'IS_REACT_ACT_ENVIRONMENT']) saved[key] = (globalThis as any)[key];
  Object.assign(globalThis, { window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true });
  // RTK schedules listener work with requestAnimationFrame; keep timer-backed
  // globals in place (not restored to undefined) so late callbacks cannot throw.
  (globalThis as any).requestAnimationFrame ??= (cb: any) => setTimeout(() => cb(Date.now()), 0);
  (globalThis as any).cancelAnimationFrame ??= (id: any) => clearTimeout(id);
  const previousFetch = globalThis.fetch;
  const urls: string[] = [];
  globalThis.fetch = (async (input: any) => {
    urls.push(String(input?.url ?? input));
    return { ok: true, status: 200, text: async () => LISTING, json: async () => JSON.parse(LISTING) };
  }) as any;
  const store = await makeVaultStore();
  const root = createRoot(dom.window.document.getElementById('root')!);
  // Compare attributes directly: the names under test contain quotes and control
  // characters that a CSS attribute selector cannot hold unescaped.
  const q = (id: string) => (Array.from(dom.window.document.querySelectorAll('[data-debug-id]'))
    .find((el: any) => el.getAttribute('data-debug-id') === id) ?? null) as HTMLButtonElement | null;
  try {
    await act(async () => { root.render(React.createElement(Provider, { store, children: React.createElement(BridgeDirectoryPicker, {
      bridgeId: 'brg_1', onPick: () => {}, debugId: 'pick',
    }) })); });
    const text = dom.window.document.body.textContent || '';
    assert.doesNotMatch(text, /JSON parse failed|Bridge unavailable/);

    // Only directories are listed; the lossy one is shown, flagged and disabled.
    const lossy = q('pick-entry-dir_�');
    assert.ok(lossy, 'lossy directory is listed');
    assert.equal(lossy!.disabled, true);
    assert.match(lossy!.textContent || '', /Unreadable name/);
    assert.match(lossy!.title, /not valid UTF-8/);

    // A valid name with quotes, a backslash, a control char and an emoji round-trips exactly.
    const okName = 'ok "q" \\ \u0001 \u{1F600}';
    const ok = q('pick-entry-' + okName);
    assert.ok(ok, 'valid directory is listed with its exact name');
    assert.equal(ok!.disabled, false);
    assert.doesNotMatch(ok!.textContent || '', /Unreadable name/);

    const before = urls.length;
    await act(async () => { lossy!.click(); });
    assert.equal(urls.length, before, 'a lossy entry never triggers a listing of a path built from its name');
    await act(async () => { ok!.click(); });
    assert.equal(urls.length, before + 1);
    assert.match(urls[urls.length - 1], new RegExp(encodeURIComponent('/home/u/' + okName).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    globalThis.fetch = previousFetch;
    for (const key of Object.keys(saved)) (globalThis as any)[key] = saved[key];
    dom.window.close();
  }
});
