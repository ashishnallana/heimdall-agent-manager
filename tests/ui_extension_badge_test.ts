// Provider extension badges (REQ-EXT-DET-2): the provider-setup badge for every
// measured extension state, the install hint copy, and the per-instance
// "native signals" / "screen detection" badge, plus source checks that the
// provider setup surface and the conversation header render them.
//
// RUN: node --test tests/ui_extension_badge_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

import {
  instanceSignalBadge,
  normalizeInstanceExtension,
  normalizeProviderExtension,
  providerExtensionBadge,
} from '../src/ui/components/extension/extensionBadgeModel.ts';

const HINT = 'claude plugin marketplace add <repo>/extensions && claude plugin install heimdall@heimdall';

function ext(state: string, extra: Record<string, unknown> = {}) {
  return normalizeProviderExtension({
    state, version: '', checked_at: '2026-10-22T06:00:00Z', plugin_id: 'heimdall@heimdall',
    min_version: '0.1.0', install_hint: HINT, capabilities: ['activity', 'permissions'], ...extra,
  });
}

test('installed extension shows its version and no install hint', () => {
  const badge = providerExtensionBadge(ext('present', { version: '0.2.1' }));
  assert.equal(badge?.kind, 'installed');
  assert.equal(badge?.label, 'Extension installed v0.2.1');
  assert.equal(badge?.tone, 'success');
  assert.equal(badge?.installHint, '');
});

test('disabled, outdated, absent and error map to their labels', () => {
  assert.equal(providerExtensionBadge(ext('disabled'))?.label, 'Extension disabled');
  const disabled = providerExtensionBadge(ext('disabled'))!.detail;
  assert.match(disabled, /heimdall@heimdall/);
  assert.doesNotMatch(disabled, /claude plugin/, 'no provider-specific command in the generic UI');
  const update = providerExtensionBadge(ext('outdated', { version: '0.0.9' }))!;
  assert.equal(update.label, 'Update available');
  assert.match(update.detail, /v0\.0\.9.*v0\.1\.0/);
  assert.equal(update.installHint, '', 'a <repo> placeholder hint is never shown');
  assert.equal(providerExtensionBadge(ext('outdated', { install_hint: 'codex plugin add heimdall@heimdall' }))!.installHint, 'codex plugin add heimdall@heimdall');
  assert.equal(providerExtensionBadge(ext('error'))?.kind, 'error');
});

test('"Not found" carries a usable catalog install hint, but never a <repo> placeholder', () => {
  const badge = providerExtensionBadge(ext('absent'))!;
  assert.equal(badge.kind, 'not-found');
  assert.equal(badge.label, 'Not found');
  assert.equal(badge.installHint, '');
  const usable = 'claude plugin install heimdall@heimdall';
  assert.equal(providerExtensionBadge(ext('absent', { install_hint: usable }))!.installHint, usable);
});

test('badge is hidden when the provider has no extension or it is unsupported', () => {
  assert.equal(normalizeProviderExtension(null), null);
  assert.equal(providerExtensionBadge(normalizeProviderExtension(null)), null);
  assert.equal(providerExtensionBadge(ext('unsupported')), null);
});

test('an unknown or unreported state reads as "not checked"', () => {
  assert.equal(ext('weird')?.state, '');
  assert.equal(providerExtensionBadge(ext(''))?.kind, 'not-checked');
});

test('instance badge: native signals with the capability list as tooltip', () => {
  const badge = instanceSignalBadge({ provider: 'claude', version: '0.1.0', capabilities: ['activity', 'subagents', 'permissions', 'file_edits'], last_seen_at: 'x' });
  assert.equal(badge.kind, 'native');
  assert.equal(badge.label, 'Native signals');
  assert.match(badge.tooltip, /claude v0\.1\.0/);
  assert.match(badge.tooltip, /Activity, Subagents, Permission prompts, File edits/);
});

test('instance badge falls back to screen detection without capabilities', () => {
  assert.equal(instanceSignalBadge(undefined).kind, 'screen');
  assert.equal(instanceSignalBadge(null).label, 'Screen detection');
  assert.equal(instanceSignalBadge({ provider: 'claude', capabilities: [] }).kind, 'screen');
  assert.equal(normalizeInstanceExtension({ provider: '', capabilities: [] }), null);
});

const root = fileURLToPath(new URL('..', import.meta.url));
const read = (p: string) => fs.readFileSync(`${root}/${p}`, 'utf8');

test('provider setup surface renders the extension badge and copyable hint', () => {
  const api = read('src/ui/components/providers/providerSetupApi.ts');
  assert.match(api, /normalizeProviderExtension\(raw\?\.extension\)/);
  const surface = read('src/ui/components/providers/ProviderSetupSurface.tsx');
  assert.match(surface, /<ProviderExtensionBadge/);
  const badges = read('src/ui/components/extension/ExtensionBadges.tsx');
  assert.match(badges, /provider-extension-install-copy-btn-/);
  assert.match(badges, /copyTextToClipboard/);
});

test('conversation header no longer shows the instance signal badge', () => {
  const pane = read('src/ui/components/workbench/AgentChatPane.tsx');
  assert.doesNotMatch(pane, /InstanceSignalBadge/);
});

test('installed package never asserts trusted or active per-instance hooks', () => {
  const badge = providerExtensionBadge(normalizeProviderExtension({ state: 'present', version: '0.1.0' }));
  assert.match(badge!.detail, /review may be required/i);
  assert.doesNotMatch(badge!.detail, /signals are available/i);
});

test('Codex tested-release package uses compatibility manifest without portable shadow', () => {
  const root = new URL('../extensions/codex/', import.meta.url);
  assert.equal(fs.existsSync(new URL('plugin.json', root)), false);
  const manifest = JSON.parse(fs.readFileSync(new URL('.codex-plugin/plugin.json', root), 'utf8'));
  assert.equal(manifest.name, 'heimdall');
  assert.equal(manifest.hooks, './hooks/hooks.json');
  const hookConfig = JSON.parse(fs.readFileSync(new URL('hooks/hooks.json', root), 'utf8'));
  assert.equal(Object.keys(hookConfig.hooks).length, 10);
  for (const [event, groups] of Object.entries(hookConfig.hooks) as Array<[string, any[]]>) {
    const hook = groups[0].hooks[0];
    assert.match(hook.command, /HEIMDALL_CTL_BIN/);
    assert.match(hook.command, /extension hook codex/);
    assert.equal(hook.async, undefined);
    assert.equal(hook.timeout, event === 'PermissionRequest' ? 330 : event === 'SessionEnd' || event === 'Interrupt' ? 3 : 5);
  }
});
