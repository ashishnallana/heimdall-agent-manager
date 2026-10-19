// REQ-EA-1/2/6: the browser half of atomic bridge enrollment — the API calls the
// approval page and Settings make against a pending enrollment. (Key delivery to the
// enrolling process is covered in ui_vault_bridge_delivery_test.ts.)
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_bridge_enrollment_pending_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
}

test('REQ-EA-6: enrollment status is read per bridge, and a deleted row reads as null (rolled back)', async () => {
  const realFetch = globalThis.fetch;
  const calls: string[] = [];
  try {
    const { fetchBridgeEnrollmentStatus } = await import('../src/ui/api/endpoints/bridges.ts');
    globalThis.fetch = (async (url: any) => {
      calls.push(String(url));
      return json({ data: { bridge_id: 'brg_p', enrollment_state: 'pending', enroll_connected: true, enroll_public_key: '04ab', enrollment_pending_until: '2026-10-16T15:05:00Z', vault_status: '' } });
    }) as any;
    const status = await fetchBridgeEnrollmentStatus('brg_p');
    assert.equal(status?.enrollment_state, 'pending');
    assert.equal(status?.enroll_connected, true);
    assert.match(calls[0], /\/bridges\/brg_p\/enrollment$/);

    globalThis.fetch = (async () => json({ error: { message: 'bridge not found', code: 'not_found' } }, 404)) as any;
    assert.equal(await fetchBridgeEnrollmentStatus('brg_gone'), null, 'a 404 is the rolled-back answer, not an error');

    globalThis.fetch = (async () => json({ error: { message: 'boom' } }, 500)) as any;
    await assert.rejects(() => fetchBridgeEnrollmentStatus('brg_p'), 'any other failure is NOT a verdict');
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('REQ-EA-1: pending enrollments are fetched opt-in and filtered to pending rows', async () => {
  const realFetch = globalThis.fetch;
  const calls: string[] = [];
  try {
    const { fetchPendingBridgeEnrollments } = await import('../src/ui/api/endpoints/bridges.ts');
    globalThis.fetch = (async (url: any) => {
      calls.push(String(url));
      return json({ data: [
        { bridge_id: 'brg_live', enrollment_state: 'enrolled', status: 'online' },
        { bridge_id: 'brg_new', enrollment_state: 'pending', label: 'laptop', machine_hostname: 'lap', enrollment_pending_until: '2026-10-16T15:05:00Z' },
      ] });
    }) as any;
    const rows = await fetchPendingBridgeEnrollments();
    assert.match(calls[0], /\/bridges\?include_pending=1$/, 'only Settings asks for pending rows');
    assert.deepEqual(rows.map((r) => r.bridge_id), ['brg_new']);
    assert.equal(rows[0].label, 'laptop');
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('REQ-EA-3: cancel posts to the per-bridge cancel endpoint', async () => {
  const realFetch = globalThis.fetch;
  const calls: Array<{ url: string; method: string }> = [];
  try {
    const { cancelBridgeEnrollment } = await import('../src/ui/api/endpoints/bridges.ts');
    globalThis.fetch = (async (url: any, init: any) => {
      calls.push({ url: String(url), method: String(init?.method || 'GET') });
      return json({ data: { bridge_id: 'brg_p', rolled_back: true, row_deleted: true } });
    }) as any;
    assert.deepEqual(await cancelBridgeEnrollment('brg_p'), { rolledBack: true });
    assert.equal(calls.length, 1);
    assert.match(calls[0].url, /\/bridges\/brg_p\/enrollment\/cancel$/);
    assert.equal(calls[0].method, 'POST');

    // A commit that won the race: the Hub says so, and the caller must not report a rollback.
    globalThis.fetch = (async () => json({ data: { bridge_id: 'brg_p', rolled_back: false, committed: true, row_deleted: false } })) as any;
    assert.deepEqual(await cancelBridgeEnrollment('brg_p'), { rolledBack: false });
    // An older Hub without the field keeps the old meaning.
    globalThis.fetch = (async () => json({ data: { bridge_id: 'brg_p' } })) as any;
    assert.deepEqual(await cancelBridgeEnrollment('brg_p'), { rolledBack: true });
  } finally {
    globalThis.fetch = realFetch;
  }
});
