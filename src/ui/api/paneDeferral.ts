// Hidden-pane refresh deferral. A conversation pane stays MOUNTED while the layout
// hides it (paneVisibility.tsx), so its newest-messages query (Chat:<conversation>,
// subscribed only by AgentChatPane) kept refetching on every message event although
// nobody could see it. Panes register their conversation and visibility here; a
// Chat:<conversation> invalidation whose panes are ALL hidden is recorded as dirty
// instead of dispatched, and the first pane to become visible refetches it once.
//
// Only that tag is deferred: sidebar rows/unread badges, the conversation header and
// instance state still refresh immediately, so unread counts stay correct. Mark-read
// stays gated on visibility (paneShouldMarkRead); on show it fires together with the
// deferred refetch, so the new message renders a moment after the badge clears.
//
// A dirty mark outlives the pane: the newest page stays cached (keepUnusedDataFor) and
// a remount does not refetch it, so a pane that later shows the conversation again
// refetches once. Nothing is dropped.
//
// A mark is cleared only by a response to a request that STARTED after it. The mark
// records the requestId of every cached Chat:<conversation> entry at that moment (RTK
// keeps the latest request's id per entry, pending or settled). A request that was
// already in flight when the event arrived carries a pre-event snapshot, and RTK drops
// a refetch while it is pending, so consuming the mark on show lost the message until
// the next event or cache expiry. Now the pane waits for that request to settle and
// then refetches once; whatever settles with a newer requestId (success or error)
// spends the mark, so it cannot loop. requestIds, not timestamps: they never collide.
//
// Owner-specific: cleared on every API reset (user switch, vault lock/unlock), see
// paneDeferralResetMiddleware in wsInvalidation.ts.

import { heimdallApi } from './heimdallApi';

type PaneEntry = { conversationId: string; visible: boolean };
// null: the store was not readable when the mark was made (a bare dispatch in tests);
// the pane's current page is then taken as the stale one when it next looks.
type DirtyMark = { staleRequestIds: Set<string> | null };

const panes = new Map<number, PaneEntry>();
const dirty = new Map<string, DirtyMark>();
let nextPaneId = 1;

export function registerPane(conversationId: string, visible: boolean): number {
  const id = nextPaneId++;
  panes.set(id, { conversationId, visible });
  return id;
}

export function updatePane(id: number, conversationId: string, visible: boolean): void {
  panes.set(id, { conversationId, visible });
}

export function unregisterPane(id: number): void {
  // The dirty mark is kept (see above): the cached page is still stale.
  panes.delete(id);
}

/** Every mounted pane for the conversation is hidden (and there is at least one). */
export function allPanesHidden(conversationId: string): boolean {
  let seen = false;
  for (const entry of panes.values()) {
    if (entry.conversationId !== conversationId) continue;
    if (entry.visible) return false;
    seen = true;
  }
  return seen;
}

// requestId of the latest request (pending or settled) of every cache entry for the
// conversation's newest page. Tags are only provided once a request fulfils, so a first
// request still pending is found by endpoint and arguments as well.
function currentRequestIds(state: any, conversationId: string): Set<string> {
  const ids = new Set<string>();
  const queries = state?.[heimdallApi.reducerPath]?.queries || {};
  const keys = new Set<string>();
  for (const { queryCacheKey } of heimdallApi.util.selectInvalidatedBy(state, [{ type: 'Chat', id: conversationId }])) {
    keys.add(queryCacheKey);
  }
  for (const [key, entry] of Object.entries<any>(queries)) {
    const args = entry?.originalArgs;
    if (entry?.endpointName === 'fetchConversationMessages' && args?.conversationId === conversationId && !args?.cursor) keys.add(key);
  }
  for (const key of keys) {
    const requestId = queries[key]?.requestId;
    if (requestId) ids.add(requestId);
  }
  return ids;
}

/**
 * Called at flush time: true when the tag was recorded as dirty instead of sent.
 * `state` is the store state at that moment, used to tell pre-event requests apart.
 */
export function deferIfHidden(tag: { type: string; id: string }, state?: unknown): boolean {
  if (tag.type !== 'Chat' || !tag.id || !allPanesHidden(tag.id)) return false;
  const stale = state ? currentRequestIds(state, tag.id) : null;
  const mark = dirty.get(tag.id);
  if (!mark) dirty.set(tag.id, { staleRequestIds: stale });
  else if (mark.staleRequestIds && stale) for (const id of stale) mark.staleRequestIds.add(id);
  else mark.staleRequestIds = null;
  return true;
}

/**
 * A pane reports its newest-page request state (each render it changes). Returns true
 * when the pane must refetch now: its conversation is dirty, nothing is in flight, and
 * the page it holds came from a request older than the mark. A settled request newer
 * than the mark clears it, whether or not the pane is visible.
 */
export function needsCatchUp(
  conversationId: string,
  request: { requestId?: string; isFetching: boolean },
  visible: boolean,
): boolean {
  const mark = dirty.get(conversationId);
  // No request yet: the mount fetch about to start is newer than the mark.
  if (!mark || request.isFetching || !request.requestId) return false;
  if (!mark.staleRequestIds) mark.staleRequestIds = new Set([request.requestId]);
  if (!mark.staleRequestIds.has(request.requestId)) {
    dirty.delete(conversationId);
    return false;
  }
  return visible;
}

export function isDirty(conversationId: string): boolean {
  return dirty.has(conversationId);
}

/** API reset (user switch, vault lock): the marks belong to the previous cache owner. */
export function clearDirtyMarks(): void {
  dirty.clear();
}

// Tests and teardown.
export function resetPaneDeferral(): void {
  panes.clear();
  dirty.clear();
  nextPaneId = 1;
}
