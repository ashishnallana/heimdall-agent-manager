// REQ-BUPD-3: Unit Tests for UI BridgesPanel Version Badges, Update Notifications, and Trigger Modal
//
// RUN: node --test tests/ui_bridges_panel_update_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  formatBridgeVersion,
  formatLatestVersion,
  isBridgeUpdating,
  isUpdateUnavailableForTarget,
  updateAvailabilityLabel,
  shouldWarnActiveTasks,
  getActiveTaskCount,
} from '../src/ui/components/settings/bridgeUpdate.ts';

// ---------------------------------------------------------------------------
// 1. Version Formatting and Update Predicates (REQ-BUPD-3)
// ---------------------------------------------------------------------------

test('formatBridgeVersion correctly formats version and commit sha variants', () => {
  assert.equal(
    formatBridgeVersion({ version: '0.1.0', commit_sha: 'a57c83d9' }),
    'v0.1.0 (a57c83d9)',
    'Should format full version with commit sha in parentheses',
  );
  assert.equal(
    formatBridgeVersion({ version: '0.1.0' }),
    'v0.1.0',
    'Should format version without commit sha',
  );
  assert.equal(
    formatBridgeVersion({ commit_sha: 'a57c83d9' }),
    'a57c83d9',
    'Should format commit sha without version prefix',
  );
  assert.equal(
    formatBridgeVersion({ commit_sha: 'a57c83d912345678' }),
    'a57c83d9',
    'Should slice commit sha to 8 characters',
  );
  assert.equal(
    formatBridgeVersion(null),
    '',
    'Should return empty string for null bridge',
  );
  assert.equal(
    formatBridgeVersion(undefined),
    '',
    'Should return empty string for undefined bridge',
  );
  assert.equal(
    formatBridgeVersion({}),
    '',
    'Should return empty string when neither version nor commit is present',
  );
});

test('formatLatestVersion correctly formats latest version indicator', () => {
  assert.equal(
    formatLatestVersion({ latest_version: '0.2.0', latest_commit_sha: '796bfb57' }),
    'v0.2.0 (796bfb57)',
    'Should format latest version with commit sha',
  );
  assert.equal(
    formatLatestVersion({ latest_version: '0.2.0' }),
    'v0.2.0',
    'Should format latest version without commit sha',
  );
  assert.equal(
    formatLatestVersion({}),
    'latest',
    'Should default to latest when no version is provided',
  );
  assert.equal(
    formatLatestVersion(null),
    'latest',
    'Should default to latest for null bridge',
  );
});

// REQ-T13-4: a release without a bundle for the bridge's target (e.g. a
// termux-arm64 bridge on a release that only ships linux-arm64) is shown as
// "not available for <target>", never as an installable update.
test('update availability copy names the target when no bundle exists for it', () => {
  const termux = { update_available: true, update_artifact_available: false, latest_version: '0.3.30', target: 'termux-arm64' };
  assert.equal(isUpdateUnavailableForTarget(termux), true);
  assert.equal(updateAvailabilityLabel(termux), 'v0.3.30 not available for termux-arm64');
  assert.equal(
    updateAvailabilityLabel({ ...termux, target: '' }),
    'v0.3.30 not available for this target',
  );
  const installable = { ...termux, update_artifact_available: true };
  assert.equal(isUpdateUnavailableForTarget(installable), false);
  assert.equal(updateAvailabilityLabel(installable), 'Update available: v0.3.30');
  // Hubs that predate the field omit it: keep the existing behaviour.
  assert.equal(isUpdateUnavailableForTarget({ update_available: true }), false);
  assert.equal(isUpdateUnavailableForTarget({ update_available: false, update_artifact_available: false }), false);
  assert.equal(isUpdateUnavailableForTarget(null), false);
});

test('isBridgeUpdating identifies active update stages', () => {
  assert.equal(isBridgeUpdating({ update_status: 'downloading' }), true);
  assert.equal(isBridgeUpdating({ update_status: 'validating' }), true);
  assert.equal(isBridgeUpdating({ update_status: 'restarting' }), true);

  assert.equal(isBridgeUpdating({ update_status: 'idle' }), false);
  assert.equal(isBridgeUpdating({ update_status: 'healthy' }), false);
  assert.equal(isBridgeUpdating({ update_status: 'complete' }), false);
  assert.equal(isBridgeUpdating({ update_status: 'failed' }), false);
  assert.equal(isBridgeUpdating({}), false);
  assert.equal(isBridgeUpdating(null), false);
});

test('shouldWarnActiveTasks and getActiveTaskCount detect running agent instances', () => {
  assert.equal(shouldWarnActiveTasks({ active_instance_count: 3 }), true);
  assert.equal(getActiveTaskCount({ active_instance_count: 3 }), 3);

  assert.equal(shouldWarnActiveTasks({ instance_count: 1 }), true);
  assert.equal(getActiveTaskCount({ instance_count: 1 }), 1);

  assert.equal(shouldWarnActiveTasks({ active_instance_count: 0 }), false);
  assert.equal(getActiveTaskCount({ active_instance_count: 0 }), 0);

  assert.equal(shouldWarnActiveTasks({}), false);
  assert.equal(getActiveTaskCount({}), 0);
});

