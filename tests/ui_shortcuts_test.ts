// REQ-SHORTCUT-MANAGER-1, REQ-SHORTCUT-SHIELD-3: pure shortcut logic coverage.
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_shortcuts_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import {
  SHORTCUT_SEQUENCE_TIMEOUT_MS,
  actionDescriptorKey,
  getChordCompletions,
  getDirectionalPaneId,
  getNextPaneId,
  getSequenceCommitAction,
  isShortcutOverrideTrigger,
  matchSequence,
  normalizeShortcutKey,
  resolveShortcutMode,
  shouldIgnoreEvent,
  type AppAction,
  type ShortcutKeyboardEvent,
} from '../src/ui/services/shortcuts/shortcutLogic.ts';
import { mergePaletteActions } from '../src/ui/components/ui/patterns/commandPaletteLogic.ts';

const actions: AppAction[] = [
  { id: 'home', title: 'Home', category: 'Navigation', sequence: ['g', 'h'], run() {} },
  { id: 'conversations', title: 'Conversations', category: 'Navigation', sequence: ['g', 'c'], run() {} },
  { id: 'disabled', title: 'Disabled', category: 'General', sequence: ['x'], isEnabled: () => false, run() {} },
];

function keyboardEvent(target: EventTarget | null, overrides: Partial<ShortcutKeyboardEvent> = {}): ShortcutKeyboardEvent {
  return {
    altKey: false,
    ctrlKey: false,
    defaultPrevented: false,
    isComposing: false,
    key: 'g',
    metaKey: false,
    repeat: false,
    target,
    ...overrides,
  };
}

test('matches exact, prefix, none, and disabled actions', () => {
  const prefix = matchSequence(['g'], actions);
  assert.equal(prefix.kind, 'prefix');
  if (prefix.kind === 'prefix') assert.deepEqual(prefix.actions.map((action) => action.id), ['home', 'conversations']);

  const exact = matchSequence(['g', 'h'], actions);
  assert.equal(exact.kind, 'exact');
  if (exact.kind === 'exact') assert.equal(exact.action.id, 'home');

  assert.deepEqual(matchSequence(['g', 'x'], actions), { kind: 'none' });
  assert.deepEqual(matchSequence(['x'], actions), { kind: 'none' });
});

test('defers an exact action when the same sequence prefixes longer chords', () => {
  const replace = { id: 'replace', title: 'Replace', category: 'Workspace' as const, sequence: ['s', 'c'], run() {} };
  const split = { id: 'split', title: 'Split', category: 'Workspace' as const, sequence: ['s', 'c', 'v'], run() {} };
  const match = matchSequence(['s', 'c'], [replace, split]);
  assert.equal(match.kind, 'prefix');
  if (match.kind === 'prefix') {
    assert.equal(match.fallbackAction?.id, 'replace');
    assert.deepEqual(match.actions.map((action) => action.id), ['split']);
  }
  assert.deepEqual(matchSequence(['s', 'c', 'v'], [replace, split]), { kind: 'exact', action: split });
});

test('Enter commits only the current enabled exact action', () => {
  const openLauncher = { id: 'open-launcher', title: 'Open launcher', category: 'Workspace' as const, sequence: ['s', 's'], run() {} };
  const splitVertical = { id: 'split-v', title: 'Split right', category: 'Workspace' as const, sequence: ['s', 's', 'v'], run() {} };
  const splitHorizontal = { id: 'split-h', title: 'Split bottom', category: 'Workspace' as const, sequence: ['s', 's', 'h'], run() {} };
  const chordActions = [openLauncher, splitVertical, splitHorizontal];

  assert.equal(getSequenceCommitAction(['s', 's'], chordActions)?.id, 'open-launcher');
  assert.deepEqual(matchSequence(['s', 's', 'v'], chordActions), { kind: 'exact', action: splitVertical });
  assert.deepEqual(matchSequence(['s', 's', 'h'], chordActions), { kind: 'exact', action: splitHorizontal });
  assert.equal(getSequenceCommitAction(['s'], chordActions), undefined);
  assert.equal(getSequenceCommitAction([], chordActions), undefined);
  assert.equal(getSequenceCommitAction(['x'], chordActions), undefined);
  assert.equal(
    getSequenceCommitAction(['s', 's'], [{ ...openLauncher, isEnabled: () => false }, splitVertical]),
    undefined,
  );
});

test('normalizes character, Escape, and arrow keys', () => {
  assert.equal(normalizeShortcutKey('G'), 'g');
  assert.equal(normalizeShortcutKey('?'), '?');
  assert.equal(normalizeShortcutKey('Escape'), 'escape');
  assert.equal(normalizeShortcutKey('ArrowLeft'), '←');
  assert.equal(normalizeShortcutKey('ArrowRight'), '→');
  assert.equal(normalizeShortcutKey('ArrowUp'), '↑');
  assert.equal(normalizeShortcutKey('ArrowDown'), '↓');
  assert.equal(SHORTCUT_SEQUENCE_TIMEOUT_MS, 1_200);
});

test('ignores modified, composing, repeated, and prevented events', () => {
  for (const override of [
    { metaKey: true },
    { ctrlKey: true },
    { altKey: true },
    { isComposing: true },
    { repeat: true },
    { defaultPrevented: true },
  ]) {
    assert.equal(shouldIgnoreEvent(keyboardEvent(null, override)), true);
  }
  assert.equal(shouldIgnoreEvent(keyboardEvent(null, { key: 'G' })), false);
});

test('Ctrl+Alt together is the explicit one-shot editable shortcut override', () => {
  assert.equal(isShortcutOverrideTrigger(keyboardEvent(null, { key: 'Alt', ctrlKey: true, altKey: true })), true);
  assert.equal(isShortcutOverrideTrigger(keyboardEvent(null, { key: 'Control', ctrlKey: true, altKey: true })), true);
  assert.equal(isShortcutOverrideTrigger(keyboardEvent(null, { key: 'AltGraph', ctrlKey: true, altKey: true })), false);
  assert.equal(isShortcutOverrideTrigger(keyboardEvent(null, { key: 'Alt', ctrlKey: true, altKey: true, repeat: true })), false);
});

test('shortcut mode follows editable focus unless the one-shot override is active', () => {
  const dom = new JSDOM('<!doctype html><body><input id="input"><div class="xterm"><span id="terminal"></span></div><button id="plain"></button></body>');
  const document = dom.window.document;
  const input = document.getElementById('input');
  const terminal = document.getElementById('terminal');
  const plain = document.getElementById('plain');

  assert.equal(resolveShortcutMode(input), 'insert');
  assert.equal(resolveShortcutMode(terminal), 'insert');
  assert.equal(resolveShortcutMode(input, true), 'normal');
  assert.equal(resolveShortcutMode(plain), 'normal');
  assert.equal(resolveShortcutMode(null), 'normal');
});

test('ignores editable, Monaco, xterm, and blocking-dialog targets', () => {
  const dom = new JSDOM(`<!doctype html><body>
    <input id="input"><textarea id="textarea"></textarea><select id="select"></select>
    <div id="editable" contenteditable="true"><span id="editable-child"></span></div>
    <div class="monaco-editor"><span id="monaco-child"></span></div>
    <div class="xterm"><span id="xterm-child"></span></div>
    <button id="plain"></button>
  </body>`);
  const document = dom.window.document;
  for (const id of ['input', 'textarea', 'select', 'editable-child', 'monaco-child', 'xterm-child']) {
    assert.equal(shouldIgnoreEvent(keyboardEvent(document.getElementById(id))), true, id);
  }
  assert.equal(shouldIgnoreEvent(keyboardEvent(document.getElementById('plain'))), false);

  const dialog = document.createElement('div');
  dialog.setAttribute('role', 'dialog');
  document.body.append(dialog);
  assert.equal(shouldIgnoreEvent(keyboardEvent(document.getElementById('plain'))), true);

  dialog.dataset.shortcutCheatsheet = 'true';
  assert.equal(shouldIgnoreEvent(keyboardEvent(document.getElementById('plain'))), false);
});

test('descriptor keys ignore callback identity but include registration metadata', () => {
  const first = [{ ...actions[0], run() {} }];
  const second = [{ ...actions[0], run() { throw new Error('fresh callback'); } }];
  assert.equal(actionDescriptorKey(first), actionDescriptorKey(second));
  assert.notEqual(actionDescriptorKey(first), actionDescriptorKey([{ ...second[0], title: 'Start' }]));
});

test('chord completions group actions by the next key after the active prefix', () => {
  const matches = [
    ...actions,
    { id: 'history', title: 'History', category: 'Navigation' as const, sequence: ['g', 'h', 'i'], run() {} },
  ];
  assert.deepEqual(getChordCompletions(['g'], matches), [
    { key: 'h', titles: ['Home', 'History'] },
    { key: 'c', titles: ['Conversations'] },
  ]);
});

test('palette merging keeps static actions and adapts only enabled live shortcuts', () => {
  const merged = mergePaletteActions(
    [{ id: 'static', label: 'Static action', route: '/static' }],
    [
      actions[0],
      { ...actions[2], title: 'Hidden action' },
      { ...actions[0], id: 'static', title: 'Live override', sequence: ['g', 'o'] },
    ],
  );

  assert.deepEqual(merged, [
    { id: 'static', label: 'Live override', hint: 'Shortcut: g o', badge: 'g o' },
    { id: 'home', label: 'Home', hint: 'Shortcut: g h', badge: 'g h' },
  ]);
});

test('pane focus cycling advances and wraps in tree order', () => {
  const paneIds = ['pane-1', 'pane-2', 'pane-3'];
  assert.equal(getNextPaneId(paneIds, 'pane-1'), 'pane-2');
  assert.equal(getNextPaneId(paneIds, 'pane-2'), 'pane-3');
  assert.equal(getNextPaneId(paneIds, 'pane-3'), 'pane-1');
  assert.equal(getNextPaneId(paneIds, 'missing'), 'pane-1');
  assert.equal(getNextPaneId([], 'pane-1'), undefined);
});

test('directional pane focus chooses the nearest pane in the requested half-plane', () => {
  const layouts = [
    { paneId: 'left', left: 0, top: 0, width: 50, height: 100 },
    { paneId: 'top-right', left: 50, top: 0, width: 50, height: 50 },
    { paneId: 'bottom-right', left: 50, top: 50, width: 50, height: 50 },
  ];
  assert.equal(getDirectionalPaneId(layouts, 'bottom-right', 'up'), 'top-right');
  assert.equal(getDirectionalPaneId(layouts, 'top-right', 'down'), 'bottom-right');
  assert.equal(getDirectionalPaneId(layouts, 'top-right', 'left'), 'left');
  assert.equal(getDirectionalPaneId(layouts, 'left', 'right'), 'top-right');
  assert.equal(getDirectionalPaneId(layouts, 'left', 'left'), undefined);
});
