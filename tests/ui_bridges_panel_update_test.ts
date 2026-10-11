// REQ-BUPD-3: Unit Tests for UI BridgesPanel Version Badges, Update Notifications, and Trigger Modal
//
// RUN: node --test tests/ui_bridges_panel_update_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  formatBridgeVersion,
  formatLatestVersion,
  isBridgeUpdating,
  isUpdateUnavailableForTarget,
  updateAvailabilityLabel,
  shouldWarnActiveTasks,
  getActiveTaskCount,
} from '../src/ui/components/settings/bridgeUpdate.ts';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const REPO_ROOT = path.resolve(__dirname, '..');

const BRIDGES_PANEL_PATH = path.join(
  REPO_ROOT,
  'src/ui/components/settings/BridgesPanel.tsx',
);
const BRIDGE_SUPPORT_API_PATH = path.join(
  REPO_ROOT,
  'src/ui/api/endpoints/bridgeSupport.ts',
);

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

  const panel = fs.readFileSync(BRIDGES_PANEL_PATH, 'utf8');
  assert.match(panel, /data-debug-id=\{`settings-bridge-update-unavailable-\$\{id\}`\}/, 'unavailable badge has a debug id');
  assert.match(panel, /data-debug-id=\{`settings-bridge-target-\$\{id\}`\}/, 'target is shown in the bridge row');
  assert.match(fs.readFileSync(BRIDGE_SUPPORT_API_PATH, 'utf8'), /update_artifact_available\?: boolean/, 'Bridge type carries update_artifact_available');
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

// ---------------------------------------------------------------------------
// 2. BridgesPanel Source Invariants (REQ-BUPD-3 Acceptance Checklist)
// ---------------------------------------------------------------------------

test('BridgesPanel.tsx implements REQ-BUPD-3 acceptance checklist', () => {
  assert.ok(fs.existsSync(BRIDGES_PANEL_PATH), 'BridgesPanel.tsx must exist');
  const content = fs.readFileSync(BRIDGES_PANEL_PATH, 'utf8');

  // Acceptance Criterion 1: Bridge row displays version and commit SHA badges
  assert.match(
    content,
    /data-debug-id=\{`settings-bridge-version-\$\{id\}`\}/,
    'Bridge row must render monospace version badge with debug id',
  );
  assert.match(
    content,
    /font-mono/,
    'Version badge must use font-mono typography',
  );

  // Acceptance Criterion 2: "Update available" indicator renders when update_available is true
  assert.match(
    content,
    /bridge\?\.update_available/,
    'Panel must inspect update_available on bridge object',
  );
  assert.match(
    content,
    /data-debug-id=\{`settings-bridge-update-available-\$\{id\}`\}/,
    'Update available badge must have debug id',
  );
  assert.match(
    content,
    /Update available:/,
    'Badge text must include "Update available:"',
  );

  // Acceptance Criterion 3: "Update Bridge" button opens confirmation modal with drain/force options
  assert.match(
    content,
    /data-debug-id=\{`settings-bridge-update-btn-\$\{id\}`\}/,
    'Row must have Update Bridge button with debug id',
  );
  assert.match(
    content,
    /data-debug-id="settings-bridge-update-modal"/,
    'Confirmation dialog must have debug id',
  );
  assert.match(
    content,
    /data-debug-id="settings-bridge-update-warning"/,
    'Modal must render warning when active tasks exist',
  );
  assert.match(
    content,
    /data-debug-id="settings-bridge-update-drain-option"/,
    'Modal must provide graceful drain option',
  );
  assert.match(
    content,
    /data-debug-id="settings-bridge-update-force-option"/,
    'Modal must provide force immediate update option',
  );

  // Acceptance Criterion 4: Calling update mutation dispatches POST /api/v1/bridges/{id}/update
  assert.match(
    content,
    /updateBridge\(\{/,
    'Modal confirmation must invoke updateBridge mutation',
  );
  assert.match(
    content,
    /data-debug-id="settings-bridge-update-confirm"/,
    'Modal must include confirm update button',
  );

  // Real-time progress and error state tracking
  assert.match(
    content,
    /data-debug-id=\{`settings-bridge-update-progress-\$\{id\}`\}/,
    'Panel must display real-time progress state',
  );
  assert.match(
    content,
    /data-debug-id=\{`settings-bridge-update-failed-\$\{id\}`\}/,
    'Panel must display failure state and error reason',
  );
});

// ---------------------------------------------------------------------------
// 3. bridgeSupport.ts API Mutation & Interface Invariants (REQ-BUPD-3)
// ---------------------------------------------------------------------------

test('bridgeSupport.ts defines Bridge interface and updateBridge mutation', () => {
  assert.ok(fs.existsSync(BRIDGE_SUPPORT_API_PATH), 'bridgeSupport.ts must exist');
  const apiContent = fs.readFileSync(BRIDGE_SUPPORT_API_PATH, 'utf8');

  // Interface extension
  assert.match(apiContent, /export interface Bridge/, 'Bridge interface must be exported');
  assert.match(apiContent, /version\?: string;/, 'Bridge interface must include version');
  assert.match(apiContent, /commit_sha\?: string;/, 'Bridge interface must include commit_sha');
  assert.match(apiContent, /update_available\?: boolean;/, 'Bridge interface must include update_available');
  assert.match(apiContent, /latest_version\?: string;/, 'Bridge interface must include latest_version');
  assert.match(apiContent, /update_status\?:/, 'Bridge interface must include update_status');
  assert.match(apiContent, /update_error\?: string;/, 'Bridge interface must include update_error');

  // Mutation and hook
  assert.match(apiContent, /updateBridge: build\.mutation/, 'updateBridge mutation must be defined');
  assert.match(apiContent, /\/bridges\/\$\{encodeURIComponent\(bridgeId\)\}\/update/, 'Must hit /bridges/{id}/update endpoint');
  assert.match(apiContent, /useUpdateBridgeMutation/, 'useUpdateBridgeMutation hook must be exported');
});
