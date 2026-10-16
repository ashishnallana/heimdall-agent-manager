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

/** Primary task action: runs the card's operations (task.vote lgtm). */
export const acceptCard = (cardId: string, keepalive: boolean) => send(`/cards/${enc(cardId)}/accept`, 'POST', {}, keepalive);

export const snoozeCard = (cardId: string, until: string, keepalive: boolean) =>
  send(`/cards/${enc(cardId)}/snooze`, 'POST', { snooze_until: until }, keepalive);

export const cancelTask = (refs: AttentionTaskRefs, keepalive: boolean) =>
  send(`/task-chains/${enc(refs.chain_id)}/tasks/${enc(refs.task_id)}/cancel`, 'POST', {}, keepalive);

export const markConversationRead = (conversationId: string, keepalive: boolean) =>
  send(`/chats/${enc(conversationId)}/read`, 'POST', {}, keepalive);

/**
 * Hands the review to an agent: the agent becomes the reviewer instead of the
 * user, so the task no longer awaits the user and its card retires server-side.
 */
export const assignReviewerAgent = (refs: AttentionTaskRefs, agent: { agentId: string; displayName: string }, keepalive: boolean) =>
  send(`/task-chains/${enc(refs.chain_id)}/tasks/${enc(refs.task_id)}`, 'PATCH', {
    reviewer_refs: [{ type: 'agent_id', agent_id: agent.agentId, display_name: agent.displayName }],
    requires_user_approval: false,
  }, keepalive);
