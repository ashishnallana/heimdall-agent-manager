// REQ-ERR-PROTO-A: the UI reads the shared wire error ({code, class, cause, message})
// from hub error envelopes and words a failed agent by its class.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_wire_error_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ApiError, cookieJsonFetch } from '../src/ui/api/cookieFetch.ts';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { agentFailureSummary } from '../src/ui/utils/agentStatus.ts';
import { AgentFailureNotice } from '../src/ui/components/agents/AgentFailureNotice.tsx';

test('ApiError carries the envelope code, class and cause', async () => {
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async () => new Response(
    JSON.stringify({ error: { code: 'provider_unavailable', class: 'recoverable', cause: 'provider_not_logged_in', message: 'log in', details: {} }, meta: {} }),
    { status: 503 },
  )) as typeof fetch;
  try {
    await assert.rejects(cookieJsonFetch('/x'), (err: unknown) => {
      assert.ok(err instanceof ApiError);
      assert.equal(err.status, 503);
      assert.equal(err.code, 'provider_unavailable');
      assert.equal(err.errorClass, 'recoverable');
      assert.equal(err.errorCause, 'provider_not_logged_in');
      assert.equal(err.message, 'log in');
      return true;
    });
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('agentFailureSummary words the failure by class', () => {
  assert.equal(agentFailureSummary(null), null);
  const recoverable = agentFailureSummary({ code: 'provider_unavailable', class: 'recoverable', cause: 'provider_not_logged_in', message: '' });
  assert.deepEqual(recoverable, { label: 'Needs attention', detail: 'provider not logged in', tone: 'warning' });
  const retriable = agentFailureSummary({ code: 'bridge_busy', class: 'retriable', cause: 'pty_host_unreachable', message: 'daemon unavailable' });
  assert.equal(retriable?.label, 'Retrying automatically');
  assert.equal(retriable?.detail, 'pty host unreachable: daemon unavailable');
  const fatal = agentFailureSummary({ code: 'internal_error', class: 'fatal', cause: 'agent_launch_failed', message: '' });
  assert.equal(fatal?.label, 'Failed');
  assert.equal(fatal?.tone, 'danger');
});

test('AgentDetail renders a failed instance by its error class', () => {
  const render = (runtimeStatus: string, lastError: unknown) =>
    renderToStaticMarkup(React.createElement(AgentFailureNotice, { runtimeStatus, lastError }));
  const missingProvider = { code: 'provider_unavailable', class: 'recoverable', cause: 'provider_missing', message: 'claude not on PATH' };
  const html = render('failed', missingProvider);
  assert.match(html, /data-debug-id="live-instance-last-error"/);
  assert.match(html, /Needs attention: provider missing: claude not on PATH/);
  assert.match(render('failed', { code: 'bridge_busy', class: 'retriable', cause: 'pty_host_unreachable', message: '' }), /Retrying automatically: pty host unreachable/);
  assert.match(render('failed', { code: 'unprocessable_entity', class: 'fatal', cause: 'agent_bootstrap_invalid', message: '' }), /Failed: agent bootstrap invalid/);
  // Nothing for a healthy instance or a failure with no typed error.
  assert.equal(render('running', missingProvider), '');
  assert.equal(render('failed', null), '');
});
