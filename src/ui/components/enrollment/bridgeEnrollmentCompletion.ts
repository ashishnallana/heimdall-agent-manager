// Bridge enrollment state helpers for the device approval page (atomic enrollment,
// REQ-EA-6). The password-era delivery/restart helpers are gone.

/**
 * How long the page waits for the enrolling process to connect when the hub gave
 * no deadline. Matches the hub's BRIDGE_ENROLL_PENDING_SECONDS.
 */
export const ENROLLMENT_PENDING_FALLBACK_SECONDS = 300;

export type EnrollmentPendingOutcome = 'ready' | 'waiting' | 'rolled-back' | 'committed';

/**
 * Reads `GET /bridges/{id}/enrollment` for the approval page (REQ-EA-6).
 * `null` (the row is gone) and a past deadline both mean the hub rolled the
 * enrollment back; `enrolled` means it already committed (e.g. another tab).
 */
export function enrollmentPendingOutcome(
  status: { enrollment_state?: string; enroll_connected?: boolean; enrollment_pending_until?: string } | null,
  nowMs: number,
): EnrollmentPendingOutcome {
  if (!status) return 'rolled-back';
  if (status.enrollment_state === 'enrolled') return 'committed';
  const until = Date.parse(String(status.enrollment_pending_until || ''));
  if (Number.isFinite(until) && nowMs >= until) return 'rolled-back';
  return status.enroll_connected ? 'ready' : 'waiting';
}

