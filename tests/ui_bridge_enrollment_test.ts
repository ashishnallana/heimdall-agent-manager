// REQ-BRG-1: Unit Tests for Bridge Readiness Badge and Pending Enrollment Ghosting Prevention
//
// RUN: node --test tests/ui_bridge_enrollment_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  bridgeReady,
  statusLabel,
} from '../src/ui/components/settings/bridgeEnrollment.ts';

test('statusLabel correctly extracts bridge status or defaults to offline', () => {
  assert.equal(statusLabel({ status: 'online' }), 'online');
  assert.equal(statusLabel({ runtime_status: 'online' }), 'online');
  assert.equal(statusLabel({ status: 'REVOKED' }), 'revoked');
  assert.equal(statusLabel({}), 'offline');
  assert.equal(statusLabel(null), 'offline');
});

test('bridgeReady returns true for online or connected bridges regardless of capabilities', () => {
  assert.equal(bridgeReady({ status: 'online' }), true);
  assert.equal(bridgeReady({ status: 'connected' }), true);
  assert.equal(bridgeReady({ runtime_status: 'online' }), true);

  assert.equal(bridgeReady({ status: 'online', capabilities: [] }), true);
  assert.equal(bridgeReady({ status: 'online', provider_profiles: [] }), true);
});

test('bridgeReady returns false for offline or revoked bridges', () => {
  assert.equal(bridgeReady({ status: 'offline' }), false);
  assert.equal(bridgeReady({ status: 'revoked' }), false);
  assert.equal(bridgeReady({ status: 'disconnected' }), false);
  assert.equal(bridgeReady({}), false);
});
