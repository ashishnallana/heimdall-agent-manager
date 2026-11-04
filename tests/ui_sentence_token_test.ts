// SentenceToken (new-conversation launcher, spec §3.2/§3.3/§3.7, motion §4 #1-#3 #5-#7 #17 #18)
// and the backwards-compatible @ui Menu/Drawer extensions it is built on.
// DOM nodes are compared with assert.ok(a === b): assert.equal on two jsdom nodes
// deep-inspects them on failure and can hang the run.
import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';

type Env = { width?: number; reducedMotion?: boolean };

async function withDom<T>(env: Env, fn: (doc: Document, win: any) => Promise<T>): Promise<T> {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', { url: 'http://localhost/' });
  const win = dom.window as any;
  Object.defineProperty(win, 'innerWidth', { value: env.width ?? 1280, configurable: true });
  win.matchMedia = (q: string) => ({
    matches: Boolean(env.reducedMotion && q.includes('prefers-reduced-motion')),
    media: q,
    addEventListener() {},
    removeEventListener() {},
    addListener() {},
    removeListener() {},
  });
  const keys = ['window', 'document', 'HTMLElement', 'Node', 'KeyboardEvent', 'MouseEvent', 'localStorage'] as const;
  const prev: Record<string, unknown> = {};
  for (const k of keys) prev[k] = (globalThis as any)[k];
  const prevNavigator = (globalThis as any).navigator;
  (globalThis as any).window = win;
  (globalThis as any).document = win.document;
  (globalThis as any).HTMLElement = win.HTMLElement;
  (globalThis as any).Node = win.Node;
  (globalThis as any).KeyboardEvent = win.KeyboardEvent;
  (globalThis as any).MouseEvent = win.MouseEvent;
  (globalThis as any).localStorage = win.localStorage;
  Object.defineProperty(globalThis, 'navigator', { value: win.navigator, configurable: true });
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  try {
    return await fn(win.document, win);
  } finally {
    dom.window.close();
    for (const k of keys) (globalThis as any)[k] = prev[k];
    Object.defineProperty(globalThis, 'navigator', { value: prevNavigator, configurable: true });
  }
}

async function mount(doc: Document, element: React.ReactElement) {
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const root = createRoot(doc.getElementById('root')!);
  await act(async () => {
    root.render(element);
  });
  return {
    act,
    rerender: async (next: React.ReactElement) => act(async () => root.render(next)),
    unmount: async () => act(async () => root.unmount()),
  };
}

const OPTIONS = [
  { value: 'none', label: 'No project', tokenLabel: 'without a project', description: 'A plain conversation, not tied to a repo' },
  { value: 'alpha', label: 'Alpha', description: '/src/alpha', descriptionMono: true, keywords: ['first'] },
  { value: 'beta', label: 'Beta', description: '/src/beta', descriptionMono: true, disabled: true },
  { value: 'gamma', label: 'Gamma', description: '/src/gamma', descriptionMono: true },
];

async function load() {
  const mod = await import('../src/ui/components/chat/launcher/SentenceToken.tsx');
  return mod;
}

function key(win: any, target: Element, k: string) {
  target.dispatchEvent(new win.KeyboardEvent('keydown', { key: k, bubbles: true, cancelable: true }));
}

function Harness(props: { SentenceToken: any; initial?: string; search?: boolean; onChange?: (v: string) => void; extra?: string }) {
  const [value, setValue] = React.useState(props.initial ?? 'alpha');
  return React.createElement(props.SentenceToken, {
    value,
    options: OPTIONS,
    label: 'Project',
    debugId: 'new-convo-project-token',
    menuWidth: 380,
    search: props.search
      ? { placeholder: 'Find a project', debugId: 'new-convo-project-search', emptyText: 'No project matches that name.' }
      : undefined,
    onChange: (v: string) => {
      props.onChange?.(v);
      setValue(v);
    },
  });
}

test('token is a real menu button with the §3.2 rest look and no animation at mount', async () => {
  await withDom({}, async (doc) => {
    const { SentenceToken } = await load();
    const ui = await mount(doc, React.createElement(Harness, { SentenceToken, initial: 'none' }));
    const token = doc.querySelector('[data-debug-id="new-convo-project-token"]') as HTMLButtonElement;
    assert.ok(token);
    assert.equal(token.tagName, 'BUTTON');
    assert.equal(token.getAttribute('type'), 'button');
    assert.equal(token.getAttribute('aria-haspopup'), 'menu');
    assert.equal(token.getAttribute('aria-expanded'), 'false');
    // Default project renders as "without a project", never the row label.
    assert.equal(token.querySelector('[data-token-value]')!.textContent, 'without a project');
    for (const cls of ['rounded-[10px]', 'px-2', 'pb-0.5', 'decoration-dotted', 'decoration-2', 'underline-offset-8', 'decoration-faint', 'hover:bg-neutral-soft', 'hover:decoration-accent', 'focus-visible:outline-2', 'focus-visible:outline-offset-2']) {
      assert.ok(token.className.includes(cls), `token missing ${cls}`);
    }
    const chevron = token.querySelector('[data-token-chevron]') as HTMLElement;
    assert.equal(chevron.getAttribute('aria-hidden'), 'true');
    assert.ok(chevron.className.includes('w-0') && chevron.className.includes('group-hover/tok:w-[18px]'));
    assert.ok(!token.querySelector('[data-token-value]')!.className.includes('animate-tok-swap'));
    await ui.unmount();
  });
});

test('desktop: opening shows a fixed-width animated menu of menuitemradio rows and focuses the checked row', async () => {
  await withDom({}, async (doc) => {
    const { SentenceToken } = await load();
    const ui = await mount(doc, React.createElement(Harness, { SentenceToken }));
    const token = doc.querySelector('[data-debug-id="new-convo-project-token"]') as HTMLButtonElement;
    await ui.act(async () => token.click());
    assert.equal(token.getAttribute('aria-expanded'), 'true');
    assert.equal(token.getAttribute('data-state'), 'open');
    assert.ok(token.className.includes('text-accent'));
    assert.ok((token.querySelector('[data-token-chevron]') as HTMLElement).className.includes('rotate-180'));
    const popup = doc.querySelector('[data-debug-id="new-convo-project-token-menu"]') as HTMLElement;
    assert.ok(popup);
    assert.equal(popup.style.width, '380px');
    assert.ok(popup.className.includes('animate-menu-in'));
    assert.ok(popup.className.includes('origin-top-left'));
    const menu = doc.querySelector('[role="menu"]') as HTMLElement;
    assert.equal(menu.getAttribute('aria-label'), 'Project');
    const rows = Array.from(menu.querySelectorAll('[role="menuitemradio"]'));
    assert.equal(rows.length, 4);
    assert.deepEqual(rows.map((r) => r.getAttribute('aria-checked')), ['false', 'true', 'false', 'false']);
    assert.equal(rows[2].getAttribute('aria-disabled'), 'true');
    assert.ok(doc.activeElement === rows[1], 'focus');
    // The selected row carries the accent check that pops in (#7).
    assert.ok(rows[1].querySelector('.animate-pop'));
    assert.ok(!rows[0].querySelector('.animate-pop'));
    await ui.unmount();
  });
});

test('keyboard: arrows skip disabled rows and wrap, Home/End jump, Esc closes and returns focus to the token', async () => {
  await withDom({}, async (doc, win) => {
    const { SentenceToken } = await load();
    const ui = await mount(doc, React.createElement(Harness, { SentenceToken }));
    const token = doc.querySelector('[data-debug-id="new-convo-project-token"]') as HTMLButtonElement;
    await ui.act(async () => token.click());
    const rows = () => Array.from(doc.querySelectorAll('[role="menuitemradio"]')) as HTMLElement[];
    const labelOf = () => (doc.activeElement as HTMLElement).querySelector('.font-medium')?.textContent;
    assert.equal(labelOf(), 'Alpha');
    await ui.act(async () => key(win, doc.activeElement!, 'ArrowDown'));
    assert.equal(labelOf(), 'Gamma', 'disabled Beta is skipped');
    await ui.act(async () => key(win, doc.activeElement!, 'ArrowDown'));
    assert.equal(labelOf(), 'No project', 'wraps to the top');
    await ui.act(async () => key(win, doc.activeElement!, 'ArrowUp'));
    assert.equal(labelOf(), 'Gamma', 'wraps to the bottom');
    await ui.act(async () => key(win, doc.activeElement!, 'Home'));
    assert.equal(labelOf(), 'No project');
    await ui.act(async () => key(win, doc.activeElement!, 'End'));
    assert.equal(labelOf(), 'Gamma');
    assert.equal(rows().length, 4);
    await ui.act(async () => key(win, doc.activeElement!, 'Escape'));
    assert.equal(token.getAttribute('aria-expanded'), 'false');
    assert.ok(doc.activeElement === token, 'focus');
    // Exit (#6): the popup stays mounted, hidden from AT, playing the reverse, then unmounts.
    const closing = doc.querySelector('[data-debug-id="new-convo-project-token-menu"]') as HTMLElement | null;
    if (closing) {
      assert.equal(closing.getAttribute('aria-hidden'), 'true');
      assert.ok(closing.className.includes('animate-menu-out'));
      await ui.act(async () => closing.dispatchEvent(new win.Event('animationend', { bubbles: true })));
    }
    assert.ok(doc.querySelector('[data-debug-id="new-convo-project-token-menu"]') === null);
    await ui.unmount();
  });
});

test('picking a row calls onChange, closes, returns focus and replays tokSwap only on a value change', async () => {
  await withDom({}, async (doc, win) => {
    const { SentenceToken } = await load();
    const picks: string[] = [];
    const ui = await mount(doc, React.createElement(Harness, { SentenceToken, onChange: (v: string) => picks.push(v) }));
    const token = doc.querySelector('[data-debug-id="new-convo-project-token"]') as HTMLButtonElement;
    const valueSpan = () => token.querySelector('[data-token-value]') as HTMLElement;
    const before = valueSpan();

    // Re-picking the current value is not a change.
    await ui.act(async () => token.click());
    await ui.act(async () => (doc.querySelector('[role="menuitemradio"][aria-checked="true"]') as HTMLElement).click());
    assert.deepEqual(picks, []);
    assert.ok(valueSpan() === before, 'no remount without a change');
    assert.ok(!valueSpan().className.includes('animate-tok-swap'));

    await ui.act(async () => token.click());
    const gamma = Array.from(doc.querySelectorAll('[role="menuitemradio"]')).find((r) => r.textContent?.includes('Gamma')) as HTMLElement;
    await ui.act(async () => gamma.click());
    assert.deepEqual(picks, ['gamma']);
    assert.equal(token.getAttribute('aria-expanded'), 'false');
    assert.ok(doc.activeElement === token, 'focus');
    assert.equal(valueSpan().textContent, 'Gamma');
    assert.ok(valueSpan() !== before, 'value span remounts so the keyframe replays');
    assert.ok(valueSpan().className.includes('animate-tok-swap'));

    // Picking back the mount value still animates (a real change).
    const afterGamma = valueSpan();
    await ui.act(async () => token.click());
    const alpha = Array.from(doc.querySelectorAll('[role="menuitemradio"]')).find((r) => r.textContent?.includes('Alpha')) as HTMLElement;
    await ui.act(async () => alpha.click());
    assert.ok(valueSpan() !== afterGamma);
    assert.ok(valueSpan().className.includes('animate-tok-swap'));

    // An unrelated re-render (open/close) does not remount the value.
    const settled = valueSpan();
    await ui.act(async () => token.click());
    await ui.act(async () => key(win, doc.activeElement!, 'Escape'));
    assert.ok(valueSpan() === settled);
    await ui.unmount();
  });
});

test('reduced motion: a value change applies no tokSwap class', async () => {
  await withDom({ reducedMotion: true }, async (doc) => {
    const { SentenceToken } = await load();
    const ui = await mount(doc, React.createElement(Harness, { SentenceToken }));
    const token = doc.querySelector('[data-debug-id="new-convo-project-token"]') as HTMLButtonElement;
    await ui.act(async () => token.click());
    const gamma = Array.from(doc.querySelectorAll('[role="menuitemradio"]')).find((r) => r.textContent?.includes('Gamma')) as HTMLElement;
    await ui.act(async () => gamma.click());
    assert.equal(token.querySelector('[data-token-value]')!.textContent, 'Gamma');
    assert.ok(!token.querySelector('[data-token-value]')!.className.includes('animate-'));
    assert.ok(token.className.includes('motion-reduce:transition-none'));
    await ui.unmount();
  });
});

test('search: focused on open, filters by label and keywords, shows the empty text, ArrowDown enters the list', async () => {
  await withDom({}, async (doc, win) => {
    const { SentenceToken, filterSentenceTokenOptions } = await load();
    assert.deepEqual(filterSentenceTokenOptions(OPTIONS, 'FIRST').map((o) => o.value), ['alpha']);
    assert.deepEqual(filterSentenceTokenOptions(OPTIONS, '  ').length, 4);

    const ui = await mount(doc, React.createElement(Harness, { SentenceToken, search: true }));
    const token = doc.querySelector('[data-debug-id="new-convo-project-token"]') as HTMLButtonElement;
    await ui.act(async () => token.click());
    const input = doc.querySelector('[data-debug-id="new-convo-project-search"]') as HTMLInputElement;
    assert.ok(input);
    assert.ok(doc.activeElement === input, 'focus');
    assert.equal(input.getAttribute('placeholder'), 'Find a project');
    assert.ok(doc.querySelector(`label[for="${input.id}"]`)?.textContent?.includes('Find a project'));
    // The field sits outside role="menu" (a menu may only own menu items).
    assert.ok(input.closest('[role="menu"]') === null);

    const type = async (text: string) => {
      const setter = Object.getOwnPropertyDescriptor(win.HTMLInputElement.prototype, 'value')!.set!;
      await ui.act(async () => {
        setter.call(input, text);
        input.dispatchEvent(new win.Event('input', { bubbles: true }));
      });
    };
    const labels = () => Array.from(doc.querySelectorAll('[role="menuitemradio"] .font-medium')).map((n) => n.textContent);
    await type('gam');
    assert.deepEqual(labels(), ['Gamma']);
    await type('/src/');
    assert.deepEqual(labels(), ['Alpha', 'Beta', 'Gamma']);
    await type('zzz');
    assert.deepEqual(labels(), []);
    assert.ok(doc.body.textContent!.includes('No project matches that name.'));
    await type('a');
    // Home/End stay in the field for text editing.
    await ui.act(async () => key(win, input, 'End'));
    assert.ok(doc.activeElement === input, 'focus');
    await ui.act(async () => key(win, input, 'ArrowDown'));
    assert.ok(doc.activeElement === doc.querySelector('[role="menuitemradio"]'), 'focus');

    // Esc from the field also closes and restores focus; a reopen starts with an empty query.
    await ui.act(async () => input.focus());
    await ui.act(async () => key(win, input, 'Escape'));
    assert.ok(doc.activeElement === token, 'focus');
    await ui.act(async () => token.click());
    const reopened = doc.querySelectorAll('[data-debug-id="new-convo-project-search"]');
    const live = Array.from(reopened).find((n) => !(n as HTMLElement).closest('[aria-hidden="true"]')) as HTMLInputElement;
    assert.equal(live.value, '');
    await ui.unmount();
  });
});

test('mobile (<768px): the menu is a bottom sheet with handle, scrim, 48px rows; Esc returns focus to the token', async () => {
  await withDom({ width: 390 }, async (doc, win) => {
    const { SentenceToken } = await load();
    const ui = await mount(doc, React.createElement(Harness, { SentenceToken }));
    const token = doc.querySelector('[data-debug-id="new-convo-project-token"]') as HTMLButtonElement;
    assert.ok(token.className.includes('min-h-11'), '44px hit area');
    const chevron = token.querySelector('[data-token-chevron]') as HTMLElement;
    assert.ok(chevron.className.includes('opacity-100'), 'chevron always visible on mobile');

    await ui.act(async () => token.click());
    assert.equal(token.getAttribute('aria-expanded'), 'true');
    const dialog = doc.querySelector('[role="dialog"]') as HTMLElement;
    assert.ok(dialog, 'sheet rendered');
    assert.equal(dialog.getAttribute('aria-label'), 'Project');
    for (const cls of ['rounded-t-[var(--radius-xl)]', 'max-h-[calc(var(--app-viewport-height)*0.8)]', 'pb-[env(safe-area-inset-bottom)]', 'animate-sheet-in']) {
      assert.ok(dialog.className.includes(cls), `sheet missing ${cls}`);
    }
    const scrim = dialog.parentElement as HTMLElement;
    assert.ok(scrim.className.includes('bg-scrim') && scrim.className.includes('animate-fade-in'));
    assert.ok(!scrim.className.includes('backdrop-blur'));
    const handle = dialog.querySelector('span[aria-hidden="true"]') as HTMLElement;
    assert.ok(handle.className.includes('h-1') && handle.className.includes('w-9'), '36x4 grab handle');

    const rows = Array.from(dialog.querySelectorAll('[role="menuitemradio"]')) as HTMLElement[];
    assert.equal(rows.length, 4);
    assert.ok(rows.every((r) => r.className.includes('min-h-12')), 'rows >= 48px');
    assert.ok(doc.activeElement === rows[1], 'checked row focused on open');
    await ui.act(async () => key(win, doc.activeElement!, 'ArrowDown'));
    assert.ok(doc.activeElement === rows[3], 'focus');

    await ui.act(async () => key(win, doc.activeElement!, 'Escape'));
    assert.equal(token.getAttribute('aria-expanded'), 'false');
    assert.ok(doc.activeElement === token, 'focus');
    const closing = doc.querySelector('[role="dialog"]') as HTMLElement | null;
    if (closing) {
      assert.ok(closing.className.includes('animate-sheet-out'));
      assert.equal(closing.parentElement!.getAttribute('data-state'), 'closing');
      await ui.act(async () => closing.dispatchEvent(new win.Event('animationend', { bubbles: true })));
    }
    assert.ok(doc.querySelector('[role="dialog"]') === null);
    await ui.unmount();
  });
});

test('renderMenu: a custom body gets close() and the token still owns focus return', async () => {
  await withDom({}, async (doc) => {
    const { SentenceToken } = await load();
    const { Menu } = await import('@ui');
    const ui = await mount(
      doc,
      React.createElement(SentenceToken, {
        value: 'x',
        label: 'Runtime',
        debugId: 'new-convo-runtime-picker',
        children: 'Claude',
        renderMenu: ({ close }: { close: () => void }) =>
          React.createElement(
            React.Fragment,
            null,
            React.createElement(Menu.RadioItem, { checked: true, keepOpen: true, 'data-debug-id': 'keep' }, 'Claude'),
            React.createElement(Menu.Item, { keepOpen: true, onClick: close, 'data-debug-id': 'done' }, 'Done'),
          ),
      }),
    );
    const token = doc.querySelector('[data-debug-id="new-convo-runtime-picker"]') as HTMLButtonElement;
    assert.equal(token.querySelector('[data-token-value]')!.textContent, 'Claude');
    await ui.act(async () => token.click());
    await ui.act(async () => (doc.querySelector('[data-debug-id="keep"]') as HTMLElement).click());
    assert.equal(token.getAttribute('aria-expanded'), 'true', 'keepOpen row leaves the menu open');
    await ui.act(async () => (doc.querySelector('[data-debug-id="done"]') as HTMLElement).click());
    assert.equal(token.getAttribute('aria-expanded'), 'false');
    assert.ok(doc.activeElement === token, 'focus');
    await ui.unmount();
  });
});

test('backwards compatible: a plain @ui Menu keeps its original DOM, styling and behaviour', async () => {
  await withDom({}, async (doc, win) => {
    const { Menu } = await import('@ui');
    const actions: string[] = [];
    const ui = await mount(
      doc,
      React.createElement(
        Menu,
        { trigger: React.createElement('button', { type: 'button', 'data-debug-id': 'kebab' }, 'More'), label: 'Actions' },
        React.createElement(Menu.Item, { onClick: () => actions.push('rename') }, 'Rename'),
        React.createElement(Menu.Item, { danger: true, onClick: () => actions.push('delete') }, 'Delete'),
      ),
    );
    const trigger = doc.querySelector('[data-debug-id="kebab"]') as HTMLButtonElement;
    await ui.act(async () => trigger.click());
    const menu = doc.querySelector('[role="menu"]') as HTMLElement;
    // The popup itself is the menu, with the original compact surface and no motion classes.
    assert.ok(menu.className.includes('min-w-[12rem]') && menu.className.includes('rounded-[var(--radius-md)]') && menu.className.includes('shadow-overlay'));
    assert.ok(!/animate-/.test(menu.className));
    assert.equal(menu.style.width, '');
    const items = Array.from(menu.querySelectorAll('[role="menuitem"]')) as HTMLElement[];
    assert.equal(items.length, 2);
    assert.ok(items[0].className.includes('px-3') && items[0].className.includes('py-1.5'));
    assert.equal(items[0].textContent, 'Rename');
    assert.ok(doc.activeElement === items[0], 'focus');
    await ui.act(async () => key(win, items[0], 'ArrowDown'));
    assert.ok(doc.activeElement === items[1], 'focus');
    await ui.act(async () => items[1].click());
    assert.deepEqual(actions, ['delete']);
    // Non-animated menus unmount immediately.
    assert.ok(doc.querySelector('[role="menu"]') === null);
    assert.ok(doc.activeElement === trigger, 'focus');
    await ui.unmount();
  });
});

test('backwards compatible: a default Drawer still blurs the backdrop, autofocuses and unmounts at once', async () => {
  await withDom({}, async (doc) => {
    const { Drawer } = await import('@ui');
    function D({ open }: { open: boolean }) {
      return React.createElement(
        Drawer,
        { open, onOpenChange: () => {}, title: 'Details' },
        React.createElement('button', { type: 'button', 'data-debug-id': 'inner' }, 'Inner'),
      );
    }
    const ui = await mount(doc, React.createElement(D, { open: true }));
    const dialog = doc.querySelector('[role="dialog"]') as HTMLElement;
    assert.ok(dialog.parentElement!.className.includes('bg-backdrop'));
    assert.ok(dialog.parentElement!.className.includes('backdrop-blur-sm'));
    assert.ok(!dialog.querySelector('.w-9.h-1'));
    assert.ok(dialog.contains(doc.activeElement));
    await ui.rerender(React.createElement(D, { open: false }));
    assert.ok(doc.querySelector('[role="dialog"]') === null);
    await ui.unmount();
  });
});
