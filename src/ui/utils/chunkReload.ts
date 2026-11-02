// REQ-UI-CHUNK-RELOAD-1: recover from a lazily loaded chunk that no longer exists.
//
// Every page is a `React.lazy` import of a content-hashed file under `assets/`. A
// deploy replaces those names, so a document loaded before the deploy (most often
// the long-lived desktop window) asks for an old file on its first visit to a page
// and gets the SPA's index.html back. Reloading picks up the current index.html
// and its current chunk names.
//
// Guards: never reload while offline (Electron would replace the contained error
// with a blank network-error page), and at most once per RELOAD_GUARD_MS so a
// chunk that is missing even after a reload falls back to the ErrorBoundary
// instead of looping. Without sessionStorage there is no loop guard, so no reload.

export const CHUNK_RELOAD_STAMP_KEY = 'heimdall:chunk-reload-at';
export const RELOAD_GUARD_MS = 30_000;

type ChunkReloadWindow = {
  navigator: { onLine: boolean };
  sessionStorage: Pick<Storage, 'getItem' | 'setItem'>;
  location: { reload(): void };
  addEventListener(type: string, listener: (event: Event) => void): void;
};

const CHUNK_ERROR_PATTERNS = [
  /Failed to fetch dynamically imported module/i, // Chromium / Electron
  /error loading dynamically imported module/i, // Firefox
  /Importing a module script failed/i, // Safari
  /Unable to preload CSS/i, // Vite's CSS preload helper
  /is not a valid JavaScript MIME type/i, // an old chunk answered with index.html
];

export function isChunkLoadError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : typeof error === 'string' ? error : '';
  return CHUNK_ERROR_PATTERNS.some((pattern) => pattern.test(message));
}

/** Reloads the document unless offline or a reload already happened within the guard window. */
export function tryChunkReload(win: ChunkReloadWindow, now: number = Date.now()): boolean {
  if (!win.navigator.onLine) return false;
  try {
    const last = Number(win.sessionStorage.getItem(CHUNK_RELOAD_STAMP_KEY)) || 0;
    if (now - last < RELOAD_GUARD_MS) return false;
    win.sessionStorage.setItem(CHUNK_RELOAD_STAMP_KEY, String(now));
  } catch (_err) {
    return false;
  }
  win.location.reload();
  return true;
}

/**
 * Vite dispatches `vite:preloadError` when a lazy import (or its CSS) fails. The
 * event is deliberately not cancelled: the original error still reaches the
 * ErrorBoundary, which stays as the fallback if no reload happens.
 */
export function installChunkReloadRecovery(win: ChunkReloadWindow): void {
  win.addEventListener('vite:preloadError', () => {
    tryChunkReload(win);
  });
}
