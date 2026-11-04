// REQ-UI-CHUNK-RELOAD-1: a stale lazy chunk reloads the document once, never while
// offline and never in a loop (src/ui/utils/chunkReload.ts, installed by
// src/ui/main.tsx and used by components/shell/ErrorBoundary.tsx).
//
// RUN: node --test tests/ui_chunk_reload_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  CHUNK_RELOAD_STAMP_KEY,
  RELOAD_GUARD_MS,
  installChunkReloadRecovery,
  isChunkLoadError,
  tryChunkReload,
} from '../src/ui/utils/chunkReload.ts';

function fakeWindow({ onLine = true, storageThrows = false } = {}) {
  const store = new Map<string, string>();
  const listeners = new Map<string, (event: Event) => void>();
  const win = {
    reloads: 0,
    store,
    listeners,
    navigator: { onLine },
    sessionStorage: {
      getItem: (key: string) => {
        if (storageThrows) throw new Error('blocked');
        return store.get(key) ?? null;
      },
      setItem: (key: string, value: string) => {
        if (storageThrows) throw new Error('blocked');
        store.set(key, value);
      },
    },
    location: { reload: () => { win.reloads += 1; } },
    addEventListener: (type: string, listener: (event: Event) => void) => { listeners.set(type, listener); },
  };
  return win;
}

test('recognises chunk-load failures from each engine and nothing else', () => {
  assert.ok(isChunkLoadError(new TypeError('Failed to fetch dynamically imported module: https://web.ninjy.ai/assets/ProjectListPage-CMUA-wr0.js')));
  assert.ok(isChunkLoadError(new TypeError('error loading dynamically imported module: https://x/assets/a.js')));
  assert.ok(isChunkLoadError(new TypeError('Importing a module script failed.')));
  assert.ok(isChunkLoadError(new Error('Unable to preload CSS for /assets/a.css')));
  assert.ok(isChunkLoadError(new TypeError("Failed to load module script: Expected a JavaScript module script but the server responded with a MIME type of \"text/html\". Strict MIME type checking is enforced for module scripts per HTML spec. 'text/html' is not a valid JavaScript MIME type.")));
  assert.equal(isChunkLoadError(new Error('Objects are not valid as a React child')), false);
  assert.equal(isChunkLoadError(null), false);
});

test('reloads once, then not again inside the guard window', () => {
  const win = fakeWindow();
  assert.equal(tryChunkReload(win, 1_000_000), true);
  assert.equal(win.reloads, 1);
  assert.equal(win.store.get(CHUNK_RELOAD_STAMP_KEY), '1000000');
  assert.equal(tryChunkReload(win, 1_000_000 + RELOAD_GUARD_MS - 1), false);
  assert.equal(win.reloads, 1);
  assert.equal(tryChunkReload(win, 1_000_000 + RELOAD_GUARD_MS), true);
  assert.equal(win.reloads, 2);
});

test('never reloads while offline or without sessionStorage', () => {
  const offline = fakeWindow({ onLine: false });
  assert.equal(tryChunkReload(offline, 1_000_000), false);
  assert.equal(offline.reloads, 0);
  const blocked = fakeWindow({ storageThrows: true });
  assert.equal(tryChunkReload(blocked, 1_000_000), false);
  assert.equal(blocked.reloads, 0);
});

test('vite:preloadError triggers the guarded reload without cancelling the event', () => {
  const win = fakeWindow();
  installChunkReloadRecovery(win);
  const listener = win.listeners.get('vite:preloadError');
  assert.ok(listener);
  const event = new Event('vite:preloadError', { cancelable: true });
  listener(event);
  assert.equal(win.reloads, 1);
  assert.equal(event.defaultPrevented, false);
  listener(new Event('vite:preloadError', { cancelable: true }));
  assert.equal(win.reloads, 1);
});
