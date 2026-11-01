import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { JSDOM } from 'jsdom';
import { desktopUpdatePreparation, installDesktopUpdatePreparation, unsupportedUpdateEditorOpen } from '../src/ui/utils/desktopUpdatePreparation.ts';
import { writeComposerDraftChecked, getComposerDraftKey } from '../src/ui/utils/clientPersistence.ts';
import { flushWorkspaceForDesktopUpdate } from '../src/ui/utils/desktopUpdatePersistence.ts';
import { buildDefaultSplitTree } from '../src/ui/store/workspaceLayoutSlice.ts';
import { loadSavedLayout, readGroupIndex } from '../src/ui/store/splitGroups.ts';
import { readAuxPanesState, readWorkspaceChromeState } from '../src/ui/utils/clientPersistence.ts';

const { default: Panel } = await import('../src/ui/components/settings/DesktopUpdatesPanel.tsx');
const state = (phase = 'idle') => ({ schemaVersion: 1, phase, currentVersion: '1.2.3', targetVersion: '1.2.4', supported: true, reason: 'signed-install',
  channel: 'stable', message: phase, errorCode: '', retryable: phase === 'error', percent: 42, transferred: 42, total: 100, lastCheckedAt: null });

test('unknown editors block even empty deletions; registered composer and empty attachment input do not', () => {
  const dom = new JSDOM('<textarea data-debug-id="conversation-composer-input"></textarea><input type="file" data-debug-id="conversation-attach-input"><input type="search">');
  try {
    assert.equal(unsupportedUpdateEditorOpen(dom.window.document), false);
    for (const markup of ['<input value="">', '<textarea></textarea>', '<select></select>', '<iframe></iframe>', '<div contenteditable="true"></div>', '<div class="monaco-editor"></div>']) {
      const element = dom.window.document.createElement('div'); element.innerHTML = markup; dom.window.document.body.append(element);
      assert.equal(unsupportedUpdateEditorOpen(dom.window.document), true, markup); element.remove();
    }
  } finally { dom.window.close(); }
});

test('rendered panel handles browser, old preload, subscribed progress/retry/restart and listener cleanup', async () => {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.example/' });
  const savedWindow = (globalThis as any).window; const savedDocument = (globalThis as any).document;
  (globalThis as any).window = dom.window; (globalThis as any).document = dom.window.document; (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  const root = createRoot(dom.window.document.getElementById('root')!);
  const text = () => dom.window.document.body.textContent || '';
  const query = (id: string) => dom.window.document.querySelector(`[data-debug-id="${id}"]`) as HTMLButtonElement | null;
  let listener: ((next: any) => void) | null = null; let unsubscribed = 0; let checks = 0; let retries = 0; let restarts = 0;
  try {
    await act(async () => root.render(React.createElement(Panel)));
    assert.match(text(), /browser/); assert.equal(query('desktop-updates-check'), null);
    (dom.window as any).odinApi = {};
    await act(async () => root.render(React.createElement(Panel, { key: 'old' })));
    assert.match(text(), /manual upgrade/);
    const api = { schemaVersion: 1, getState: async () => state(), check: async () => { checks++; return state('checking'); },
      retry: async () => { retries++; return state('checking'); }, restartAndInstall: async () => { restarts++; return { ok: false, error: 'Close pending edits' }; },
      onState: (fn: (next: any) => void) => { listener = fn; return () => { unsubscribed++; listener = null; }; },
      onPrepare() { return () => {}; }, onRelease() { return () => {}; }, preparationResult: async () => ({ ok: true }) };
    (dom.window as any).odinApi = { desktopUpdates: api };
    await act(async () => root.render(React.createElement(Panel, { key: 'current' })));
    assert.match(text(), /1.2.3/); await act(async () => query('desktop-updates-check')!.click()); assert.equal(checks, 1);
    await act(async () => listener!(state('downloading')));
    assert.equal(query('desktop-updates-progress')?.getAttribute('value'), '42');
    assert.equal(query('desktop-updates-check')!.disabled, true);
    await act(async () => listener!(state('error'))); await act(async () => query('desktop-updates-retry')!.click()); assert.equal(retries, 1);
    await act(async () => listener!(state('downloaded'))); await act(async () => query('desktop-updates-later')!.click()); assert.equal(restarts, 0);
    await act(async () => query('desktop-updates-restart')!.click()); assert.equal(restarts, 1); assert.match(text(), /Close pending edits/);
    await act(async () => root.unmount()); assert.equal(unsubscribed, 1);
  } finally {
    (globalThis as any).window = savedWindow; (globalThis as any).document = savedDocument; dom.window.close();
  }
});

test('renderer freezes before checked persistence and blocks edit/send/upload events until matching release', async () => {
  const dom = new JSDOM('<input id="composer"><button id="send">Send</button><input id="upload" type="file">', { url: 'https://hub.example/' });
  const saved = (globalThis as any).window; (globalThis as any).window = dom.window;
  let prepare: (request: any) => Promise<void> = async () => {}; let release = (_request: any) => {};
  const acknowledgements: any[] = []; let submits = 0;
  const api = { schemaVersion: 1, onPrepare: (fn: any) => { prepare = fn; return () => {}; }, onRelease: (fn: any) => { release = fn; return () => {}; },
    preparationResult: async (payload: any) => { acknowledgements.push(payload); } };
  const cleanup = installDesktopUpdatePreparation(api, dom.window.document);
  const input = dom.window.document.getElementById('composer') as HTMLInputElement;
  input.value = 'latest keystroke';
  const unregister = desktopUpdatePreparation.register({ flush: () => writeComposerDraftChecked('inst_test', input.value) });
  dom.window.document.getElementById('send')!.addEventListener('click', () => { submits++; });
  try {
    await prepare({ epoch: 101 });
    assert.equal(dom.window.localStorage.getItem(getComposerDraftKey('inst_test')), 'latest keystroke');
    assert.equal(acknowledgements.at(-1).ready, true);
    assert.ok(dom.window.document.querySelector('[data-debug-id="desktop-update-preparing-overlay"]'));
    for (const [id, event] of [['composer', 'beforeinput'], ['send', 'click'], ['upload', 'change']]) {
      const allowed = dom.window.document.getElementById(id)!.dispatchEvent(new dom.window.Event(event, { bubbles: true, cancelable: true }));
      assert.equal(allowed, false, event);
    }
    assert.equal(submits, 0); release({ epoch: 100 }); assert.equal(desktopUpdatePreparation.frozen(), true);
    release({ epoch: 101 }); assert.equal(desktopUpdatePreparation.frozen(), false);
    dom.window.document.getElementById('send')!.click(); assert.equal(submits, 1);
  } finally { unregister(); cleanup(); (globalThis as any).window = saved; dom.window.close(); }
});

test('checked restart flush restores current split geometry, aux tabs and chrome through normal hydration', () => {
  const dom = new JSDOM('', { url: 'https://hub.example/' });
  const saved = (globalThis as any).window; (globalThis as any).window = dom.window;
  try {
    const tree = buildDefaultSplitTree(['inst_a', 'inst_b']);
    const aux = { agentPanes: { inst_a: { tabs: [], activeTabId: 'overview' } } };
    flushWorkspaceForDesktopUpdate(tree, aux, 420);
    assert.deepEqual(loadSavedLayout(['inst_a', 'inst_b']), tree);
    assert.deepEqual(readGroupIndex(), [['inst_a', 'inst_b']]);
    assert.deepEqual(readAuxPanesState(), aux); assert.deepEqual(readWorkspaceChromeState(), { auxWidth: 420 });
    Object.defineProperty(dom.window, 'localStorage', { value: { setItem() { throw new Error('storage full'); } } });
    assert.throws(() => flushWorkspaceForDesktopUpdate(tree, aux, 421), /storage full/);
    assert.throws(() => writeComposerDraftChecked('inst_a', 'unsaved'), /storage full/);
  } finally { (globalThis as any).window = saved; dom.window.close(); }
});
