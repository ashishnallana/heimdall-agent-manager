// Sidebar Bridge-update badge: which bridges it advertises (connected, online,
// installable update, not mid-update), checked once on load, and its click
// opening Workspace Settings at that bridge's Update button.
//
// RUN: node --test tests/ui_sidebar_update_badge_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { pendingBridgeUpdates } from '../src/ui/components/settings/bridgeUpdate.ts';

const online = { status: 'online', runtime_connected: true, update_available: true };

test('only connected, online bridges with an installable update are advertised', () => {
  const updates = pendingBridgeUpdates([
    { ...online, bridge_id: 'brg_ok', label: 'dawnstar', latest_version: '0.3.40' },
    { ...online, bridge_id: 'brg_offline', status: 'offline', latest_version: '0.3.40' },
    { ...online, bridge_id: 'brg_disconnected', runtime_connected: false, latest_version: '0.3.40' },
    { ...online, bridge_id: 'brg_current', update_available: false },
    { ...online, bridge_id: 'brg_no_bundle', update_artifact_available: false, latest_version: '0.3.40' },
    { ...online, bridge_id: 'brg_updating', update_status: 'downloading', latest_version: '0.3.40' },
  ] as any);
  assert.deepEqual(updates, [{ bridgeId: 'brg_ok', latestVersion: '0.3.40', label: 'dawnstar' }]);
});

test('newest advertised version comes first (numeric compare)', () => {
  const updates = pendingBridgeUpdates([
    { ...online, bridge_id: 'a', latest_version: '0.3.9' },
    { ...online, bridge_id: 'b', latest_version: '0.3.40' },
  ] as any);
  assert.deepEqual(updates.map(u => u.bridgeId), ['b', 'a']);
});

test('empty / malformed input', () => {
  assert.deepEqual(pendingBridgeUpdates(undefined), []);
  assert.deepEqual(pendingBridgeUpdates([{ ...online }] as any), []);
  // The list query's data is `{ bridges: [...] }`; a non-array must never throw.
  assert.deepEqual(pendingBridgeUpdates({ bridges: [] } as any), []);
});

test('badge checks once on load and opens the bridge update button', () => {
  const badge = readFileSync(new URL('../src/ui/components/shell/SidebarUpdateBadge.tsx', import.meta.url), 'utf8');
  assert.match(badge, /if \(update !== undefined \|\| !bridgesQuery\.isSuccess\) return;/, 'first response is captured once');
  assert.match(badge, /pendingBridgeUpdates\(bridgesQuery\.data\?\.bridges\)/, 'reads the bridges array from the list query');
  const shell = readFileSync(new URL('../src/ui/components/shell/AppShell.tsx', import.meta.url), 'utf8');
  assert.match(shell, /settings-bridge-update-btn-\$\{CSS\.escape\(update\.bridgeId\)\}/);
  assert.match(shell, /setSettingsModalTab\('bridges'\)/);
});
