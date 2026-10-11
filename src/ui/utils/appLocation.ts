// Hash-based routing location helpers.
//
// The desktop app is loaded in production via Electron `loadFile(index.html)` over
// `file://`. If the route lived in the real path (history/pushState to
// `/workspace/chains/X/tasks/Y`), a page refresh would ask Electron to load a
// non-existent file at that path and the window would come up blank -- this is the
// "refresh on the task view doesn't open" bug.
//
// Storing the route in the URL *hash* (`index.html#/workspace/chains/X/tasks/Y?...`)
// makes refresh always reload `index.html` (the part before `#`), while the hash is
// preserved so the app re-derives the same route. It also keeps relative asset URLs
// (`base: './'`) resolving against `index.html` at any route depth.
//
// Hash grammar: `#<pathname>[?<search>]`

function rawHash(): string {
  const hash = typeof window !== 'undefined' ? window.location.hash || '' : '';
  return hash.startsWith('#') ? hash.slice(1) : '';
}

// Route pathname (e.g. `/workspace/chains/c1/tasks/t2`). Falls back to the real
// document pathname on the very first load before any hash has been written.
export function getRoutePathname(): string {
  if (typeof window === 'undefined') return '/';
  const raw = rawHash();
  if (!raw) {
    const docPath = window.location.pathname || '/';
    if (docPath.includes('/preview/') || docPath.includes('/proxy/') || docPath.startsWith('/api/')) {
      return '/';
    }
    return docPath;
  }
  const qIndex = raw.indexOf('?');
  const path = qIndex >= 0 ? raw.slice(0, qIndex) : raw;
  if (!path) return '/';
  return path.startsWith('/') ? path : `/${path}`;
}

// Route search string including the leading `?` (e.g. `?memoryId=m1`). Falls back to
// the real document search on first load so existing `?view=...` deep links keep
// working before the app migrates them into the hash.
export function getRouteSearch(): string {
  if (typeof window === 'undefined') return '';
  const hash = window.location.hash || '';
  if (hash.startsWith('#')) {
    const raw = hash.slice(1);
    const qIndex = raw.indexOf('?');
    return qIndex >= 0 ? raw.slice(qIndex) : '';
  }
  return window.location.search || '';
}

// Build the `#`-prefixed URL fragment for pushState/replaceState.
export function buildRouteHash(pathname: string, search: string): string {
  const normalizedSearch = search && !search.startsWith('?') ? `?${search}` : search || '';
  const normalizedPath = pathname && pathname.startsWith('/') ? pathname : `/${pathname || ''}`;
  return `#${normalizedPath}${normalizedSearch}`;
}

// Path-form device routes that a direct document hit should land on. Matched as
// the trailing segments of the document path so a sub-path deployment still folds.
const LEGACY_DEVICE_ROUTE = /(\/device\/add|\/device\/providers(?:\/[^/]+)?)\/?$/;

// Legacy deep-link migration target: for a document opened at a real path-based
// route (an old `/workspace/...` bookmark, or a direct `/device/add?code=...` /
// `/device/providers[/<bridge>]` hit served by an SPA fallback) with no hash
// route, returns the `#`-prefixed hash that route belongs in. Returns null when
// the location is already hash-routed or is not a foldable route.
export function legacyPathRouteHash(pathname: string, search: string, hash: string): string | null {
  if (hash && hash.length > 1) return null; // already hash-routed
  if (!pathname) return null;
  const workspaceAt = pathname.indexOf('/workspace');
  if (workspaceAt >= 0) return buildRouteHash(pathname.slice(workspaceAt) || '/workspace', search);
  const device = LEGACY_DEVICE_ROUTE.exec(pathname);
  if (device) return buildRouteHash(device[1], search);
  return null;
}

export function navigateTo(href: string): void {
  window.location.hash = href.startsWith('#') ? href.slice(1) : href;
}
