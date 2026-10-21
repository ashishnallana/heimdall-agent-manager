// Shared between the user-WS consumer (wsInvalidation.ts) and the conversation pane
// (AgentChatPane), which keeps older message pages in component state rather than in a
// mounted RTK entry.

// ---- Originating-tab echo -------------------------------------------------------
// A send from this tab already invalidates its conversation through the mutation's
// invalidatesTags. The hub then announces the same message to every owner socket,
// this one included; refetching again for that echo is a duplicate same-key request.
// Other tabs never noted the id, so they still fetch.
const LOCAL_ECHO_TTL_MS = 60_000;
const localMessageIds = new Map<string, number>();

export function noteLocalMessageSent(messageId: string, now = Date.now()): void {
  if (!messageId) return;
  for (const [id, at] of localMessageIds) {
    if (now - at > LOCAL_ECHO_TTL_MS) localMessageIds.delete(id);
  }
  localMessageIds.set(messageId, now);
}

// True once per noted id: the first echo is consumed, so a later genuine change to the
// same message (not produced today) would still refresh.
export function consumeLocalMessageEcho(messageId: string, now = Date.now()): boolean {
  const at = localMessageIds.get(messageId);
  if (at === undefined) return false;
  localMessageIds.delete(messageId);
  return now - at <= LOCAL_ECHO_TTL_MS;
}

export function resetLocalMessageEchoes(): void {
  localMessageIds.clear();
}

// ---- Read receipts --------------------------------------------------------------
// messages_read carries the committed read_at and the ids it marked (capped at 200 by
// the producer). RTK message pages are patched directly; this window event reaches the
// pane's older pages held in state.
export const CONVERSATION_MESSAGES_READ_EVENT = 'heimdall:conversation-messages-read';

export type ConversationMessagesRead = {
  conversationId: string;
  messageIds: string[];
  readAt: string;
};

// Returns the same array when nothing changed so React state setters can bail out.
export function applyReadReceipt<T extends Record<string, any>>(rows: T[], receipt: ConversationMessagesRead): T[] {
  if (!receipt.readAt || receipt.messageIds.length === 0) return rows;
  const ids = new Set(receipt.messageIds);
  let changed = false;
  const next = rows.map((row) => {
    const id = String(row?.message_id ?? row?.id ?? '');
    if (!ids.has(id)) return row;
    const current = String(row?.read_at ?? '');
    if (current && current >= receipt.readAt) return row;
    changed = true;
    return { ...row, read_at: receipt.readAt };
  });
  return changed ? next : rows;
}

// In-place variant for immer drafts.
export function applyReadReceiptToDraft(rows: any[] | undefined, receipt: ConversationMessagesRead): void {
  if (!Array.isArray(rows) || !receipt.readAt) return;
  const ids = new Set(receipt.messageIds);
  for (const row of rows) {
    const id = String(row?.message_id ?? row?.id ?? '');
    if (!ids.has(id)) continue;
    const current = String(row?.read_at ?? '');
    if (!current || current < receipt.readAt) row.read_at = receipt.readAt;
  }
}

export function announceConversationMessagesRead(receipt: ConversationMessagesRead): void {
  if (typeof window === 'undefined' || typeof window.dispatchEvent !== 'function') return;
  try {
    window.dispatchEvent(new CustomEvent(CONVERSATION_MESSAGES_READ_EVENT, { detail: receipt }));
  } catch {
    /* a missing CustomEvent (old test env) must not break cache patching */
  }
}

// ---- Newest page refetch vs loaded older pages ------------------------------------
// The pane keeps older pages (fetched from the PREVIOUS newest page's cursor) in state
// and renders [...older, ...newest] sorted by time. When the newest page is refetched
// after k new messages, its k oldest rows slide out of it:
// - some overlap (k < page): carry the rows that slid out into the older pages, so the
//   transcript stays contiguous;
// - no overlap (k >= page): the older pages no longer join the newest one; drop them
//   and page back from the new newest page (reanchor) rather than render a hole.
// Rows without an id cannot be matched and are not carried.
export type OlderPagesReconcile<T> = { older: T[]; reanchor: boolean };

export function reconcileOlderPages<T extends Record<string, any>>(
  previousBase: T[],
  nextBase: T[],
  older: T[],
  idOf: (row: T) => string,
): OlderPagesReconcile<T> {
  if (older.length === 0 || previousBase.length === 0 || nextBase.length === 0) return { older, reanchor: false };
  const nextIds = new Set(nextBase.map(idOf).filter(Boolean));
  if (!previousBase.some((row) => nextIds.has(idOf(row)))) return { older: [], reanchor: true };
  const olderIds = new Set(older.map(idOf).filter(Boolean));
  const slid = previousBase.filter((row) => {
    const id = idOf(row);
    return id && !nextIds.has(id) && !olderIds.has(id);
  });
  return { older: slid.length > 0 ? [...slid, ...older] : older, reanchor: false };
}
