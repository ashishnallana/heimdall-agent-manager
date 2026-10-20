import { buildRouteHash } from './appLocation';

/**
 * Conversation URL model (Jetski `jetskiAgent/routing/conversationUrl.ts`).
 *
 * The URL encodes the OPEN PANE SET of the Main workspace:
 *
 *   #/conversations/<id1>+<id2>+...?focused=<id>
 *
 * A single view is the one-id case (`#/conversations/<id>`, the legacy URL
 * shape keeps working). `_new` marks a new-chat picker pane and may repeat.
 * `?msg=<messageId>` (deep-link to a message) is preserved by callers that
 * need it; layout pushes drop it.
 */

export const NEW_PANE_URL_ID = '_new';

export interface ResolvedConversationIds {
  ids: string[];
  focused?: string;
}

function safeDecode(segment: string): string {
  try {
    return decodeURIComponent(segment);
  } catch {
    // Malformed percent-encoding: fall back to the raw segment.
    return segment;
  }
}

/** Raw (still percent-encoded) id list segment of a conversation route, or null. */
export function conversationIdsSegment(pathname: string): string | null {
  const match =
    typeof pathname === 'string' ? pathname.match(/^\/(?:conversations|c)\/([^/]+)\/?$/) : null;
  if (!match) return null;
  if (match[1] === 'new') return null; // `/conversations/new` is the launch page
  return match[1];
}

/**
 * Parses the pane set from a route. Ids are de-duplicated except `_new`
 * placeholders (distinct empty panes); `focused` always names one of the ids
 * (else ids[0]) and is undefined when there are no ids.
 */
export function parseConversationIdsFromRoute(
  pathname: string,
  search: string | Record<string, string> = '',
): ResolvedConversationIds {
  const params =
    typeof search === 'string'
      ? new URLSearchParams(search.startsWith('?') ? search.slice(1) : search)
      : new URLSearchParams(search);
  const segment = conversationIdsSegment(pathname);
  const raw = segment ? segment.split('+').map(safeDecode).map((s) => s.trim()).filter(Boolean) : [];
  const ids: string[] = [];
  const seen = new Set<string>();
  for (const id of raw) {
    if (id === NEW_PANE_URL_ID) {
      ids.push(id);
    } else if (!seen.has(id)) {
      seen.add(id);
      ids.push(id);
    }
  }
  let focused: string | undefined = params.get('focused') || undefined;
  if (ids.length === 0) focused = undefined;
  else if (!focused || !ids.includes(focused)) focused = ids[0];
  return { ids, focused };
}

/**
 * Builds the `#`-prefixed hash for a pane set. A single view omits `focused`
 * (canonical legacy shape); split views always carry it.
 */
export function buildConversationHash(
  ids: string[],
  options: { focusedId?: string; extraSearch?: Record<string, string> } = {},
): string {
  const list = ids.length > 0 ? ids : [NEW_PANE_URL_ID];
  const path = `/conversations/${list.map((id) => encodeURIComponent(id)).join('+')}`;
  const params = new URLSearchParams();
  if (list.length > 1) {
    const focused = options.focusedId && list.includes(options.focusedId) ? options.focusedId : list[0];
    params.set('focused', focused);
  }
  for (const [k, v] of Object.entries(options.extraSearch || {})) {
    if (v) params.set(k, v);
  }
  const search = params.toString();
  return buildRouteHash(path, search ? `?${search}` : '');
}

/** Stable comparison key for an id list + focus. */
export function conversationUrlKey(ids: string[], focused?: string): string {
  return `${ids.join('+')}|${focused ?? ''}`;
}

/** Pushes a new hash (history entry). */
export function navigateToHash(hash: string): void {
  if (typeof window === 'undefined') return;
  window.location.hash = hash.startsWith('#') ? hash.slice(1) : hash;
}

/**
 * Replaces the current hash without adding a history entry (Jetski
 * `navigate({replace: true})`), and notifies hash listeners.
 */
export function replaceHash(hash: string): void {
  if (typeof window === 'undefined') return;
  const target = hash.startsWith('#') ? hash : `#${hash}`;
  if (window.location.hash === target) return;
  try {
    window.history.replaceState(window.history.state, '', target);
    // Use the window's own Event constructor (realm-safe, e.g. under jsdom).
    const EventCtor: typeof Event = (window as any).Event || Event;
    window.dispatchEvent(new EventCtor('hashchange'));
  } catch {
    window.location.replace(target);
  }
}
