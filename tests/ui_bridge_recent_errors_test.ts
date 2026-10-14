// Bridge "Recent errors" card (bridge_logs plan v2 §4.4): pure presentation
// helpers + a server render of the hook-free list.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_bridge_recent_errors_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';

import {
  BRIDGE_EVENT_SKEW_MS,
  bridgeEventDisplayTime,
  bridgeEventLevelTone,
  formatBridgeEventFields,
  formatRelativeTime,
} from '../src/ui/components/settings/bridgeEvents.ts';
import { normalizeBridgeEventsPage } from '../src/ui/api/endpoints/bridgeSupport.ts';
import { BridgeRecentErrorsList } from '../src/ui/components/settings/BridgeRecentErrorsCard.tsx';

const NOW = 1_700_000_000_000;

test('formatRelativeTime buckets seconds/minutes/hours/days and never goes negative', () => {
  assert.equal(formatRelativeTime(NOW - 10_000, NOW), 'just now');
  assert.equal(formatRelativeTime(NOW - 3 * 60_000, NOW), '3 m ago');
  assert.equal(formatRelativeTime(NOW - 2 * 3_600_000, NOW), '2 h ago');
  assert.equal(formatRelativeTime(NOW - 5 * 86_400_000, NOW), '5 d ago');
  assert.equal(formatRelativeTime(NOW + 60_000, NOW), 'just now', 'future timestamps clamp to now');
  assert.equal(formatRelativeTime(0, NOW), '—');
});

test('bridgeEventDisplayTime prefers the bridge clock unless it is skewed > 5 min', () => {
  assert.equal(bridgeEventDisplayTime({ ts_ms: NOW - 1000, received_at: NOW }), NOW - 1000);
  assert.equal(bridgeEventDisplayTime({ ts_ms: NOW - BRIDGE_EVENT_SKEW_MS - 1, received_at: NOW }), NOW);
  assert.equal(bridgeEventDisplayTime({ ts_ms: 0, received_at: NOW }), NOW);
  assert.equal(bridgeEventLevelTone('error'), 'danger');
  assert.equal(bridgeEventLevelTone('warn'), 'warning');
  assert.equal(formatBridgeEventFields({ provider: 'claude', exit_code: 1 }), 'provider=claude, exit_code=1');
  assert.equal(formatBridgeEventFields(undefined), '');
});

test('normalizeBridgeEventsPage tolerates a sparse payload', () => {
  const page = normalizeBridgeEventsPage({ bridge_id: 'brg_1', events: [{ id: 7, code: 'provider_missing', message: 'm', level: 'error' }], has_more: true, next_before_id: 7 });
  assert.equal(page.events.length, 1);
  assert.equal(page.events[0].count, 1);
  assert.deepEqual(page.events[0].fields, {});
  assert.equal(page.has_more, true);
  assert.equal(page.next_before_id, 7);
  const empty = normalizeBridgeEventsPage(null);
  assert.deepEqual(empty.events, []);
});

test('BridgeRecentErrorsList renders level badge, message, code chip, ×count and relative time', () => {
  const html = renderToStaticMarkup(
    React.createElement(BridgeRecentErrorsList, {
      bridgeId: 'brg_1',
      now: NOW,
      events: [
        { id: 2, ts_ms: NOW - 120_000, received_at: NOW - 119_000, level: 'error', code: 'provider_missing', fields: { provider: 'claude' }, count: 3, message: 'Provider CLI is not installed or has no runnable command (provider: claude)' },
        { id: 1, ts_ms: NOW - 3 * 3_600_000, received_at: NOW - 3 * 3_600_000, level: 'warn', code: 'hub_ws_closed', fields: { reason: 'eof' }, count: 1, message: 'Connection to the hub closed; reconnecting (reason: eof)' },
      ],
    }),
  );
  assert.match(html, /data-debug-id="settings-bridge-errors-list-brg_1"/);
  assert.match(html, /data-debug-id="settings-bridge-error-level-brg_1-2"[^>]*>error</);
  assert.match(html, /Provider CLI is not installed or has no runnable command \(provider: claude\)/);
  assert.match(html, /data-debug-id="settings-bridge-error-code-brg_1-2"[^>]*>provider_missing</);
  assert.match(html, /data-debug-id="settings-bridge-error-count-brg_1-2"[^>]*>×3</);
  assert.match(html, /data-debug-id="settings-bridge-error-time-brg_1-2"[^>]*>2 m ago</);
  assert.match(html, /data-debug-id="settings-bridge-error-time-brg_1-1"[^>]*>3 h ago</);
  assert.doesNotMatch(html, /settings-bridge-error-count-brg_1-1/, 'count 1 shows no ×count');
  assert.match(html, /title="provider=claude"/);

  const empty = renderToStaticMarkup(React.createElement(BridgeRecentErrorsList, { bridgeId: 'brg_1', events: [], now: NOW }));
  assert.match(empty, /settings-bridge-errors-empty-brg_1/);
  assert.match(empty, /No warnings or errors reported\./);
});
