// REQ-SET-1, REQ-SET-2, REQ-SET-3, REQ-SET-4, REQ-SET-5, REQ-SET-6: Unit tests for SettingsModal routing & persistence
//
// RUN: node --test tests/ui_settings_modal_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  SETTINGS_STORAGE_KEY,
  loadSettings,
  saveSettings,
} from '../src/ui/utils/settingsPersistence.ts';
import {
  resolveSettingsTab,
  normalizeSettingsTab,
} from '../src/ui/utils/settingsRouting.ts';
import {
  DEFAULT_NAV,
  DEFAULT_ACTIONS,
} from '../src/ui/components/ui/patterns/commandPaletteLogic.ts';

// In-memory mock localStorage for settings persistence tests
class MockStorage {
  private store = new Map<string, string>();

  getItem(key: string): string | null {
    return this.store.get(key) ?? null;
  }

  setItem(key: string, value: string): void {
    this.store.set(key, String(value));
  }

  removeItem(key: string): void {
    this.store.delete(key);
  }

  clear(): void {
    this.store.clear();
  }

  get length(): number {
    return this.store.size;
  }

  key(index: number): string | null {
    return Array.from(this.store.keys())[index] ?? null;
  }
}

// ---------------------------------------------------------------------------
// 1. settingsPersistence Load & Save Round-Trip (REQ-SET-3, REQ-SET-6 item 3)
// ---------------------------------------------------------------------------

test('settingsPersistence correctly loads defaults, serializes, and deserializes to localStorage', () => {
  const mockStorage = new MockStorage();
  (globalThis as any).window = {
    localStorage: mockStorage,
  };

  // 1. Load defaults
  const defaults = loadSettings();
  assert.equal(defaults.queuedMessages, 'queue');
  assert.equal(defaults.permissionPreset, 'default');
  assert.equal(defaults.planReviewPolicy, 'always_ask');
  assert.equal(defaults.browserJsExecutionPolicy, 'request_review');
  assert.equal(defaults.advancedExpanded, true);

  // 2. Save modified settings
  saveSettings({
    queuedMessages: 'send_immediately',
    permissionPreset: 'strict',
    planReviewPolicy: 'never_ask',
    browserJsExecutionPolicy: 'disabled',
    commandSetupScript: 'echo "testing settings roundtrip"',
    advancedExpanded: false,
  });

  const raw = mockStorage.getItem(SETTINGS_STORAGE_KEY);
  assert.ok(raw !== null, 'Item should be written to storage key');
  const parsed = JSON.parse(raw);
  assert.equal(parsed.queuedMessages, 'send_immediately');
  assert.equal(parsed.permissionPreset, 'strict');
  assert.equal(parsed.planReviewPolicy, 'never_ask');
  assert.equal(parsed.browserJsExecutionPolicy, 'disabled');
  assert.equal(parsed.commandSetupScript, 'echo "testing settings roundtrip"');
  assert.equal(parsed.advancedExpanded, false);

  // 3. LoadSettings deserializes accurately
  const loaded = loadSettings();
  assert.equal(loaded.queuedMessages, 'send_immediately');
  assert.equal(loaded.permissionPreset, 'strict');
  assert.equal(loaded.planReviewPolicy, 'never_ask');
  assert.equal(loaded.browserJsExecutionPolicy, 'disabled');
  assert.equal(loaded.commandSetupScript, 'echo "testing settings roundtrip"');
  assert.equal(loaded.advancedExpanded, false);

  // 4. Partial update support
  saveSettings({ queuedMessages: 'queue' });
  const partiallyUpdated = loadSettings();
  assert.equal(partiallyUpdated.queuedMessages, 'queue');
  assert.equal(partiallyUpdated.permissionPreset, 'strict'); // Preserved from previous save
});

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
  assert.equal(resolveSettingsTab('/settings/user-tokens'), 'user-tokens');
  assert.equal(resolveSettingsTab('/settings/templates'), 'templates');
  assert.equal(resolveSettingsTab('#/settings/vault'), 'vault');
  assert.equal(resolveSettingsTab('#/settings/lsp'), 'lsp');
  assert.equal(resolveSettingsTab('#/settings/user-tokens'), 'user-tokens');
  assert.equal(resolveSettingsTab('#/settings/templates'), 'templates');
  assert.equal(resolveSettingsTab('#/settings/projects'), 'projects');
  assert.equal(resolveSettingsTab('#/settings/experimental'), 'experimental');

  // Alias normalization
  assert.equal(normalizeSettingsTab('bridges'), 'workspace');
  assert.equal(normalizeSettingsTab('providers'), 'models');
  assert.equal(normalizeSettingsTab('labs'), 'experimental');
  assert.equal(normalizeSettingsTab('experimental'), 'experimental');
  assert.equal(normalizeSettingsTab('vault'), 'vault');
  assert.equal(normalizeSettingsTab('lsp'), 'lsp');
  assert.equal(normalizeSettingsTab('user-tokens'), 'user-tokens');
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
