// REQ-SET-1, REQ-SET-2, REQ-SET-3, REQ-SET-4, REQ-SET-5, REQ-SET-6: Unit tests for SettingsModal routing
//
// RUN: node --test tests/ui_settings_modal_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  resolveSettingsTab,
  normalizeSettingsTab,
} from '../src/ui/utils/settingsRouting.ts';
import {
  DEFAULT_NAV,
  DEFAULT_ACTIONS,
} from '../src/ui/components/ui/patterns/commandPaletteLogic.ts';

// Dynamic import runs after the harness registers its Vite-style module resolver.
const { SETTINGS_CATEGORIES } = await import('../src/ui/components/settings/SettingsModal.tsx');

// ---------------------------------------------------------------------------
// 2. AppShell Routing Integration (REQ-SET-5, REQ-SET-6 item 5)
// ---------------------------------------------------------------------------

test('AppShell routing integration ensures settings routes resolve without crashing', () => {
  // Deep link route resolution
  assert.equal(resolveSettingsTab('/settings'), '');
  assert.equal(resolveSettingsTab('/settings/'), '');
  assert.equal(resolveSettingsTab('/settings/general'), '');
  assert.equal(resolveSettingsTab('/settings/appearance'), 'appearance');
  assert.equal(resolveSettingsTab('/settings/bridges'), 'bridges');
  assert.equal(resolveSettingsTab('/settings/notifications'), 'notifications');
  assert.equal(resolveSettingsTab('/settings/providers'), 'providers');
  assert.equal(resolveSettingsTab('/settings/projects'), 'projects');
  assert.equal(resolveSettingsTab('/settings/experimental'), 'experimental');
  assert.equal(resolveSettingsTab('/settings/vault'), 'vault');
  assert.equal(resolveSettingsTab('/settings/lsp'), 'lsp');
  assert.equal(resolveSettingsTab('/settings/templates'), 'templates');
  assert.equal(resolveSettingsTab('#/settings/vault'), 'vault');
  assert.equal(resolveSettingsTab('#/settings/lsp'), 'lsp');
  assert.equal(resolveSettingsTab('#/settings/templates'), 'templates');
  assert.equal(resolveSettingsTab('#/settings/projects'), 'projects');
  assert.equal(resolveSettingsTab('#/settings/experimental'), 'experimental');

  // Alias normalization
  // REQ-ENR-11: Workspace Settings was replaced by Bridges; legacy links land on Bridges.
  assert.equal(normalizeSettingsTab('bridges'), 'bridges');
  assert.equal(normalizeSettingsTab('workspace'), 'bridges');
  assert.equal(normalizeSettingsTab('providers'), 'models');
  assert.equal(normalizeSettingsTab('labs'), 'experimental');
  assert.equal(normalizeSettingsTab('experimental'), 'experimental');
  assert.equal(normalizeSettingsTab('vault'), 'vault');
  assert.equal(normalizeSettingsTab('lsp'), 'lsp');
  assert.equal(normalizeSettingsTab('templates'), 'templates');
  assert.equal(normalizeSettingsTab('projects'), 'projects');
  assert.equal(normalizeSettingsTab('browser'), 'appearance');
  assert.equal(normalizeSettingsTab('shortcuts'), 'appearance');
  assert.equal(normalizeSettingsTab('feedback'), 'appearance');
  assert.equal(normalizeSettingsTab('general'), 'account');
  assert.equal(normalizeSettingsTab(), 'account');
  assert.equal(normalizeSettingsTab(undefined), 'account');

  // Command palette integration
  const settingsNav = DEFAULT_NAV.find((item) => item.label === 'Settings');
  assert.ok(settingsNav, 'DEFAULT_NAV must include Settings');
  assert.ok(
    settingsNav.route.startsWith('/settings'),
    'Settings nav route must start with /settings',
  );
  const appearanceNav = DEFAULT_NAV.find((item) => item.label === 'Appearance');
  assert.ok(appearanceNav, 'DEFAULT_NAV must include Appearance');
  assert.equal(appearanceNav.route, '/settings/appearance');
  const settingsAction = DEFAULT_ACTIONS.find(
    (action) => action.id === 'settings' || action.id === 'settings-modal',
  );
  assert.ok(settingsAction, 'DEFAULT_ACTIONS must include settings action');
});

test('Settings lists a Bridges category in place of Workspace Settings (REQ-ENR-11)', () => {
  const bridges = SETTINGS_CATEGORIES.find((category) => category.id === 'bridges');
  assert.ok(bridges, 'SETTINGS_CATEGORIES must include bridges');
  assert.equal(bridges.label, 'Bridges');
  assert.equal(SETTINGS_CATEGORIES.some((category) => category.id === 'workspace'), false);
  assert.equal(SETTINGS_CATEGORIES.some((category) => /Workspace Settings/.test(category.label)), false);
});
