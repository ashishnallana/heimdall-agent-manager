// REQ-SET-3, REQ-SET-6: Unit tests for settingsPersistence
//
// RUN: node --test tests/ui_general_settings_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  SETTINGS_STORAGE_KEY,
  DEFAULT_GENERAL_SETTINGS,
  loadSettings,
  saveSettings,
} from '../src/ui/utils/settingsPersistence.ts';

// In-memory mock localStorage
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
// 1. settingsPersistence: Defaults and Fallbacks
// ---------------------------------------------------------------------------

test('DEFAULT_GENERAL_SETTINGS specifies correct default values', () => {
  assert.equal(DEFAULT_GENERAL_SETTINGS.queuedMessages, 'queue');
  assert.equal(DEFAULT_GENERAL_SETTINGS.permissionPreset, 'default');
  assert.equal(DEFAULT_GENERAL_SETTINGS.planReviewPolicy, 'always_ask');
  assert.equal(DEFAULT_GENERAL_SETTINGS.browserJsExecutionPolicy, 'request_review');
  assert.ok(DEFAULT_GENERAL_SETTINGS.commandSetupScript.includes('source ~/.profile'));
  assert.equal(DEFAULT_GENERAL_SETTINGS.advancedExpanded, true);
});

test('loadSettings returns defaults when localStorage is empty', () => {
  (globalThis as any).window = {
    localStorage: new MockStorage(),
  };

  const settings = loadSettings();
  assert.deepEqual(settings, DEFAULT_GENERAL_SETTINGS);
});

// ---------------------------------------------------------------------------
// 2. settingsPersistence: Save & Load Round-Trip
// ---------------------------------------------------------------------------

test('saveSettings persists modified values to localStorage under heimdall:settings:general', () => {
  const mockStorage = new MockStorage();
  (globalThis as any).window = {
    localStorage: mockStorage,
  };

  saveSettings({
    queuedMessages: 'send_immediately',
    permissionPreset: 'strict',
    planReviewPolicy: 'never_ask',
    browserJsExecutionPolicy: 'disabled',
    commandSetupScript: 'echo "hello world"',
    advancedExpanded: false,
  });

  const raw = mockStorage.getItem(SETTINGS_STORAGE_KEY);
  assert.ok(raw !== null, 'Item should be written to storage key');
  const parsed = JSON.parse(raw);
  assert.equal(parsed.queuedMessages, 'send_immediately');
  assert.equal(parsed.permissionPreset, 'strict');
  assert.equal(parsed.planReviewPolicy, 'never_ask');
  assert.equal(parsed.browserJsExecutionPolicy, 'disabled');
  assert.equal(parsed.commandSetupScript, 'echo "hello world"');
  assert.equal(parsed.advancedExpanded, false);

  // loadSettings should return the persisted values
  const loaded = loadSettings();
  assert.equal(loaded.queuedMessages, 'send_immediately');
  assert.equal(loaded.permissionPreset, 'strict');
  assert.equal(loaded.planReviewPolicy, 'never_ask');
  assert.equal(loaded.browserJsExecutionPolicy, 'disabled');
  assert.equal(loaded.commandSetupScript, 'echo "hello world"');
  assert.equal(loaded.advancedExpanded, false);
});

test('saveSettings supports partial updates without wiping other settings', () => {
  const mockStorage = new MockStorage();
  (globalThis as any).window = {
    localStorage: mockStorage,
  };

  saveSettings({ queuedMessages: 'send_immediately' });
  let loaded = loadSettings();
  assert.equal(loaded.queuedMessages, 'send_immediately');
  assert.equal(loaded.permissionPreset, 'default'); // Default preserved

  saveSettings({ permissionPreset: 'custom' });
  loaded = loadSettings();
  assert.equal(loaded.queuedMessages, 'send_immediately'); // Previously saved preserved
  assert.equal(loaded.permissionPreset, 'custom');
});
