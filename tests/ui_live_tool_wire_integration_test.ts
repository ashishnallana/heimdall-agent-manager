import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import { JSDOM } from 'jsdom';
import reducer, { parseLiveSnapshot, liveFrameReceived, liveStreamReady, liveStreamDisconnected } from '../src/ui/store/toolActivitySlice.ts';
import LiveToolActivity from '../src/ui/components/extension/LiveToolActivity.tsx';

// Consume the real fresh isolated HTTP/WS evidence, rather than hand-copying its
// protocol into a test fixture. The stack uses injected canonical provider events.
test('real Bridge -> Hub REST/WS payloads render, survive snapshot races, and finish without polling', async () => {
  const dir = process.env.LIVE_TOOLS_EVIDENCE!;
  assert.ok(dir, 'LIVE_TOOLS_EVIDENCE must name the fresh integration run');
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, 'manifest.json'), 'utf8'));
  assert.equal(manifest.status, 'pass');
  const frames = manifest.ui_frames;
  assert.ok(frames.length > 5);
  for (const raw of [...frames, ...manifest.snapshots]) {
    assert.ok(parseLiveSnapshot(raw), `UI accepts actual wire frame revision ${raw.revision}`);
  }
  const page = manifest.chain_snapshot;
  const ids = page.members.map((m: any) => m.instance_id);
  const dom = new JSDOM('<div id="root"></div>', {url: 'https://hub.test/'});
  const keys = ['window', 'document', 'HTMLElement', 'Node', 'IS_REACT_ACT_ENVIRONMENT'];
  const old = Object.fromEntries(keys.map(k => [k, (globalThis as any)[k]]));
  const oldFetch = globalThis.fetch;
  Object.assign(globalThis, {window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement,
    Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true});
  let requests = 0, resolveSnapshot!: (response: Response) => void;
  globalThis.fetch = async () => { requests++; return new Promise<Response>(resolve => { resolveSnapshot = resolve; }); };
  const store = configureStore({reducer: {toolActivity: reducer}});
  const root = createRoot(dom.window.document.getElementById('root')!);
  const q = (id: string) => dom.window.document.querySelector(`[data-debug-id="${id}"]`) as HTMLElement;
  try {
    await act(async () => root.render(React.createElement(Provider, {store,
      children: React.createElement(LiveToolActivity, {instanceId: ids[0], chainId: page.chain_id, onOpenShell() {}})})));
    assert.equal(requests, 0);
    await act(async () => { store.dispatch(liveStreamReady()); });
    assert.equal(requests, 1);
    // Complete A while the older initial REST page is still outstanding.
    const finalA = frames.find((f: any) => f.instance_id === ids[0] && f.active.length === 0 && f.last_completion);
    assert.ok(finalA);
    await act(async () => { store.dispatch(liveFrameReceived(parseLiveSnapshot(finalA)!)); });
    await act(async () => { resolveSnapshot(new Response(JSON.stringify({data: page}))); });
    assert.equal(store.getState().toolActivity.scopes['chain:' + page.chain_id].members[ids[0]].snapshot!.active.length, 0);
    await act(async () => { q('live-tools-toggle').click(); });
    // Only tool pushes; no chat fetch, extension history or shell inventory.
    await act(async () => { for (const f of frames) store.dispatch(liveFrameReceived(parseLiveSnapshot(f)!)); });
    assert.match(q('live-tools-toggle').textContent!, /0 running/);
    await act(async () => { q('live-tools-toggle').click(); });
    assert.equal(dom.window.document.querySelectorAll('[data-debug-id^="live-tools-shell-"]').length, 0);
    assert.ok(dom.window.document.querySelectorAll('[data-debug-id^="live-tools-last-duration-"]').length <= 2);
    assert.equal(requests, 1, 'all real completion frames and idle/collapse make no additional requests');
    await act(async () => { store.dispatch(liveStreamDisconnected()); });
    assert.equal(q('live-tool-activity'), null);
    // A late old fetch/frame cannot restore anything while disconnected.
    await act(async () => { store.dispatch(liveFrameReceived(parseLiveSnapshot(frames[0])!)); });
    assert.equal(q('live-tool-activity'), null);
  } finally {
    await act(async () => root.unmount());
    globalThis.fetch = oldFetch; Object.assign(globalThis, old); dom.window.close();
  }
});
