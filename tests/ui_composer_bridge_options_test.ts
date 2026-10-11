// Composer "Agent settings" bridge picker: archived bridges are hidden, offline
// bridges are listed but disabled.
//
// RUN: node --test tests/ui_composer_bridge_options_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { composerBridgeIsArchived, composerBridgeOptions } from '../src/ui/utils/composerBridgeOptions.ts';

const online = { bridge_id: 'brg_on', status: 'online', runtime_connected: true, reconfiguration_supported: true };
const offline = { bridge_id: 'brg_off', status: 'offline', runtime_connected: false };
const staleOnline = { bridge_id: 'brg_stale', status: 'online', runtime_connected: false };
const archived = { bridge_id: 'brg_arch', status: 'revoked', revoked_at: '2026-10-01T00:00:00Z' };
const archivedAt = { bridge_id: 'brg_arch2', status: 'offline', revoked_at: '2026-10-01T00:00:00Z' };
const oldBuild = { bridge_id: 'brg_old', status: 'online', runtime_connected: true, reconfiguration_supported: false };

test('archived (revoked) bridges are not offered at all', () => {
  assert.equal(composerBridgeIsArchived(archived), true);
  assert.equal(composerBridgeIsArchived(archivedAt), true);
  assert.equal(composerBridgeIsArchived(offline), false);
  const ids = composerBridgeOptions([online, archived, offline, archivedAt]).map((o) => o.id);
  assert.deepEqual(ids, ['brg_on', 'brg_off']);
});

test('offline bridges are listed but disabled; online ones are selectable', () => {
  const byId = Object.fromEntries(composerBridgeOptions([online, offline, staleOnline]).map((o) => [o.id, o.disabledReason]));
  assert.equal(byId.brg_on, null);
  assert.equal(byId.brg_off, 'offline');
  assert.equal(byId.brg_stale, 'offline', 'online at the hub but no runtime connection is still offline');
});

test('reconfiguration requirement still applies to online bridges', () => {
  const [opt] = composerBridgeOptions([oldBuild], true);
  assert.equal(opt.disabledReason, 'update_required');
  assert.equal(composerBridgeOptions([oldBuild], false)[0].disabledReason, null);
  assert.equal(composerBridgeOptions([{ ...offline, reconfiguration_supported: false }], true)[0].disabledReason, 'offline');
});

test('empty / malformed input', () => {
  assert.deepEqual(composerBridgeOptions(undefined), []);
  assert.deepEqual(composerBridgeOptions([{ status: 'online' }]), []);
});

test('the picker renders only these options and disables by their reason', () => {
  const s = readFileSync(new URL('../src/ui/components/chat/RuntimeConfigurationOptions.tsx', import.meta.url), 'utf8');
  assert.match(s, /const bridgeOptions = composerBridgeOptions\(bridges, requireReconfiguration\);/);
  assert.match(s, /\{bridgeOptions\.map\(/);
  assert.doesNotMatch(s, /\{bridges\.map\(/, 'raw list (with archived bridges) is no longer rendered');
  assert.match(s, /disabled=\{disabled \|\| disabledReason !== null\}/);
});
