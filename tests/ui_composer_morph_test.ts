import assert from 'node:assert/strict';
import { after, afterEach, test } from 'node:test';
import { JSDOM } from 'jsdom';
import React, { act } from 'react';
import { configureStore } from '@reduxjs/toolkit';
import { Provider } from 'react-redux';

// REQ-MORPH-1..5/8: the opt-in morphing composer primitive. Legacy (unopted) callers such as
// NewConversationPage must keep the classic DOM.
const dom = new JSDOM('<!doctype html><html><body></body></html>', { url: 'https://heimdall.test/', pretendToBeVisual: true });
let frames = 0;
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
  ResizeObserver: class { observe() {} disconnect() {} },
  requestAnimationFrame: (callback: FrameRequestCallback) => { frames++; return setTimeout(() => callback(0), 0) as unknown as number; },
  cancelAnimationFrame: (id: number) => clearTimeout(id),
});
const { createRoot } = await import('react-dom/client');
const { default: inputPreferences, externalKeyboardSet } = await import('../src/ui/store/inputPreferencesSlice.ts');
const {
  MessageComposerActions, MessageComposerInput, MessageComposerMorphShell, MORPH_CSS,
  composerExpansionReasons, useComposerDockInset, useComposerExpanded,
} = await import('../src/ui/components/chat/MessageComposer.tsx');
type Inputs = import('../src/ui/components/chat/MessageComposer.tsx').ComposerExpansionInputs;
type Expansion = import('../src/ui/components/chat/MessageComposer.tsx').ComposerExpansion;
after(() => dom.window.close());

const h = React.createElement;
const cleanups: (() => Promise<void>)[] = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0)) await cleanup(); });

async function mount(element: React.ReactElement) {
  const store = configureStore({ reducer: { inputPreferences } });
  const container = document.createElement('div');
  document.body.append(container);
  const root = createRoot(container);
  await act(async () => root.render(h(Provider, { store, children: element })));
  cleanups.push(async () => { await act(async () => root.unmount()); container.remove(); });
  return { store, container, render: (next: React.ReactElement) => act(async () => root.render(h(Provider, { store, children: next }))) };
}

const q = <T extends Element = HTMLElement>(container: Element, id: string) => container.querySelector<T>(`[data-debug-id="${id}"]`);
const actionsProps = { debugPrefix: 'conversation', mobile: false, provider: 'claude', model: 'opus', onSettings: () => {}, onUpload: () => {}, onOpenTasks: () => {}, onPaneToggle: () => {} };

let lastExpansion: Expansion | undefined;
/** Every committed expansion, so transient collapses between focusout and focusin show up. */
const committed: boolean[] = [];
function Morph({ inputs = {}, initialDraft = '', onFieldKeyDown, outside = true, sendDisabled, onUpload, onPaneToggle }: { inputs?: Partial<Inputs>; initialDraft?: string; onFieldKeyDown?: (event: React.KeyboardEvent<HTMLTextAreaElement>) => void; outside?: boolean; sendDisabled?: boolean; onUpload?: () => void; onPaneToggle?: () => void }) {
  const [draft, setDraft] = React.useState(initialDraft);
  const expansion = useComposerExpanded({ draft, ...inputs });
  lastExpansion = expansion;
  React.useLayoutEffect(() => { committed.push(expansion.expanded); });
  return h(React.Fragment, null,
    h(MessageComposerMorphShell, {
      expansion, debugPrefix: 'conversation',
      context: h('button', { type: 'button', 'data-debug-id': 'conversation-composer-bridge-chip' }, 'riverwood'),
      actions: h(MessageComposerActions, { ...actionsProps, ...(onUpload ? { onUpload } : {}), ...(onPaneToggle ? { onPaneToggle } : {}), sendDisabled: sendDisabled ?? draft.trim().length === 0, morph: { expanded: expansion.expanded }, pendingActions: inputs.pendingActions ? h('button', { type: 'button', 'data-debug-id': 'pending-approve-btn' }, 'Approve') : undefined, readOnly: inputs.readOnly }),
      children: h(MessageComposerInput, { morph: true, mobile: false, debugId: 'conversation-composer-input', value: draft, placeholder: 'Message the agent', onChange: event => setDraft(event.target.value), onKeyDown: onFieldKeyDown }),
    }),
    outside ? h('button', { type: 'button', 'data-debug-id': 'outside-btn' }, 'Elsewhere') : null,
  );
}
const shellOf = (container: Element) => q(container, 'conversation-composer-morph')!;
const fieldOf = (container: Element) => q<HTMLTextAreaElement>(container, 'conversation-composer-input')!;
const expandedOf = (container: Element) => shellOf(container).getAttribute('data-expanded');

test('collapsed by default; hidden context and tools are inert and aria-hidden, chip and send stay reachable', async () => {
  const { container } = await mount(h(Morph));
  assert.equal(expandedOf(container), 'false');
  assert.deepEqual(lastExpansion!.reasons, []);
  for (const id of ['conversation-composer-morph-context', 'conversation-composer-morph-tools']) {
    const region = q(container, id)!;
    assert.equal(region.getAttribute('inert'), '', `${id} must leave the tab order`);
    assert.equal(region.getAttribute('aria-hidden'), 'true', `${id} must leave the accessibility tree`);
  }
  // The classic toolbar IDs survive inside the morph layout.
  for (const id of ['conversation-composer-toolbar', 'conversation-attach-btn', 'conversation-request-pane-btn', 'conversation-tasks-btn', 'conversation-runtime-menu-btn', 'conversation-composer-send-btn', 'conversation-composer-morph-trailing', 'conversation-composer-morph-spacer']) {
    assert.ok(q(container, id), `missing ${id}`);
  }
  assert.equal(q(container, 'conversation-composer-morph-trailing')!.closest('[inert]'), null);
  const send = q<HTMLButtonElement>(container, 'conversation-composer-send-btn')!;
  assert.equal(send.disabled, true, 'empty draft dims and disables send');
  const field = fieldOf(container);
  assert.equal(field.rows, 1);
  assert.equal(field.hasAttribute('data-composer-morph-field'), true);
});

test('focus opens; moving focus between the field and composer controls keeps it open; leaving collapses', async () => {
  const { container } = await mount(h(Morph));
  const field = fieldOf(container);
  await act(async () => field.focus());
  assert.equal(expandedOf(container), 'true');
  assert.deepEqual(lastExpansion!.reasons, ['focus']);
  assert.equal(q(container, 'conversation-composer-morph-tools')!.hasAttribute('inert'), false);
  assert.equal(q(container, 'conversation-composer-morph-context')!.hasAttribute('aria-hidden'), false);
  committed.length = 0;
  // Separate acts per native event: React renders between focusout and focusin, so a
  // containment bug would commit a collapsed (inert) frame while focus is in transit.
  const tasks = q<HTMLButtonElement>(container, 'conversation-tasks-btn')!;
  const chip = q<HTMLButtonElement>(container, 'conversation-composer-bridge-chip')!;
  for (const [from, to] of [[field, tasks], [tasks, chip]] as const) {
    await act(async () => { from.dispatchEvent(new dom.window.FocusEvent('focusout', { bubbles: true, relatedTarget: to })); });
    await act(async () => { to.focus(); });
  }
  assert.equal(expandedOf(container), 'true', 'relatedTarget inside the composer keeps it open');
  assert.ok(committed.every(Boolean), `no collapsed frame while moving focus inside: ${committed}`);
  await act(async () => q<HTMLButtonElement>(container, 'outside-btn')!.focus());
  assert.equal(expandedOf(container), 'false');
  assert.equal(lastExpansion!.focusWithin, false);
});

/** jsdom has no PointerEvent: a MouseEvent carrying the pointer fields the hook reads. */
function pointerish(type: string, pointerType: 'mouse' | 'touch', button = 0) {
  const event = new dom.window.MouseEvent(type, { bubbles: true, cancelable: true, button });
  if (type.startsWith('pointer')) Object.defineProperties(event, { pointerType: { value: pointerType }, isPrimary: { value: true } });
  return event;
}

/** A press the way WebKit (Safari, iOS) delivers it: the pressed <button> never takes focus,
 *  so the field blurs to <body> (relatedTarget null). Desktop Safari blurs on mousedown,
 *  before pointerup; iOS sends pointerdown/pointerup at touch time and the compatibility
 *  mousedown (with the blur) just before click. The click is only delivered when the target
 *  is still hit-testable: a browser never dispatches it into an inert subtree, and jsdom does
 *  not model inert, so that check is made here, at the moment the click would be dispatched. */
async function webkitPress(target: HTMLElement, order: 'desktop' | 'ios' = 'desktop') {
  const fire = (type: string) => act(async () => { target.dispatchEvent(pointerish(type, order === 'ios' ? 'touch' : 'mouse')); });
  const blurField = () => act(async () => { (document.activeElement as HTMLElement | null)?.blur(); });
  await fire('pointerdown');
  if (order === 'desktop') { await fire('mousedown'); await blurField(); await fire('pointerup'); await fire('mouseup'); }
  else { await fire('pointerup'); await fire('mousedown'); await blurField(); await fire('mouseup'); }
  if (target.closest('[inert]') || (target as HTMLButtonElement).disabled) return false;
  await act(async () => { target.click(); });
  return true;
}

for (const order of ['desktop', 'ios'] as const) {
  test(`WebKit ${order} press on + and terminal (blur relatedTarget null, button never focused) runs the handler and keeps the composer open`, async () => {
    const calls: string[] = [];
    const { container } = await mount(h(Morph, { onUpload: () => calls.push('upload'), onPaneToggle: () => calls.push('terminal') }));
    const field = fieldOf(container);
    await act(async () => field.focus());
    committed.length = 0;
    for (const [id, call] of [['conversation-attach-btn', 'upload'], ['conversation-request-pane-btn', 'terminal']] as const) {
      const button = q<HTMLButtonElement>(container, id)!;
      assert.equal(await webkitPress(button, order), true, `${id} was inert (collapsed) when its click would be dispatched`);
      assert.equal(calls.at(-1), call, `${id} handler ran`);
      assert.notEqual(document.activeElement, button, 'models WebKit: the button did not take focus');
      assert.equal(expandedOf(container), 'true');
    }
    assert.deepEqual(calls, ['upload', 'terminal']);
    assert.ok(committed.every(Boolean), `no collapsed frame during either press: ${committed}`);
    // Engaged with focus on <body>: a press truly outside ends it.
    const outside = q<HTMLButtonElement>(container, 'outside-btn')!;
    await webkitPress(outside, order);
    assert.equal(expandedOf(container), 'false', 'a press outside the composer collapses it');
    assert.equal(lastExpansion!.focusWithin, false);
  });
}

test('after a WebKit control press, focus returning to the field, Tab/Shift+Tab inside, or focus leaving resolve correctly', async () => {
  const { container } = await mount(h(Morph));
  const field = fieldOf(container);
  await act(async () => field.focus());
  await webkitPress(q<HTMLButtonElement>(container, 'conversation-tasks-btn')!);
  assert.equal(expandedOf(container), 'true');
  // Keyboard focus anywhere in the composer (Tab / Shift+Tab land on its controls) keeps it open.
  const bridge = q<HTMLButtonElement>(container, 'conversation-composer-bridge-chip')!;
  await act(async () => bridge.focus());
  assert.equal(expandedOf(container), 'true');
  await act(async () => field.focus());
  assert.equal(expandedOf(container), 'true');
  // Held again, then keyboard focus moves outside (Tab past the composer): collapses.
  await webkitPress(q<HTMLButtonElement>(container, 'conversation-attach-btn')!);
  assert.equal(expandedOf(container), 'true');
  await act(async () => q<HTMLButtonElement>(container, 'outside-btn')!.focus());
  assert.equal(expandedOf(container), 'false', 'focus moving outside ends the press hold');
  // A completed press inside (into the field) does not leak a hold into a later plain blur.
  await webkitPress(field);
  await act(async () => field.focus());
  await act(async () => field.blur());
  assert.equal(expandedOf(container), 'false', 'blur to <body> without a composer press collapses');
});

test('presses that never click (disabled send, right-click, cancelled touch) do not arm a hold for a later blur', async () => {
  const { container } = await mount(h(Morph));
  const field = fieldOf(container);
  const send = q<HTMLButtonElement>(container, 'conversation-composer-send-btn')!;
  assert.equal(send.disabled, true);
  const cases: [string, HTMLElement, () => Promise<void>][] = [
    ['disabled send', send, () => act(async () => { send.dispatchEvent(pointerish('pointerdown', 'touch')); })],
    ['right-click', q<HTMLButtonElement>(container, 'conversation-attach-btn')!, () => act(async () => { q(container, 'conversation-attach-btn')!.dispatchEvent(pointerish('pointerdown', 'mouse', 2)); })],
    ['cancelled touch', q<HTMLButtonElement>(container, 'conversation-attach-btn')!, async () => {
      await act(async () => { q(container, 'conversation-attach-btn')!.dispatchEvent(pointerish('pointerdown', 'touch')); });
      await act(async () => { q(container, 'conversation-attach-btn')!.dispatchEvent(pointerish('pointercancel', 'touch')); });
    }],
    ['mouse press released without a click', q<HTMLButtonElement>(container, 'conversation-attach-btn')!, async () => {
      await act(async () => { q(container, 'conversation-attach-btn')!.dispatchEvent(pointerish('pointerdown', 'mouse')); });
      await act(async () => { q(container, 'conversation-attach-btn')!.dispatchEvent(pointerish('pointerup', 'mouse')); });
    }],
  ];
  for (const [label, , pressWithoutClick] of cases) {
    await act(async () => field.focus());
    assert.equal(expandedOf(container), 'true');
    await pressWithoutClick();
    // Later, focus goes nowhere with no press in progress (iOS keyboard "Done", programmatic blur).
    await act(async () => field.blur());
    assert.equal(expandedOf(container), 'false', `${label}: a later blur to <body> collapses`);
  }
});

test('window blur (relatedTarget null, document unfocused) keeps it open like :focus-within', async () => {
  const { container } = await mount(h(Morph));
  const field = fieldOf(container);
  await act(async () => field.focus());
  const hasFocus = document.hasFocus;
  document.hasFocus = () => false;
  try {
    await act(async () => { field.dispatchEvent(new dom.window.FocusEvent('focusout', { bubbles: true, relatedTarget: null })); });
    assert.equal(expandedOf(container), 'true');
  } finally { document.hasFocus = hasFocus; }
  // A real blur to <body> with the document focused collapses.
  await act(async () => field.blur());
  assert.equal(expandedOf(container), 'false');
});

test('any draft character holds it open after blur, including whitespace and restored drafts', async () => {
  const restored = await mount(h(Morph, { initialDraft: 'restored draft' }));
  assert.equal(expandedOf(restored.container), 'true');
  assert.deepEqual(lastExpansion!.reasons, ['draft']);
  assert.equal(q(restored.container, 'conversation-composer-morph-tools')!.hasAttribute('inert'), false);

  const { container } = await mount(h(Morph));
  const field = fieldOf(container);
  await act(async () => field.focus());
  const setValue = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, 'value')!.set!;
  setValue.call(field, ' ');
  await act(async () => field.dispatchEvent(new dom.window.Event('input', { bubbles: true })));
  await act(async () => q<HTMLButtonElement>(container, 'outside-btn')!.focus());
  assert.equal(expandedOf(container), 'true', 'whitespace-only draft keeps it open');
  assert.equal(q<HTMLButtonElement>(container, 'conversation-composer-send-btn')!.disabled, true, 'whitespace alone does not enable send');
  setValue.call(field, 'hello');
  await act(async () => field.dispatchEvent(new dom.window.Event('input', { bubbles: true })));
  assert.equal(q<HTMLButtonElement>(container, 'conversation-composer-send-btn')!.disabled, false);
  setValue.call(field, '');
  await act(async () => field.dispatchEvent(new dom.window.Event('input', { bubbles: true })));
  assert.equal(expandedOf(container), 'false', 'clearing a blurred field collapses');
});

test('explicit flags (attachments, quotes, borrowed, owned menu/portal, upload, pending, read-only) each hold it open', async () => {
  const flags: [keyof Inputs, string][] = [['hasAttachments', 'attachments'], ['hasQuotes', 'quotes'], ['borrowed', 'borrowed'], ['menuOpen', 'menu'], ['uploadActive', 'upload'], ['pendingActions', 'pending-actions'], ['readOnly', 'read-only']];
  for (const [flag, reason] of flags) {
    assert.deepEqual(composerExpansionReasons({ draft: '', [flag]: true }, false), [reason]);
  }
  assert.deepEqual(composerExpansionReasons({ draft: '' }, false), []);
  assert.deepEqual(composerExpansionReasons({ draft: 'x', hasQuotes: true }, true), ['focus', 'draft', 'quotes']);

  // Portal ownership: focus leaves the DOM subtree for a menu, yet the composer stays open.
  const { container, render } = await mount(h(Morph, { inputs: { menuOpen: false } }));
  await act(async () => fieldOf(container).focus());
  await render(h(Morph, { inputs: { menuOpen: true } }));
  await act(async () => q<HTMLButtonElement>(container, 'outside-btn')!.focus());
  assert.equal(expandedOf(container), 'true');
  assert.deepEqual(lastExpansion!.reasons, ['menu']);
  await render(h(Morph, { inputs: { menuOpen: false } }));
  assert.equal(expandedOf(container), 'false');
});

test('pending actions replace send and tools; read-only keeps the chip but no send', async () => {
  const pending = await mount(h(Morph, { inputs: { pendingActions: true } }));
  assert.equal(expandedOf(pending.container), 'true');
  assert.ok(q(pending.container, 'pending-approve-btn'));
  assert.equal(q(pending.container, 'conversation-composer-send-btn'), null);
  assert.equal(q(pending.container, 'conversation-composer-morph-tools'), null);
  assert.equal(q(pending.container, 'pending-approve-btn')!.closest('[inert]'), null);

  const readOnly = await mount(h(Morph, { inputs: { readOnly: true } }));
  assert.equal(q(readOnly.container, 'conversation-composer-send-btn'), null);
  assert.ok(q(readOnly.container, 'conversation-runtime-menu-btn'));
  assert.equal(q(readOnly.container, 'conversation-composer-morph-tools'), null);
});

test('Escape on an empty field blurs and collapses; drafts, IME composition, open menus and handled events are left alone', async () => {
  let fieldKeys: string[] = [];
  const { container, render } = await mount(h(Morph, { onFieldKeyDown: event => fieldKeys.push(`${event.ctrlKey || event.metaKey ? 'mod+' : ''}${event.key}`) }));
  const field = fieldOf(container);
  const esc = (init: KeyboardEventInit = {}) => act(async () => { field.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true, ...init })); });

  await act(async () => field.focus());
  await esc({ isComposing: true });
  assert.equal(document.activeElement, field, 'IME composition owns Escape');
  await esc({ keyCode: 229 });
  assert.equal(document.activeElement, field);
  await act(async () => { field.addEventListener('keydown', function handled(event) { event.preventDefault(); field.removeEventListener('keydown', handled); }); });
  await esc();
  assert.equal(document.activeElement, field, 'an earlier handler that consumed Escape wins');

  await render(h(Morph, { inputs: { menuOpen: true }, onFieldKeyDown: event => fieldKeys.push(event.key) }));
  await esc();
  assert.equal(document.activeElement, field, 'an open owned menu dismisses first');
  await render(h(Morph, { onFieldKeyDown: event => fieldKeys.push(`${event.ctrlKey || event.metaKey ? 'mod+' : ''}${event.key}`) }));

  const setValue = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, 'value')!.set!;
  setValue.call(field, 'keep me');
  await act(async () => field.dispatchEvent(new dom.window.Event('input', { bubbles: true })));
  await esc();
  assert.equal(document.activeElement, field, 'Escape never discards or blurs a draft');
  setValue.call(field, '');
  await act(async () => field.dispatchEvent(new dom.window.Event('input', { bubbles: true })));

  fieldKeys = [];
  let event!: KeyboardEvent;
  await act(async () => { event = new dom.window.KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }); field.dispatchEvent(event); });
  assert.notEqual(document.activeElement, field);
  assert.equal(event.defaultPrevented, true);
  assert.equal(expandedOf(container), 'false');
  assert.deepEqual(fieldKeys, ['Escape'], 'the caller still sees the key first');

  // Cmd/Ctrl+Enter still reaches the caller's handler untouched.
  await act(async () => field.focus());
  await act(async () => { event = new dom.window.KeyboardEvent('keydown', { key: 'Enter', ctrlKey: true, bubbles: true, cancelable: true }); field.dispatchEvent(event); });
  assert.deepEqual(fieldKeys, ['Escape', 'mod+Enter']);
  assert.equal(event.defaultPrevented, false);
});

test('background press focuses the field; presses on child controls are not hijacked', async () => {
  let opened = 0;
  function WithChip() {
    const expansion = useComposerExpanded({ draft: '' });
    return h(MessageComposerMorphShell, {
      expansion, debugPrefix: 'conversation',
      actions: h(MessageComposerActions, { ...actionsProps, onSettings: () => { opened++; }, sendDisabled: true, morph: { expanded: expansion.expanded } }),
      children: h(MessageComposerInput, { morph: true, mobile: true, debugId: 'conversation-composer-input', defaultValue: '' }),
    });
  }
  const { container } = await mount(h(WithChip));
  const shell = shellOf(container);
  const field = fieldOf(container);
  let press!: MouseEvent;
  await act(async () => { press = new dom.window.MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0 }); shell.dispatchEvent(press); });
  assert.equal(document.activeElement, field);
  assert.equal(press.defaultPrevented, true, 'focus is not dropped to <body> by the press');
  assert.equal(expandedOf(container), 'true');

  // Pressing the spacer of an already-open composer keeps focus in the field.
  await act(async () => { q(container, 'conversation-composer-morph-spacer')!.dispatchEvent(new dom.window.MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0 })); });
  assert.equal(document.activeElement, field);

  const chip = q<HTMLButtonElement>(container, 'conversation-runtime-menu-btn')!;
  await act(async () => { press = new dom.window.MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0 }); chip.dispatchEvent(press); });
  assert.equal(press.defaultPrevented, false, 'child controls keep their native press');
  await act(async () => chip.click());
  assert.equal(opened, 1);

  // Secondary button presses (context menu) are ignored.
  await act(async () => field.blur());
  await act(async () => { shell.dispatchEvent(new dom.window.MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 2 })); });
  assert.notEqual(document.activeElement, field);
});

test('morph field: CSS-owned height (content var only), no per-frame JS, and keyboard-mode replacement keeps focus and draft', async () => {
  frames = 0;
  const ref = React.createRef<HTMLTextAreaElement>();
  function Field() {
    const [draft, setDraft] = React.useState('two\nlines');
    const expansion = useComposerExpanded({ draft });
    return h(MessageComposerMorphShell, { expansion, debugPrefix: 'conversation', children: h(MessageComposerInput, { morph: true, mobile: true, ref, debugId: 'conversation-composer-input', value: draft, onChange: event => setDraft(event.target.value) }) });
  }
  const { container, store } = await mount(h(Field));
  const field = ref.current!;
  assert.equal(field.style.height, '', 'no inline height that would block the CSS transition');
  assert.match(field.style.getPropertyValue('--composer-morph-field-content'), /^\d+px$/);
  await act(async () => field.focus());
  field.setSelectionRange(1, 3);
  await act(async () => fieldOf(container).blur());
  await act(async () => field.focus());
  assert.equal(frames, 0, 'opening and closing schedule no animation frames');

  await act(async () => store.dispatch(externalKeyboardSet(true)));
  const replaced = ref.current!;
  assert.notEqual(replaced, field);
  assert.equal(replaced.inputMode, 'none');
  assert.equal(replaced.value, 'two\nlines');
  assert.equal(document.activeElement, replaced);
  assert.deepEqual([replaced.selectionStart, replaced.selectionEnd], [1, 3]);
  assert.equal(replaced.hasAttribute('data-composer-morph-field'), true);
  assert.equal(expandedOf(container), 'true');
});

test('motion CSS follows the reference timing and respects reduced motion', () => {
  assert.match(MORPH_CSS, /--cm-d: var\(--duration-slow, 300ms\); --cm-e: var\(--ease-emphasized, cubic-bezier\(0\.22, 1, 0\.36, 1\)\)/);
  assert.match(MORPH_CSS, /--cm-d: var\(--duration-base, 200ms\); --cm-e: var\(--ease-standard,/);
  assert.match(MORPH_CSS, /grid-template-rows: 0fr/);
  assert.match(MORPH_CSS, /\[data-expanded='true'\] \[data-composer-morph-head\] \{ grid-template-rows: 1fr \}/);
  assert.match(MORPH_CSS, /\[data-composer-morph-context\] \{ opacity: 1; transform: none; transition-delay: 60ms \}/);
  assert.match(MORPH_CSS, /\[data-composer-morph-tools\] \{ opacity: 1;[^}]*80ms,[^}]*80ms, visibility 0s \}/);
  assert.match(MORPH_CSS, /\[data-composer-morph-tools\] \{[^}]*visibility: hidden;/, 'collapsed tools are hidden after fading');
  assert.match(MORPH_CSS, /\[data-composer-morph-field\] \{ height: 24px;/);
  assert.match(MORPH_CSS, /height: clamp\(48px, var\(--composer-morph-field-content, 48px\), 144px\)/);
  assert.match(MORPH_CSS, /\[data-composer-morph-spacer\] \{ height: 16px;/);
  assert.match(MORPH_CSS, /\[data-composer-morph-spacer\] \{ height: 76px \}/);
  assert.match(MORPH_CSS, /\[data-composer-morph-chip\] \{ height: 32px;/);
  assert.match(MORPH_CSS, /\[data-composer-morph-chip\] \{ height: 40px;/);
  assert.match(MORPH_CSS, /\[data-composer-morph-send\] \{ width: 40px; height: 40px;/);
  assert.match(MORPH_CSS, /\[data-composer-morph-send\] \{ width: 44px; height: 44px \}/);
  assert.match(MORPH_CSS, /@media \(prefers-reduced-motion: reduce\) \{\s*\[data-composer-morph\], \[data-composer-morph\] \* \{ transition-duration: 1ms !important; transition-delay: 0ms !important \}/);
});

test('unopted callers (NewConversationPage) keep the classic input and toolbar DOM', async () => {
  const { container } = await mount(h('form', null,
    h(MessageComposerInput, { mobile: false, debugId: 'new-convo-input', defaultValue: '' }),
    h(MessageComposerInput, { mobile: true, debugId: 'new-convo-input-mobile', defaultValue: '' }),
    h(MessageComposerActions, { ...actionsProps, debugPrefix: 'new-convo', sendDisabled: true }),
  ));
  assert.equal(container.querySelector('[data-composer-morph], [data-composer-morph-field], [data-composer-morph-tools], [data-composer-morph-toolbar], style'), null);
  const desktop = q<HTMLTextAreaElement>(container, 'new-convo-input')!;
  const mobile = q<HTMLTextAreaElement>(container, 'new-convo-input-mobile')!;
  assert.equal(desktop.rows, 2);
  // main's composerInputClassName(mobile, 'pane', false) output, unchanged by the morph opt-in.
  assert.equal(desktop.className, 'min-h-[44px] w-full resize-none bg-transparent text-primary outline-none placeholder:text-muted px-1 py-1 text-sm');
  assert.equal(mobile.rows, 1);
  assert.equal(mobile.className, 'block min-h-6 max-h-[72px] w-full resize-none bg-transparent text-primary outline-none placeholder:text-muted p-0 text-base leading-6');
  assert.equal(mobile.style.getPropertyValue('--composer-morph-field-content'), '');
  assert.equal(mobile.style.height, '24px', 'mobile auto-size still owns the inline height');
  const toolbar = q(container, 'new-convo-composer-toolbar')!;
  assert.equal(toolbar.className, 'mt-2 flex min-w-0 items-center justify-between gap-1.5');
  assert.equal(q(container, 'new-convo-composer-send-btn')!.className, 'grid h-9 w-9 rounded-xl shrink-0 place-items-center bg-accent text-accent-fg disabled:opacity-40');
  assert.equal(container.querySelector('[inert], [aria-hidden="true"]:not(svg)'), null);
});

test('open trailing group reserves the tool row width so a long model chip truncates instead of covering tools', async () => {
  const widths: Record<string, string> = {};
  for (const [label, props] of [
    ['three', {}],
    ['one', { onOpenTasks: undefined, onPaneToggle: undefined }],
    ['extra', { extraActions: h(React.Fragment, null, h('button', { type: 'button', key: 'a' }, 'a'), h('button', { type: 'button', key: 'b' }, 'b')) }],
    ['pending', { pendingActions: h('button', { type: 'button' }, 'Apply') }],
  ] as const) {
    const { container } = await mount(h(MessageComposerActions, { ...actionsProps, ...props, sendDisabled: true, morph: { expanded: true } } as any));
    widths[label] = q(container, 'conversation-composer-toolbar')!.style.getPropertyValue('--composer-morph-tools-width');
  }
  // 44px buttons with 4px gaps; tools are not rendered beside pending actions.
  assert.deepEqual(widths, { three: '140px', one: '44px', extra: '236px', pending: '0px' });
  assert.match(MORPH_CSS, /\[data-expanded='true'\] \[data-composer-morph-trailing\] \{[^}]*max-width: calc\(100% - 34px - var\(--composer-morph-tools-width, 0px\)\)/);
});

test('dock inset: observer writes the spacer, jump button and pinned scroll in the same callback, commits React state once settled', async () => {
  const observers: { callback: ResizeObserverCallback; targets: Element[] }[] = [];
  const saved = (globalThis as any).ResizeObserver;
  (globalThis as any).ResizeObserver = class {
    targets: Element[] = [];
    callback: ResizeObserverCallback;
    constructor(callback: ResizeObserverCallback) { this.callback = callback; observers.push(this as any); }
    observe(target: Element) { this.targets.push(target); }
    disconnect() { this.targets = []; }
  };
  cleanups.push(async () => { (globalThis as any).ResizeObserver = saved; });
  let dockHeight = 58;
  const commits: number[] = [];
  function Pane() {
    const dock = React.useRef<HTMLDivElement | null>(null);
    const inset = useComposerDockInset(dock, { insetDebugId: 'list-bottom-inset', jumpDebugId: 'list-jump-latest-btn' });
    React.useLayoutEffect(() => { commits.push(inset); });
    return h('div', null,
      h('div', { 'data-debug-id': 'list-scroll' },
        inset > 0 ? h('div', { 'data-debug-id': 'list-bottom-inset', style: { height: inset } }) : null),
      h('button', { 'data-debug-id': 'list-jump-latest-btn', style: inset > 0 ? { bottom: inset + 12 } : undefined }),
      h('div', { ref: dock, 'data-debug-id': 'dock' }));
  }
  const realRect = dom.window.HTMLElement.prototype.getBoundingClientRect;
  dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
    return this.dataset.debugId === 'dock' ? { height: dockHeight, width: 300, top: 0, left: 0, bottom: dockHeight, right: 300, x: 0, y: 0, toJSON() {} } as DOMRect : realRect.call(this);
  };
  cleanups.push(async () => { dom.window.HTMLElement.prototype.getBoundingClientRect = realRect; });
  const { container } = await mount(h(Pane));
  assert.equal(commits.at(-1), 58, 'initial height measured before paint (layout effect)');
  const spacer = q(container, 'list-bottom-inset')!;
  const scroller = q(container, 'list-scroll')!;
  let scrollTop = 900;
  Object.defineProperties(scroller, {
    scrollHeight: { configurable: true, get: () => 1000 + parseFloat(spacer.style.height) },
    clientHeight: { configurable: true, get: () => 158 },
    scrollTop: { configurable: true, get: () => scrollTop, set: (v: number) => { scrollTop = Math.min(v, 1000 + parseFloat(spacer.style.height) - 158); } },
  });
  const observer = observers.find((o) => o.targets.includes(q(container, 'dock')!))!;
  const fire = (height: number) => observer.callback([{ borderBoxSize: [{ blockSize: height, inlineSize: 300 }] } as any], observer as any);
  // Animation frames: synchronous DOM writes, no React render per frame.
  const before = commits.length;
  for (const height of [85.5, 127.3, 151.3, 173.9]) {
    fire(height);
    assert.equal(spacer.style.height, `${Math.ceil(height)}px`, 'spacer follows the dock in the observer callback');
    assert.equal(q(container, 'list-jump-latest-btn')!.style.bottom, `${Math.ceil(height) + 12}px`);
    assert.equal(scrollTop, 1000 + Math.ceil(height) - 158, 'a reader at the bottom stays pinned');
  }
  assert.equal(commits.length, before, 'no React commit while the dock is moving');
  // A reader scrolled away is not yanked to the bottom.
  scrollTop = 200; fire(176);
  assert.equal(scrollTop, 200);
  await act(async () => { await new Promise((r) => setTimeout(r, 160)); });
  assert.equal(commits.at(-1), 176, 'settled height committed to React once');
  assert.equal(spacer.style.height, '176px');
  // Unchanged size: nothing to do.
  const settled = commits.length; fire(176);
  await act(async () => { await new Promise((r) => setTimeout(r, 160)); });
  assert.equal(commits.length, settled);
});
