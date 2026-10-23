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
    let inputs = [...container.querySelectorAll('textarea')];
    assert.equal(checkbox.checked, false);
    assert.ok(checkbox.closest('label')?.textContent?.includes('Use external keyboard'));
    assert.match(document.getElementById(checkbox.getAttribute('aria-describedby')!)!.textContent!, /Hide the on-screen keyboard in message composers\. Turn off to type on screen\./);
    assert.deepEqual(inputs.map(input => input.inputMode), ['text', 'text']);
    // Clicking the containing label exercises the native touch-accessible control.
    await act(async () => checkbox.closest('label')!.click());
    assert.equal(checkbox.checked, true);
    assert.equal(store.getState().inputPreferences.useExternalKeyboard, true);
    assert.deepEqual(JSON.parse(window.localStorage.getItem(key)!), { useExternalKeyboard: true });
    const oldInputs = inputs;
    inputs = [...container.querySelectorAll('textarea')];
    assert.ok(oldInputs.every(input => !input.isConnected));
    assert.deepEqual(inputs.map(input => input.inputMode), ['none', 'none']);
    assert.equal(ref.current, inputs[0]);
    assert.deepEqual(inputs.map(input => input.value), ['draft one', 'draft two']);
    inputs[0].dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Enter', ctrlKey: true, bubbles: true }));
    inputs[0].dispatchEvent(new dom.window.Event('paste', { bubbles: true }));
    assert.equal(keyEvents, 1);
    assert.equal(pasted, true);
    await act(async () => checkbox.click());
    inputs = [...container.querySelectorAll('textarea')];
    assert.deepEqual(inputs.map(input => input.inputMode), ['text', 'text']);
    assert.equal(ref.current, inputs[0]);
    assert.deepEqual(JSON.parse(window.localStorage.getItem(key)!), { useExternalKeyboard: false });
  } finally {
    await act(async () => root.unmount());
    container.remove();
  }
});

test('mode replacement preserves controlled editing, selection, focus, refs and resize ownership', async () => {
  window.localStorage.clear();
  const store = makeStore();
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  const ref = React.createRef<HTMLTextAreaElement>();
  const observed: { node?: Element; disconnected: boolean; notify: () => void }[] = [];
  const originalObserver = globalThis.ResizeObserver;
  const originalFrame = globalThis.requestAnimationFrame;
  globalThis.ResizeObserver = class {
    record: typeof observed[number];
    constructor(notify: () => void) {
      this.record = { disconnected: false, notify };
      observed.push(this.record);
    }
    observe(node: Element) { this.record.node = node; }
    disconnect() { this.record.disconnected = true; }
  } as unknown as typeof ResizeObserver;
  globalThis.requestAnimationFrame = callback => { callback(0); return 1; };
  let edited = '';
  function Editor() {
    const [draft, setDraft] = React.useState('controlled draft');
    return React.createElement(MessageComposerInput, {
      mobile: true, debugId: 'controlled-editor', ref, value: draft,
      onChange: event => { edited = event.target.value; setDraft(edited); },
    });
  }
  try {
    await act(async () => root.render(React.createElement(Provider, { store, children: [
      React.createElement(Editor, { key: 'editor' }),
      React.createElement('button', { key: 'button' }, 'Other control'),
    ] })));
    let input = ref.current!;
    input.focus();
    input.setSelectionRange(2, 8, 'backward');
    input.scrollTop = 5;
    for (const enabled of [true, false]) {
      const previous = input;
      const oldObserver = observed.at(-1)!;
      await act(async () => store.dispatch(externalKeyboardSet(enabled)));
      input = ref.current!;
      assert.notEqual(input, previous);
      assert.equal(previous.isConnected, false);
      assert.equal(input.inputMode, enabled ? 'none' : 'text');
      assert.equal(input.value, 'controlled draft');
      assert.equal(document.activeElement, input);
      assert.deepEqual([input.selectionStart, input.selectionEnd, input.selectionDirection], [2, 8, 'backward']);
      assert.equal(input.scrollTop, 5);
      assert.equal(oldObserver.disconnected, true);
      const observer = observed.at(-1)!;
      assert.equal(observer.node, input);
      assert.equal(observer.disconnected, false);
      Object.defineProperty(input, 'scrollHeight', { configurable: true, value: 120 });
      Object.defineProperty(input, 'clientWidth', { configurable: true, value: 240 });
      observer.notify();
      assert.equal(input.style.height, '72px');
      assert.equal(input.style.overflowY, 'auto');
    }
    // Real DOM input events must still update the caller's controlled draft.
    const setValue = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, 'value')!.set!;
    setValue.call(input, 'hardware typing');
    await act(async () => input.dispatchEvent(new dom.window.Event('input', { bubbles: true })));
    assert.equal(edited, 'hardware typing');
    assert.equal(ref.current, input, 'ordinary draft updates must retain the editor');
    const button = container.querySelector('button')!;
    button.focus();
    await act(async () => store.dispatch(externalKeyboardSet(true)));
    assert.equal(document.activeElement, button, 'settings changes must not steal focus');
    assert.equal(ref.current!.value, 'hardware typing');
    await act(async () => root.unmount());
    assert.ok(observed.every(observer => observer.disconnected));
    assert.equal(ref.current, null);
  } finally {
    await act(async () => root.unmount());
    container.remove();
    globalThis.ResizeObserver = originalObserver;
    globalThis.requestAnimationFrame = originalFrame;
  }
});

test('saved enabled preference initializes new native editors in none mode', async () => {
  window.localStorage.setItem(key, JSON.stringify({ useExternalKeyboard: true }));
  const store = makeStore();
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  try {
    await act(async () => root.render(React.createElement(Provider, { store,
      children: React.createElement(MessageComposerInput, { mobile: true, debugId: 'restored-editor', defaultValue: 'draft' }),
    })));
    assert.equal(container.querySelector('textarea')!.inputMode, 'none');
    const input = container.querySelector('textarea')!;
    input.value = 'native draft';
    await act(async () => store.dispatch(externalKeyboardSet(false)));
    assert.equal(container.querySelector('textarea')!.value, 'native draft');
    assert.equal(container.querySelector('textarea')!.inputMode, 'text');
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
