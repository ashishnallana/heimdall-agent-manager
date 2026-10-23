import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { JSDOM } from 'jsdom';
import React, { act } from 'react';
import { configureStore } from '@reduxjs/toolkit';
import { Provider } from 'react-redux';

const dom = new JSDOM('<!doctype html><html><body></body></html>', { url: 'https://heimdall.test/' });
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
  ResizeObserver: class { observe() {} disconnect() {} },
  cancelAnimationFrame: () => {},
});
const { createRoot } = await import('react-dom/client');
const {
  default: inputPreferences,
  externalKeyboardSet,
  INPUT_PREFERENCES_STORAGE_KEY: key,
  setupInputPreferencesSync,
} = await import('../src/ui/store/inputPreferencesSlice.ts');
const { MessageComposerInput } = await import('../src/ui/components/chat/MessageComposer.tsx');
const { AppearanceSettings } = await import('../src/ui/components/settings/AppearanceSettings.tsx');
const makeStore = () => configureStore({ reducer: { inputPreferences } });
after(() => dom.window.close());

test('default is off; touch settings toggle updates both mounted composer contexts and persists', async () => {
  window.localStorage.clear();
  const store = makeStore();
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  let keyEvents = 0;
  let pasted = false;
  const ref = React.createRef<HTMLTextAreaElement>();
  await act(async () => root.render(React.createElement(Provider, { store, children: [
    React.createElement(AppearanceSettings, { key: 'settings' }),
    React.createElement(MessageComposerInput, { key: 'new', mobile: true, debugId: 'new-convo-composer-input', defaultValue: 'draft one', ref, onKeyDown: () => keyEvents++, onPaste: () => { pasted = true; } }),
    React.createElement(MessageComposerInput, { key: 'agent', mobile: false, debugId: 'agent-composer-input', defaultValue: 'draft two' }),
  ] })));
  try {
    const checkbox = container.querySelector<HTMLInputElement>('[data-debug-id="settings-external-keyboard-checkbox"]')!;
    const inputs = [...container.querySelectorAll('textarea')];
    assert.equal(checkbox.checked, false);
    assert.ok(checkbox.closest('label')?.textContent?.includes('Use external keyboard'));
    assert.match(document.getElementById(checkbox.getAttribute('aria-describedby')!)!.textContent!, /Hide the on-screen keyboard in message composers\. Turn off to type on screen\./);
    assert.deepEqual(inputs.map(input => input.inputMode), ['text', 'text']);
    // Clicking the containing label exercises the native touch-accessible control.
    await act(async () => checkbox.closest('label')!.click());
    assert.equal(checkbox.checked, true);
    assert.equal(store.getState().inputPreferences.useExternalKeyboard, true);
    assert.deepEqual(JSON.parse(window.localStorage.getItem(key)!), { useExternalKeyboard: true });
    assert.deepEqual(inputs.map(input => input.inputMode), ['none', 'none']);
    assert.equal(ref.current, inputs[0]);
    assert.deepEqual(inputs.map(input => input.value), ['draft one', 'draft two']);
    inputs[0].dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Enter', ctrlKey: true, bubbles: true }));
    inputs[0].dispatchEvent(new dom.window.Event('paste', { bubbles: true }));
    assert.equal(keyEvents, 1);
    assert.equal(pasted, true);
    await act(async () => checkbox.click());
    assert.deepEqual(inputs.map(input => input.inputMode), ['text', 'text']);
    assert.deepEqual(JSON.parse(window.localStorage.getItem(key)!), { useExternalKeyboard: false });
  } finally {
    await act(async () => root.unmount());
    container.remove();
  }
});

test('fresh stores restore saved true and false (reload/user reset)', () => {
  for (const enabled of [true, false]) {
    window.localStorage.setItem(key, JSON.stringify({ useExternalKeyboard: enabled }));
    assert.equal(makeStore().getState().inputPreferences.useExternalKeyboard, enabled);
  }
});

test('malformed and non-boolean storage falls back to off', () => {
  for (const raw of ['bad json', 'null', 'true', '[]', '{}', '{"useExternalKeyboard":"true"}', '{"useExternalKeyboard":1}']) {
    window.localStorage.setItem(key, raw);
    assert.equal(makeStore().getState().inputPreferences.useExternalKeyboard, false, raw);
  }
});

test('blocked storage getter safely defaults off and permits in-memory toggles', () => {
  const descriptor = Object.getOwnPropertyDescriptor(window, 'localStorage')!;
  Object.defineProperty(window, 'localStorage', { configurable: true, get() { throw new Error('blocked'); } });
  try {
    const store = makeStore();
    assert.equal(store.getState().inputPreferences.useExternalKeyboard, false);
    store.dispatch(externalKeyboardSet(true));
    assert.equal(store.getState().inputPreferences.useExternalKeyboard, true);
    store.dispatch(externalKeyboardSet(false));
    assert.equal(store.getState().inputPreferences.useExternalKeyboard, false);
  } finally {
    Object.defineProperty(window, 'localStorage', descriptor);
  }
});

test('read and write failures are tolerated; missing window is supported', () => {
  const descriptor = Object.getOwnPropertyDescriptor(window, 'localStorage')!;
  Object.defineProperty(window, 'localStorage', { configurable: true, value: {
    getItem() { throw new Error('read denied'); },
    setItem() { throw new Error('quota exceeded'); },
  } });
  try {
    const store = makeStore();
    store.dispatch(externalKeyboardSet(true));
    assert.equal(store.getState().inputPreferences.useExternalKeyboard, true);
  } finally {
    Object.defineProperty(window, 'localStorage', descriptor);
  }
  const originalWindow = globalThis.window;
  try {
    Reflect.deleteProperty(globalThis, 'window');
    const store = makeStore();
    assert.equal(store.getState().inputPreferences.useExternalKeyboard, false);
    assert.doesNotThrow(() => store.dispatch(externalKeyboardSet(true)));
  } finally {
    globalThis.window = originalWindow;
  }
});

test('cross-tab changes, removal and clear synchronize without rewriting storage', () => {
  window.localStorage.clear();
  const store = makeStore();
  const cleanup = setupInputPreferencesSync(store.dispatch);
  const emit = (eventKey: string | null, newValue: string | null, storageArea = window.localStorage) =>
    window.dispatchEvent(new dom.window.StorageEvent('storage', { key: eventKey, newValue, storageArea }));
  try {
    emit('other-key', '{"useExternalKeyboard":true}');
    assert.equal(store.getState().inputPreferences.useExternalKeyboard, false);
    emit(key, '{"useExternalKeyboard":true}', window.sessionStorage);
    assert.equal(store.getState().inputPreferences.useExternalKeyboard, false);
    emit(key, '{"useExternalKeyboard":true}');
    assert.equal(store.getState().inputPreferences.useExternalKeyboard, true);
    assert.equal(window.localStorage.getItem(key), null, 'sync must not echo writes');
    emit(key, null);
    assert.equal(store.getState().inputPreferences.useExternalKeyboard, false);
    emit(key, '{"useExternalKeyboard":true}');
    emit(null, null);
    assert.equal(store.getState().inputPreferences.useExternalKeyboard, false);
    emit(key, 'malformed');
    assert.equal(store.getState().inputPreferences.useExternalKeyboard, false);
    cleanup();
    emit(key, '{"useExternalKeyboard":true}');
    assert.equal(store.getState().inputPreferences.useExternalKeyboard, false);
  } finally {
    cleanup();
  }
});
