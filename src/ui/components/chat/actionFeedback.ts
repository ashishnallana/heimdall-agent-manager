/**
 * Feedback sent to the agent when the user resolves an in-chat action card. The card id
 * stays in the text so the agent can correlate it; `title` must already be plaintext
 * (see resolveCardTitle) because the body is re-encrypted on send.
 */
export function buildActionFeedback(
  verdict: 'approved' | 'rejected',
  actionId: string,
  title: string,
  comment = '',
): string {
  const tag = verdict === 'approved' ? '[Action Approved]' : '[Action Rejected]';
  const base = `${tag} Action ${actionId} (${title}) was ${verdict} by user`;
  const reason = comment.trim();
  return reason ? `${base}: ${reason}` : base;
}
