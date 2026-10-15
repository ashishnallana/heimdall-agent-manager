/**
 * Pure contracts and matching helpers for the global Tier-1 shortcut manager.
 * Kept free of React so the behavior can be exercised by the native Node test runner.
 */

export const SHORTCUT_SEQUENCE_TIMEOUT_MS = 1_200;

export type ActionCategory = 'General' | 'Navigation' | 'Workspace';

export type AppAction = {
  id: string;
  title: string;
  category: ActionCategory;
  sequence: readonly string[];
  isEnabled?: () => boolean;
  run: () => void;
};

export type SequenceMatch =
  | { kind: 'exact'; action: AppAction }
  | { kind: 'prefix'; actions: AppAction[] }
  | { kind: 'none' };

export type ChordCompletion = {
  key: string;
  titles: string[];
};

export type ShortcutKeyboardEvent = Pick<
  KeyboardEvent,
  'altKey' | 'ctrlKey' | 'defaultPrevented' | 'isComposing' | 'key' | 'metaKey' | 'repeat' | 'target'
>;

const EDITABLE_SELECTOR = [
  'input',
  'textarea',
  'select',
  '[contenteditable]:not([contenteditable="false"])',
  '.monaco-editor',
  '.xterm',
].join(',');

function closestElement(target: EventTarget | null): Element | null {
  if (!target || typeof target !== 'object') return null;
  if ('closest' in target && typeof target.closest === 'function') return target as Element;
  if ('parentElement' in target) return (target as Node).parentElement;
  return null;
}

function hasBlockingDialog(target: Element | null): boolean {
  const documentRef = target?.ownerDocument ?? (typeof document === 'undefined' ? null : document);
  if (!documentRef) return false;

  return Array.from(documentRef.querySelectorAll<HTMLElement>('[role="dialog"]')).some((dialog) => {
    if (dialog.dataset.shortcutCheatsheet === 'true') return false;
    return !dialog.hidden && dialog.getAttribute('aria-hidden') !== 'true';
  });
}

export function shouldIgnoreEvent(event: ShortcutKeyboardEvent): boolean {
  if (
    event.metaKey
    || event.ctrlKey
    || event.altKey
    || event.isComposing
    || event.repeat
    || event.defaultPrevented
  ) {
    return true;
  }

  const target = closestElement(event.target);
  return Boolean(target?.closest(EDITABLE_SELECTOR)) || hasBlockingDialog(target);
}

export function normalizeShortcutKey(key: string): string | null {
  if (key === 'Esc' || key === 'Escape') return 'escape';
  if (key.length !== 1) return null;
  return key.toLowerCase();
}

export function isActionEnabled(action: AppAction): boolean {
  return action.isEnabled?.() !== false;
}

export function matchSequence(
  buffer: readonly string[],
  actions: readonly AppAction[],
): SequenceMatch {
  const enabled = actions.filter(isActionEnabled);
  const exact = enabled.find((action) => (
    action.sequence.length === buffer.length
    && action.sequence.every((key, index) => key === buffer[index])
  ));
  if (exact) return { kind: 'exact', action: exact };

  const prefixes = enabled.filter((action) => (
    action.sequence.length > buffer.length
    && buffer.every((key, index) => action.sequence[index] === key)
  ));
  return prefixes.length > 0 ? { kind: 'prefix', actions: prefixes } : { kind: 'none' };
}

export function actionDescriptorKey(actions: readonly AppAction[]): string {
  return JSON.stringify(actions.map((action) => ({
    id: action.id,
    title: action.title,
    category: action.category,
    sequence: action.sequence,
    hasEnabledGuard: Boolean(action.isEnabled),
  })));
}

export function getChordCompletions(
  buffer: readonly string[],
  matchingActions: readonly AppAction[],
): ChordCompletion[] {
  const byKey = new Map<string, string[]>();
  for (const action of matchingActions) {
    const key = action.sequence[buffer.length];
    if (!key) continue;
    const titles = byKey.get(key) ?? [];
    titles.push(action.title);
    byKey.set(key, titles);
  }
  return Array.from(byKey, ([key, titles]) => ({ key, titles }));
}
