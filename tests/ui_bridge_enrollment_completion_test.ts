import { test } from 'node:test';
import assert from 'node:assert/strict';

import { ENROLLMENT_PENDING_FALLBACK_SECONDS, enrollmentPendingOutcome } from '../src/ui/components/enrollment/bridgeEnrollmentCompletion.ts';

test('REQ-EA-6: pending outcome reads the hub enrollment status, failing toward rolled back', () => {
  const now = Date.parse('2026-10-16T15:00:00Z');
  const future = '2026-10-16T15:04:00Z';
  const past = '2026-10-16T14:59:59Z';
  // The row is gone: a new bridge's rollback hard-deletes it.
  assert.equal(enrollmentPendingOutcome(null, now), 'rolled-back');
  assert.equal(enrollmentPendingOutcome({ enrollment_state: 'pending', enroll_connected: false, enrollment_pending_until: future }, now), 'waiting');
  assert.equal(enrollmentPendingOutcome({ enrollment_state: 'pending', enroll_connected: true, enrollment_pending_until: future }, now), 'ready');
  // Past the deadline the sweep rolls it back, even if the socket is still up.
  assert.equal(enrollmentPendingOutcome({ enrollment_state: 'pending', enroll_connected: true, enrollment_pending_until: past }, now), 'rolled-back');
  // An attach has no deadline on its row; the hub's family TTL governs it.
  assert.equal(enrollmentPendingOutcome({ enrollment_state: 'pending', enroll_connected: true, enrollment_pending_until: '' }, now), 'ready');
  assert.equal(enrollmentPendingOutcome({ enrollment_state: 'enrolled', enroll_connected: false }, now), 'committed');
  assert.equal(ENROLLMENT_PENDING_FALLBACK_SECONDS, 300);
});
