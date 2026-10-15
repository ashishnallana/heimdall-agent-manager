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
  | { kind: 'prefix'; actions: AppAction[]; fallbackAction?: AppAction }
  | { kind: 'none' };

export type ChordCompletion = {
  key: string;
  titles: string[];
};

export type ShortcutKeyboardEvent = Pick<
  KeyboardEvent,
  'altKey' | 'ctrlKey' | 'defaultPrevented' | 'isComposing' | 'key' | 'metaKey' | 'repeat' | 'target'
>;

export type PaneFocusDirection = 'left' | 'right' | 'up' | 'down';

export type ShortcutPaneLayout = {
  paneId: string;
  top: number;
  left: number;
  width: number;
  height: number;
};

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

export function isEditableShortcutTarget(target: EventTarget | null): boolean {
  return Boolean(closestElement(target)?.closest(EDITABLE_SELECTOR));
}

export function isShortcutOverrideTrigger(event: ShortcutKeyboardEvent): boolean {
  return (
    event.ctrlKey
    && event.altKey
    && !event.metaKey
    && !event.repeat
    && (event.key === 'Control' || event.key === 'Alt')
  );
}

export function shouldIgnoreEvent(
  event: ShortcutKeyboardEvent,
  allowEditableTarget = false,
): boolean {
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
  return (!allowEditableTarget && isEditableShortcutTarget(event.target)) || hasBlockingDialog(target);
}

export function normalizeShortcutKey(key: string): string | null {
  if (key === 'Esc' || key === 'Escape') return 'escape';
  if (key === 'ArrowLeft') return '←';
  if (key === 'ArrowRight') return '→';
  if (key === 'ArrowUp') return '↑';
  if (key === 'ArrowDown') return '↓';
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
  const prefixes = enabled.filter((action) => (
    action.sequence.length > buffer.length
    && buffer.every((key, index) => action.sequence[index] === key)
  ));
  if (prefixes.length > 0) {
    return exact
      ? { kind: 'prefix', actions: prefixes, fallbackAction: exact }
      : { kind: 'prefix', actions: prefixes };
  }
  return exact ? { kind: 'exact', action: exact } : { kind: 'none' };
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

export function getNextPaneId(
  paneIds: readonly string[],
  focusedPaneId: string,
): string | undefined {
  if (paneIds.length === 0) return undefined;
  const focusedIndex = paneIds.indexOf(focusedPaneId);
  return paneIds[focusedIndex < 0 ? 0 : (focusedIndex + 1) % paneIds.length];
}

export function getDirectionalPaneId(
  layouts: readonly ShortcutPaneLayout[],
  focusedPaneId: string,
  direction: PaneFocusDirection,
): string | undefined {
  const focused = layouts.find((layout) => layout.paneId === focusedPaneId);
  if (!focused) return undefined;

  const sourceX = focused.left + focused.width / 2;
  const sourceY = focused.top + focused.height / 2;
  const candidates = layouts.flatMap((layout) => {
    if (layout.paneId === focusedPaneId) return [];
    const targetX = layout.left + layout.width / 2;
    const targetY = layout.top + layout.height / 2;
    const dx = targetX - sourceX;
    const dy = targetY - sourceY;
    const isAhead = direction === 'left'
      ? dx < 0
      : direction === 'right'
        ? dx > 0
        : direction === 'up'
          ? dy < 0
          : dy > 0;
    if (!isAhead) return [];

    const primaryDistance = direction === 'left' || direction === 'right' ? Math.abs(dx) : Math.abs(dy);
    const crossDistance = direction === 'left' || direction === 'right' ? Math.abs(dy) : Math.abs(dx);
    return [{ paneId: layout.paneId, score: primaryDistance ** 2 + crossDistance ** 2 }];
  });

  candidates.sort((a, b) => a.score - b.score);
  return candidates[0]?.paneId;
}
