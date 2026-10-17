// Network calls for deferred attention actions. Plain JSON calls (no vault
// encryption needed), sent with fetch keepalive when flushing on page exit, which
// RTK mutations cannot do. Callers invalidate caches after success.
import { apiUrl } from '../../api/cookieFetch';
import type { AttentionTaskRefs } from '../../api/endpoints/attention';

async function send(path: string, method: string, body: unknown, keepalive: boolean): Promise<void> {
  const res = await fetch(apiUrl(path), {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body ?? {}),
    credentials: 'include',
    keepalive,
  });
  if (!res.ok) {
    let message = `Request failed (${res.status})`;
    try {
      const parsed = JSON.parse(await res.text());
      if (parsed?.error?.message) message = parsed.error.message;
    } catch { /* keep the status line */ }
    throw new Error(message);
  }
}

const enc = encodeURIComponent;

/**
 * Primary action: runs the card's operations. On a task card that is Approve
 * (task.review) or, with `{note}`, Answer (task.answer) — checked server-side
 * against the card's guard, so a stale card never acts on a newer attempt.
 */
export const acceptCard = (cardId: string, keepalive: boolean, body: { note?: string; expected_block?: string } = {}) =>
  send(`/cards/${enc(cardId)}/accept`, 'POST', body, keepalive);

/**
 * Rejects the card's source: a memory proposal is rejected; a task review card
 * becomes Request changes with `{summary}` (a gate re-plans with it).
 */
export const rejectCard = (cardId: string, keepalive: boolean, body: { summary?: string; findings?: unknown[] } = {}) =>
  send(`/cards/${enc(cardId)}/reject`, 'POST', body, keepalive);

export const snoozeCard = (cardId: string, until: string, keepalive: boolean) =>
  send(`/cards/${enc(cardId)}/snooze`, 'POST', { snooze_until: until }, keepalive);

export const cancelTask = (refs: AttentionTaskRefs, keepalive: boolean) =>
  send(`/task-chains/${enc(refs.chain_id)}/tasks/${enc(refs.task_id)}/cancel`, 'POST', {}, keepalive);

export const markConversationRead = (conversationId: string, keepalive: boolean) =>
  send(`/chats/${enc(conversationId)}/read`, 'POST', {}, keepalive);

/**
 * Hands the review to a durable agent: it becomes the task's named reviewer and
 * the user's approval is no longer required. Task System v2 re-gates the task on
 * that edit (stale review leases are replaced, the reviewer is matched), so no
 * separate reconcile is needed; the user's card retires server-side.
 */
export const assignReviewerAgent = async (refs: AttentionTaskRefs, agent: { agentId: string; displayName: string }, keepalive: boolean) => {
  await send(`/task-chains/${enc(refs.chain_id)}/tasks/${enc(refs.task_id)}`, 'PATCH', {
    reviewers: [agent.agentId],
    requires_user_approval: false,
  }, keepalive);
};
