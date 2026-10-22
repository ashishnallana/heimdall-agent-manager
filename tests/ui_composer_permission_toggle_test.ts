// Composer "Bypass permissions" toggle (instance permission_mode): visibility
// rules from the provider catalog extension and the instance's extension hello,
// the state it reflects (effective_permission_mode), the reconfiguration payload
// a toggle sends, the real endpoint's wire body, and source checks that the
// composer settings panel renders it and restarts through the reconfiguration.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_composer_permission_toggle_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

import {
  INSTALL_EXTENSION_HINT,
  PENDING_CHANGES_HINT,
  catalogSupportsPermissions,
  effectivePermissionMode,
  permissionToggleRequest,
  permissionToggleState,
} from '../src/ui/components/workbench/permissionToggleModel.ts';

function catalog(capabilities: string[], state = 'present') {
  return {
    state, version: '0.1.0', checked_at: '2026-10-22T08:00:00Z', plugin_id: 'heimdall@heimdall',
    min_version: '0.1.0', install_hint: 'claude plugin install heimdall@heimdall', capabilities,
  };
}

function instance(extra: Record<string, unknown> = {}) {
  return {
    agent_instance_id: 'inst_1', bridge_id: 'brg_1', project_id: 'proj_1', provider: 'claude',
    model: 'claude-opus-5-5', configuration_revision: 3, permission_mode: '',
    effective_permission_mode: 'yolo',
    extension: { provider: 'claude', version: '0.1.0', capabilities: ['activity', 'permissions'], last_seen_at: '2026-10-22T08:00:00Z' },
    ...extra,
  };
}

test('hidden when the provider catalog has no extension or no permissions capability', () => {
  assert.equal(permissionToggleState({ catalogExtension: null, instance: instance() }).visible, false);
  assert.equal(permissionToggleState({ catalogExtension: catalog(['activity', 'subagents']), instance: instance() }).visible, false);
  assert.equal(permissionToggleState({ catalogExtension: catalog(['permissions'], 'unsupported'), instance: instance() }).visible, false);
  assert.equal(catalogSupportsPermissions(catalog(['permissions'])), true);
  // The catalog decides visibility even before the bridge probed the extension.
  assert.equal(catalogSupportsPermissions(catalog(['permissions'], '')), true);
});

test('reflects effective_permission_mode, not the raw instance override', () => {
  const inherited = permissionToggleState({ catalogExtension: catalog(['permissions']), instance: instance({ permission_mode: '', effective_permission_mode: 'ask' }) });
  assert.deepEqual(inherited, { visible: true, bypass: false, disabled: false, hint: '' });
  const bypassed = permissionToggleState({ catalogExtension: catalog(['permissions']), instance: instance({ permission_mode: 'yolo', effective_permission_mode: 'yolo' }) });
  assert.deepEqual(bypassed, { visible: true, bypass: true, disabled: false, hint: '' });
  // Older hubs omit the field: the historical launch is yolo.
  assert.equal(effectivePermissionMode({}), 'yolo');
  assert.equal(effectivePermissionMode({ effective_permission_mode: 'bogus' }), 'yolo');
});

test('requiring approvals is disabled with a hint until the instance extension reports permissions', () => {
  const noHello = instance({ extension: { provider: '', version: '', capabilities: [], last_seen_at: '' } });
  const state = permissionToggleState({ catalogExtension: catalog(['permissions']), instance: noHello });
  assert.deepEqual(state, { visible: true, bypass: true, disabled: true, hint: INSTALL_EXTENSION_HINT });
  const noPermCap = instance({ extension: { provider: 'claude', version: '0.1.0', capabilities: ['activity'], last_seen_at: '' } });
  assert.equal(permissionToggleState({ catalogExtension: catalog(['permissions']), instance: noPermCap }).hint, INSTALL_EXTENSION_HINT);
  // Turning bypass back ON never needs the extension.
  const asking = permissionToggleState({ catalogExtension: catalog(['permissions']), instance: { ...noHello, effective_permission_mode: 'ask' } });
  assert.deepEqual(asking, { visible: true, bypass: false, disabled: false, hint: '' });
});

test('disabled while busy or while other settings are staged', () => {
  const busy = permissionToggleState({ catalogExtension: catalog(['permissions']), instance: instance(), busy: true });
  assert.equal(busy.disabled, true);
  assert.equal(busy.hint, '');
  const staged = permissionToggleState({ catalogExtension: catalog(['permissions']), instance: instance(), pendingChanges: true });
  assert.deepEqual(staged, { visible: true, bypass: true, disabled: true, hint: PENDING_CHANGES_HINT });
});

test('toggle -> reconfiguration keeps the current destination and sets only permission_mode', () => {
  const off = permissionToggleRequest(instance(), false, 'key_1');
  assert.deepEqual(off, {
    instanceId: 'inst_1', bridge_id: 'brg_1', project_id: 'proj_1', provider: 'claude',
    model: 'claude-opus-5-5', expected_revision: 3, idempotency_key: 'key_1', permission_mode: 'ask',
  });
  const on = permissionToggleRequest(instance({ project_id: '', configuration_revision: 0 }), true, 'key_2');
  assert.equal(on.permission_mode, 'yolo');
  assert.equal(on.project_id, '');
  assert.equal(on.expected_revision, 0);
});

test('the real applyInstanceConfiguration endpoint sends permission_mode on the wire', async () => {
  const { installFetchCapture, installWindowShim, makeVaultStore } = await import('./helpers/vaultEndpointHarness.ts');
  installWindowShim();
  const capture = installFetchCapture();
  const store = await makeVaultStore();
  const { agentsApi } = await import('../src/ui/api/endpoints/agents.ts');
  capture.setNextResponse({ data: { operation_id: 'reconfig_1', phase: 'stopping', revision: 2 } });
  const result: any = await store.dispatch(
    agentsApi.endpoints.applyInstanceConfiguration.initiate(permissionToggleRequest(instance(), false, 'key_wire')),
  );
  assert.equal(result.data?.operation_id, 'reconfig_1');
  const req = capture.find((r) => r.method === 'POST' && r.url.includes('/agent-instances/inst_1/reconfigurations'));
  assert.deepEqual(req.body, {
    bridge_id: 'brg_1', project_id: 'proj_1', provider: 'claude', model: 'claude-opus-5-5',
    expected_revision: 3, idempotency_key: 'key_wire', permission_mode: 'ask',
  });
});

test('the composer settings panel renders the toggle and restarts through the reconfiguration', () => {
  const pane = fs.readFileSync(fileURLToPath(new URL('../src/ui/components/workbench/AgentChatPane.tsx', import.meta.url)), 'utf8');
  assert.match(pane, /permissionToggleState\(/);
  assert.match(pane, /data-debug-id="conversation-permission-toggle"/);
  assert.match(pane, /Bypass permissions/);
  assert.match(pane, /reconfigureInstance\(\s*permissionToggleRequest\(/);
  assert.match(pane, /setAcceptedOperation\(applied\)/);
  // The agent editor keeps the durable default.
  const form = fs.readFileSync(fileURLToPath(new URL('../src/ui/components/agents/AgentFormPage.tsx', import.meta.url)), 'utf8');
  assert.match(form, /permission_mode|permissionMode/);
  // The progress card names the permission change for a permission-only operation.
  const progress = fs.readFileSync(fileURLToPath(new URL('../src/ui/components/chat/InstanceReconfigurationProgress.tsx', import.meta.url)), 'utf8');
  assert.match(progress, /permissionChanged/);
  assert.match(progress, /Approvals required/);
});
