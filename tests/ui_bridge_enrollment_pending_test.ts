// REQ-EA-1/2/6: the browser half of atomic bridge enrollment — the API calls the
// approval page and Settings make against a pending enrollment. (Key delivery to the
// enrolling process is covered in ui_vault_bridge_delivery_test.ts.)
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_bridge_enrollment_pending_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';

test('REQ-ENROLL-PENDING: Settings discovers a later replacement and cancels it', async () => {
  const { default: Card } = await import('../src/ui/components/settings/PendingEnrollmentsCard.tsx');
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://hub.example.test/' });
  const saved = new Map<string, PropertyDescriptor | undefined>();
  for (const [key, value] of Object.entries({ window: dom.window, document: dom.window.document,
    HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true })) {
    saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
  }
  const original = { fetch: globalThis.fetch, setInterval: globalThis.setInterval, clearInterval: globalThis.clearInterval };
  let poll: (() => void) | undefined;
  let cleared = false;
  globalThis.setInterval = ((fn: () => void, ms: number) => { assert.equal(ms, 10_000); poll = fn; return 123; }) as any;
  globalThis.clearInterval = ((id: any) => { assert.equal(id, 123); cleared = true; }) as any;
  let pending = false;
  const mutations: string[] = [];
  globalThis.fetch = (async (url: any, init: any = {}) => {
    if (init.method === 'POST') {
      mutations.push(String(url)); pending = false;
      return json({ data: { rolled_back: true } });
    }
    return json({ data: pending ? [{ bridge_id: 'brg_replace', label: 'Desktop', status: 'online',
      enrollment_state: 'enrolled', enrollment_in_progress: true }] : [] });
  }) as any;
  const root = createRoot(dom.window.document.getElementById('root')!);
  try {
    await act(async () => { root.render(React.createElement(Card)); });
    assert.equal(dom.window.document.querySelector('button'), null);
    assert.ok(poll, 'polling continues from an empty list');
    pending = true;
    await act(async () => { poll!(); });
    const cancel = dom.window.document.querySelector('[data-debug-id="settings-bridge-pending-cancel-brg_replace"]') as HTMLButtonElement;
    assert.ok(cancel, 'an online bridge replacement offers cancellation');
    await act(async () => { cancel.click(); });
    assert.deepEqual(mutations, ['/api/v1/bridges/brg_replace/enrollment/cancel']);
    assert.equal(dom.window.document.querySelector('button'), null, 'cancelled replacement disappears');
  } finally {
    await act(async () => root.unmount());
    assert.ok(cleared, 'unmount stops polling');
    Object.assign(globalThis, original);
    dom.window.close();
    for (const [key, descriptor] of saved) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete (globalThis as any)[key];
    }
  }
});

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
}

test('REQ-ENROLL-PENDING: cancellation aborts an in-flight approval wait without retrying', async () => {
  const { waitForEnrollingBridge } = await import('../src/ui/components/devices/DeviceApprovalPage.tsx');
  const realFetch = globalThis.fetch;
  const controller = new AbortController();
  let requests = 0;
  let announceStarted!: () => void;
  const started = new Promise<void>((resolve) => { announceStarted = resolve; });
  globalThis.fetch = ((_url: any, init: any) => {
    requests++;
    return new Promise((_resolve, reject) => {
      init.signal.addEventListener('abort', () => reject(init.signal.reason), { once: true });
      announceStarted();
    });
  }) as any;
  try {
    const waiting = waitForEnrollingBridge('brg_replace', () => assert.fail('cancelled wait must not advance'), controller.signal);
    const rejected = assert.rejects(waiting, /enrollment cancelled/);
    await started;
    controller.abort(new Error('enrollment cancelled'));
    await rejected;
    assert.equal(requests, 1, 'aborted requests are not treated as transient failures');
  } finally {
    globalThis.fetch = realFetch;
  }
});

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
        { bridge_id: 'brg_replace', enrollment_state: 'enrolled', enrollment_in_progress: true, status: 'online', label: 'desktop' },
        { bridge_id: 'brg_new', enrollment_state: 'pending', label: 'laptop', machine_hostname: 'lap', enrollment_pending_until: '2026-10-16T15:05:00Z' },
      ] });
    }) as any;
    const rows = await fetchPendingBridgeEnrollments();
    assert.match(calls[0], /\/bridges\?include_pending=1$/, 'only Settings asks for pending rows');
    assert.deepEqual(rows.map((r) => r.bridge_id), ['brg_replace', 'brg_new']);
    assert.equal(rows[1].label, 'laptop');
    assert.equal(rows[0].replacing, true, 'replacements do not consume another bridge slot');
    assert.equal(rows[1].replacing, false);
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
