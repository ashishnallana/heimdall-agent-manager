// Hidden-pane refresh deferral. A conversation pane stays MOUNTED while the layout
// hides it (paneVisibility.tsx), so its newest-messages query (Chat:<conversation>,
// subscribed only by AgentChatPane) kept refetching on every message event although
// nobody could see it. Panes register their conversation and visibility here; a
// Chat:<conversation> invalidation whose panes are ALL hidden is recorded as dirty
// instead of dispatched, and the first pane to become visible refetches it once.
//
// Only that tag is deferred: sidebar rows/unread badges, the conversation header and
// instance state still refresh immediately, so unread counts stay correct. Mark-read
// stays gated on visibility (paneShouldMarkRead), so a deferred pane never clears
// unread for messages it has not loaded.

type PaneEntry = { conversationId: string; visible: boolean };

const panes = new Map<number, PaneEntry>();
const dirty = new Set<string>();
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
  const entry = panes.get(id);
  panes.delete(id);
  // The last pane went away: nothing needs the deferred refresh any more, and a
  // remount fetches anyway (refetchOnMountOrArgChange / cache expiry).
  if (entry && !hasPane(entry.conversationId)) dirty.delete(entry.conversationId);
}

function hasPane(conversationId: string): boolean {
  for (const entry of panes.values()) if (entry.conversationId === conversationId) return true;
  return false;
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

/** Called at flush time: true when the tag was recorded as dirty instead of sent. */
export function deferIfHidden(tag: { type: string; id: string }): boolean {
  if (tag.type !== 'Chat' || !tag.id || !allPanesHidden(tag.id)) return false;
  dirty.add(tag.id);
  return true;
}

/** A pane became visible: returns true (once) when its conversation missed a refresh. */
export function takeDirty(conversationId: string): boolean {
  return dirty.delete(conversationId);
}

export function isDirty(conversationId: string): boolean {
  return dirty.has(conversationId);
}

// Tests and teardown.
export function resetPaneDeferral(): void {
  panes.clear();
  dirty.clear();
  nextPaneId = 1;
}
