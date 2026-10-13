import {
  Axis,
  PaneState,
  PaneTreeState,
  SplitInputDirection,
} from './types';

function getNextIdNumber<T>(state: PaneTreeState<T>, prefix: string): number {
  let max = 0;
  const regex = new RegExp(`^${prefix}-(\\d+)$`);
  for (const key of Object.keys(state.panes)) {
    const match = regex.exec(key);
    if (match) {
      const num = parseInt(match[1], 10);
      if (Number.isFinite(num) && num > max) {
        max = num;
      }
    }
  }
  return max + 1;
}

function generatePaneId<T>(state: PaneTreeState<T>, prefix = 'pane'): string {
  let nextNum = getNextIdNumber(state, prefix);
  let candidate = `${prefix}-${nextNum}`;
  while (state.panes[candidate]) {
    nextNum += 1;
    candidate = `${prefix}-${nextNum}`;
  }
  return candidate;
}

/**
 * Creates a single-pane binary split tree state.
 */
export function createPaneTreeState<T>(
  initialContent: T,
  initialPaneId = 'pane-1',
): PaneTreeState<T> {
  const paneId = initialPaneId || 'pane-1';
  return {
    rootPaneId: paneId,
    panes: {
      [paneId]: {
        kind: 'content',
        value: initialContent,
      },
    },
    focusedPaneId: paneId,
    maximizedPaneId: null,
  };
}

/**
 * Converts a SplitInputDirection into a binary split Axis.
 * - 'top' | 'bottom' | 'vertical' -> 'vertical' (stacked top/bottom)
 * - 'left' | 'right' | 'horizontal' -> 'horizontal' (side-by-side left/right)
 */
export function toAxis(direction: SplitInputDirection): Axis {
  switch (direction) {
    case 'top':
    case 'bottom':
    case 'vertical':
      return 'vertical';
    case 'left':
    case 'right':
    case 'horizontal':
    default:
      return 'horizontal';
  }
}

/**
 * Returns true if the new split child should be placed in `leftChildId`
 * (top for vertical splits, left for horizontal splits).
 */
export function isFirstChild(direction: SplitInputDirection): boolean {
  return direction === 'top' || direction === 'left';
}

/**
 * Converts a PaneTreeState to structure-only format, excluding leaf content
 * values so layout calculations can memoize purely on tree topology & ratios.
 */
export function toStructureOnly<T>(
  state: PaneTreeState<T>,
): PaneTreeState<undefined> {
  const structureOnlyPanes: Record<string, PaneState<undefined>> = {};

  for (const [paneId, pane] of Object.entries(state.panes)) {
    if (pane.kind === 'split') {
      structureOnlyPanes[paneId] = { ...pane };
    } else {
      structureOnlyPanes[paneId] = { kind: 'content', value: undefined };
    }
  }

  return {
    rootPaneId: state.rootPaneId,
    panes: structureOnlyPanes,
    focusedPaneId: state.focusedPaneId,
    maximizedPaneId: state.maximizedPaneId ?? null,
  };
}

/**
 * Finds the parent split node and side ('left' | 'right') of `targetPaneId`.
 */
export function getPaneLocation<T>(
  state: PaneTreeState<T>,
  targetPaneId: string,
): { parentId: string; side: 'left' | 'right' } | undefined {
  for (const [paneId, pane] of Object.entries(state.panes)) {
    if (pane.kind === 'split') {
      if (pane.leftChildId === targetPaneId) {
        return { parentId: paneId, side: 'left' };
      }
      if (pane.rightChildId === targetPaneId) {
        return { parentId: paneId, side: 'right' };
      }
    }
  }
  return undefined;
}

/**
 * Ordered depth-first traversal returning all content leaf pane IDs.
 */
export function getContentPaneIds<T>(state: PaneTreeState<T>): string[] {
  const result: string[] = [];
  const visited = new Set<string>();

  function visit(paneId: string) {
    if (!paneId || visited.has(paneId)) return;
    visited.add(paneId);
    const pane = state.panes[paneId];
    if (!pane) return;
    if (pane.kind === 'content') {
      result.push(paneId);
    } else {
      visit(pane.leftChildId);
      visit(pane.rightChildId);
    }
  }

  visit(state.rootPaneId);

  // Fallback for any unreferenced content panes in malformed state
  for (const [paneId, pane] of Object.entries(state.panes)) {
    if (pane.kind === 'content' && !visited.has(paneId)) {
      result.push(paneId);
    }
  }

  return result;
}

export function getAllContentPanes<T>(state: PaneTreeState<T>): T[] {
  return getContentPaneIds(state)
    .map((id) => state.panes[id])
    .filter((p): p is Extract<PaneState<T>, { kind: 'content' }> => Boolean(p && p.kind === 'content'))
    .map((p) => p.value);
}

export function getContentPane<T>(
  paneId: string,
  state: PaneTreeState<T>,
): T | undefined {
  const pane = state.panes[paneId];
  if (!pane || pane.kind !== 'content') return undefined;
  return pane.value;
}

export function defaultContentPane<T>(
  state: PaneTreeState<T>,
): { paneId: string; pane: T } | undefined {
  if (state.focusedPaneId) {
    const focused = state.panes[state.focusedPaneId];
    if (focused && focused.kind === 'content') {
      return { paneId: state.focusedPaneId, pane: focused.value };
    }
  }
  const ids = getContentPaneIds(state);
  if (ids.length > 0) {
    const firstId = ids[0];
    const first = state.panes[firstId];
    if (first && first.kind === 'content') {
      return { paneId: firstId, pane: first.value };
    }
  }
  return undefined;
}

/**
 * Splits `paneIdToSplit` while strictly preserving `paneIdToSplit` and its entry in `state.panes`.
 * Creates a new parent split node and a new child content pane.
 */
export function splitPaneInTree<T>(
  state: PaneTreeState<T>,
  paneIdToSplit: string,
  direction: SplitInputDirection,
  newContent: T,
  newPaneId?: string,
): { parentId: string; newChildId: string } {
  const resolvedTargetId =
    state.panes[paneIdToSplit]?.kind === 'content'
      ? paneIdToSplit
      : state.panes[state.focusedPaneId]?.kind === 'content'
        ? state.focusedPaneId
        : getContentPaneIds(state)[0];

  if (!resolvedTargetId || !state.panes[resolvedTargetId]) {
    const fallbackId = newPaneId || generatePaneId(state, 'pane');
    state.panes[fallbackId] = { kind: 'content', value: newContent };
    state.rootPaneId = fallbackId;
    state.focusedPaneId = fallbackId;
    state.maximizedPaneId = null;
    return { parentId: fallbackId, newChildId: fallbackId };
  }

  const newChildId =
    newPaneId && !state.panes[newPaneId]
      ? newPaneId
      : generatePaneId(state, 'pane');
  state.panes[newChildId] = { kind: 'content', value: newContent };

  const position = getPaneLocation(state, resolvedTargetId);
  const parentId = generatePaneId(state, 'split');
  const firstChild = isFirstChild(direction);

  const newSplitPane: PaneState<T> = {
    kind: 'split',
    axis: toAxis(direction),
    leftChildId: firstChild ? newChildId : resolvedTargetId,
    rightChildId: firstChild ? resolvedTargetId : newChildId,
    ratio: 50,
  };
  state.panes[parentId] = newSplitPane;

  if (position) {
    const parentPane = state.panes[position.parentId];
    if (parentPane && parentPane.kind === 'split') {
      if (position.side === 'left') {
        parentPane.leftChildId = parentId;
      } else {
        parentPane.rightChildId = parentId;
      }
    }
  }

  if (state.rootPaneId === resolvedTargetId) {
    state.rootPaneId = parentId;
  }

  state.focusedPaneId = newChildId;
  if (state.maximizedPaneId) {
    state.maximizedPaneId = null;
  }

  return {
    parentId,
    newChildId,
  };
}

export const split = splitPaneInTree;
export const splitPane = splitPaneInTree;

/**
 * Detaches `paneId` from its enclosing parent split without deleting `state.panes[paneId]`.
 * Promotes its binary sibling into the grandparent (or `rootPaneId`).
 * Returns the siblingId that took the parent's place, or undefined if `paneId` was root / not in a split.
 */
function detachPaneFromParentSplit<T>(
  state: PaneTreeState<T>,
  paneId: string,
): { siblingId?: string; wasRoot: boolean } {
  const position = getPaneLocation(state, paneId);
  if (!position) {
    return { wasRoot: state.rootPaneId === paneId };
  }

  const parentPane = state.panes[position.parentId];
  if (!parentPane || parentPane.kind !== 'split') {
    return { wasRoot: false };
  }

  const siblingId =
    position.side === 'left' ? parentPane.rightChildId : parentPane.leftChildId;

  const grandparent = getPaneLocation(state, position.parentId);
  delete state.panes[position.parentId];

  if (grandparent) {
    const grandparentPane = state.panes[grandparent.parentId];
    if (grandparentPane && grandparentPane.kind === 'split') {
      if (grandparent.side === 'left') {
        grandparentPane.leftChildId = siblingId;
      } else {
        grandparentPane.rightChildId = siblingId;
      }
    }
  } else {
    state.rootPaneId = siblingId;
  }

  return { siblingId, wasRoot: false };
}

/**
 * Closes a content pane in the tree.
 * Returns `true` if the last pane (root) was closed, `false` otherwise.
 * Repairs `focusedPaneId` and clears `maximizedPaneId` if the closed pane was focused/maximized.
 */
export function closePaneInTree<T>(
  state: PaneTreeState<T>,
  paneIdToClose: string,
): boolean {
  const target = state.panes[paneIdToClose];
  if (!target || target.kind !== 'content') {
    return false;
  }

  const contentIdsBefore = getContentPaneIds(state);
  if (contentIdsBefore.length <= 1 && state.rootPaneId === paneIdToClose) {
    delete state.panes[paneIdToClose];
    state.maximizedPaneId = null;
    return true;
  }

  const { siblingId, wasRoot } = detachPaneFromParentSplit(state, paneIdToClose);
  delete state.panes[paneIdToClose];

  if (wasRoot) {
    state.maximizedPaneId = null;
    return true;
  }

  if (state.maximizedPaneId === paneIdToClose) {
    state.maximizedPaneId = null;
  }

  const remainingContentIds = getContentPaneIds(state);
  if (remainingContentIds.length <= 1) {
    state.maximizedPaneId = null;
  }

  if (
    state.focusedPaneId === paneIdToClose ||
    !state.panes[state.focusedPaneId] ||
    state.panes[state.focusedPaneId]?.kind !== 'content'
  ) {
    // Prefer a leaf inside the sibling subtree if available
    if (siblingId && state.panes[siblingId]?.kind === 'content') {
      state.focusedPaneId = siblingId;
    } else if (remainingContentIds.length > 0) {
      state.focusedPaneId = remainingContentIds[0];
    }
  }

  return remainingContentIds.length === 0;
}

/**
 * Flexible alias for `closePaneInTree` supporting both `(state, paneId)` and `(paneId, state)` argument orders.
 */
export function closePane<T>(
  stateOrId: PaneTreeState<T> | string,
  idOrState: string | PaneTreeState<T>,
): boolean {
  if (typeof stateOrId === 'string') {
    return closePaneInTree(idOrState as PaneTreeState<T>, stateOrId);
  }
  return closePaneInTree(stateOrId, idOrState as string);
}

/**
 * Moves `sourcePaneId` into a new split around `targetPaneId` along `direction`.
 * STRICTLY PRESERVES both `sourcePaneId` and `targetPaneId` in `state.panes` so React keys do not remount.
 */
export function movePaneInTree<T>(
  state: PaneTreeState<T>,
  sourcePaneId: string,
  targetPaneId: string,
  direction: SplitInputDirection,
): boolean {
  if (!sourcePaneId || !targetPaneId || sourcePaneId === targetPaneId) {
    return false;
  }

  const sourcePane = state.panes[sourcePaneId];
  const targetPane = state.panes[targetPaneId];
  if (
    !sourcePane ||
    sourcePane.kind !== 'content' ||
    !targetPane ||
    targetPane.kind !== 'content'
  ) {
    return false;
  }

  // 1. Detach sourcePaneId from its old parent split WITHOUT deleting state.panes[sourcePaneId].
  const { wasRoot } = detachPaneFromParentSplit(state, sourcePaneId);
  if (wasRoot) {
    // Cannot detach if sourcePaneId was the only pane
    return false;
  }

  // 2. Find targetPaneId's current location in the updated tree.
  const targetPosition = getPaneLocation(state, targetPaneId);
  const newParentId = generatePaneId(state, 'split');
  const firstChild = isFirstChild(direction);

  const newSplitPane: PaneState<T> = {
    kind: 'split',
    axis: toAxis(direction),
    leftChildId: firstChild ? sourcePaneId : targetPaneId,
    rightChildId: firstChild ? targetPaneId : sourcePaneId,
    ratio: 50,
  };
  state.panes[newParentId] = newSplitPane;

  if (targetPosition) {
    const targetParent = state.panes[targetPosition.parentId];
    if (targetParent && targetParent.kind === 'split') {
      if (targetPosition.side === 'left') {
        targetParent.leftChildId = newParentId;
      } else {
        targetParent.rightChildId = newParentId;
      }
    }
  }

  if (state.rootPaneId === targetPaneId) {
    state.rootPaneId = newParentId;
  }

  state.focusedPaneId = sourcePaneId;
  if (state.maximizedPaneId) {
    state.maximizedPaneId = null;
  }

  return true;
}

export const movePane = movePaneInTree;

/**
 * Swaps the positions of two content panes in the tree while preserving both pane IDs!
 * If they are in the tree, swaps their parent references (leftChildId / rightChildId)
 * so each pane keeps its own ID and value, moving to the other's slot in the layout.
 */
export function swapPanesInTree<T>(
  state: PaneTreeState<T>,
  paneIdA: string,
  paneIdB: string,
): boolean {
  if (!paneIdA || !paneIdB || paneIdA === paneIdB) {
    return false;
  }
  const paneA = state.panes[paneIdA];
  const paneB = state.panes[paneIdB];
  if (!paneA || paneA.kind !== 'content' || !paneB || paneB.kind !== 'content') {
    return false;
  }

  const locA = getPaneLocation(state, paneIdA);
  const locB = getPaneLocation(state, paneIdB);
  if (!locA || !locB) {
    return false;
  }

  const parentA = state.panes[locA.parentId];
  const parentB = state.panes[locB.parentId];
  if (!parentA || parentA.kind !== 'split' || !parentB || parentB.kind !== 'split') {
    return false;
  }

  if (locA.parentId === locB.parentId) {
    const tmp = parentA.leftChildId;
    parentA.leftChildId = parentA.rightChildId;
    parentA.rightChildId = tmp;
  } else {
    if (locA.side === 'left') {
      parentA.leftChildId = paneIdB;
    } else {
      parentA.rightChildId = paneIdB;
    }
    if (locB.side === 'left') {
      parentB.leftChildId = paneIdA;
    } else {
      parentB.rightChildId = paneIdA;
    }
  }

  return true;
}

export const swapPanes = swapPanesInTree;

/**
 * Resizes a split node's ratio, clamped to `[5, 95]`.
 * Non-finite / NaN values are ignored or clamped safely.
 */
export function resizeSplitInTree<T>(
  state: PaneTreeState<T>,
  splitPaneId: string,
  ratio: number,
): void {
  const pane = state.panes[splitPaneId];
  if (!pane || pane.kind !== 'split') {
    return;
  }
  if (!Number.isFinite(ratio) || Number.isNaN(ratio)) {
    return;
  }
  pane.ratio = Math.max(5, Math.min(95, ratio));
}

export const resizeSplit = resizeSplitInTree;

/**
 * Resets all split node ratios in the tree to 50/50.
 */
export function equalizeTreeRatios<T>(state: PaneTreeState<T>): void {
  for (const pane of Object.values(state.panes)) {
    if (pane.kind === 'split') {
      pane.ratio = 50;
    }
  }
}

export const equalizePanes = equalizeTreeRatios;

/**
 * Toggles maximize/restore on `paneId` (defaults to `state.focusedPaneId`).
 * If there is only 1 content pane in the tree, `maximizedPaneId` is cleared to `null`.
 */
export function toggleMaximizePaneInTree<T>(
  state: PaneTreeState<T>,
  paneId?: string,
): void {
  const targetId = paneId || state.focusedPaneId;
  if (!targetId || state.panes[targetId]?.kind !== 'content') {
    state.maximizedPaneId = null;
    return;
  }
  const contentIds = getContentPaneIds(state);
  if (contentIds.length <= 1) {
    state.maximizedPaneId = null;
    return;
  }
  if (state.maximizedPaneId === targetId) {
    state.maximizedPaneId = null;
  } else {
    state.maximizedPaneId = targetId;
    state.focusedPaneId = targetId;
  }
}

export const toggleMaximizePane = toggleMaximizePaneInTree;

export function updatePaneContent<T>(
  state: PaneTreeState<T>,
  paneId: string,
  value: T,
): void {
  const pane = state.panes[paneId];
  if (pane && pane.kind === 'content') {
    pane.value = value;
  }
}
