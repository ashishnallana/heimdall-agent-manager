import {
  PaneBounds,
  PaneLayout,
  PaneState,
  PaneTreeState,
  SplitterLayout,
} from './types';

export type { PaneBounds, PaneLayout, SplitterLayout };

function layoutPane(
  panes: Record<string, PaneState<unknown>>,
  paneId: string,
  bounds: PaneBounds,
  visited: Set<string> = new Set(),
): { contentLayouts: PaneLayout[]; splitterLayouts: SplitterLayout[] } {
  if (!paneId || visited.has(paneId)) {
    return { contentLayouts: [], splitterLayouts: [] };
  }
  visited.add(paneId);

  const pane = panes[paneId];
  if (!pane) {
    return { contentLayouts: [], splitterLayouts: [] };
  }

  if (pane.kind === 'content') {
    return {
      contentLayouts: [
        {
          paneId,
          top: bounds.top,
          left: bounds.left,
          width: bounds.width,
          height: bounds.height,
          isRightmostOfRow: bounds.isRightmostOfRow,
          isBottommostOfColumn: bounds.isBottommostOfColumn,
        },
      ],
      splitterLayouts: [],
    };
  }

  const isVertical = pane.axis === 'vertical';
  const rawRatio = Number.isFinite(pane.ratio) && !Number.isNaN(pane.ratio) ? pane.ratio : 50;
  const ratio = Math.max(5, Math.min(95, rawRatio));

  const leftChildBounds: PaneBounds = {
    top: bounds.top,
    left: bounds.left,
    width: isVertical ? bounds.width : bounds.width * (ratio / 100),
    height: isVertical ? bounds.height * (ratio / 100) : bounds.height,
    isRightmostOfRow: isVertical ? bounds.isRightmostOfRow : false,
    isBottommostOfColumn: isVertical ? false : bounds.isBottommostOfColumn,
  };

  const rightChildBounds: PaneBounds = {
    top: isVertical ? bounds.top + bounds.height * (ratio / 100) : bounds.top,
    left: isVertical ? bounds.left : bounds.left + bounds.width * (ratio / 100),
    width: isVertical ? bounds.width : bounds.width * ((100 - ratio) / 100),
    height: isVertical ? bounds.height * ((100 - ratio) / 100) : bounds.height,
    isRightmostOfRow: bounds.isRightmostOfRow,
    isBottommostOfColumn: bounds.isBottommostOfColumn,
  };

  const leftResult = layoutPane(panes, pane.leftChildId, leftChildBounds, visited);
  const rightResult = layoutPane(panes, pane.rightChildId, rightChildBounds, visited);

  const splitterLayouts: SplitterLayout[] = [
    ...leftResult.splitterLayouts,
    ...rightResult.splitterLayouts,
  ];

  const splitterSize = 0.5;
  if (isVertical) {
    splitterLayouts.push({
      paneId,
      axis: 'vertical',
      top: bounds.top + bounds.height * (ratio / 100) - splitterSize / 2,
      left: bounds.left,
      width: bounds.width,
      height: splitterSize,
      splitPaneBounds: bounds,
    });
  } else {
    splitterLayouts.push({
      paneId,
      axis: 'horizontal',
      top: bounds.top,
      left: bounds.left + bounds.width * (ratio / 100) - splitterSize / 2,
      width: splitterSize,
      height: bounds.height,
      splitPaneBounds: bounds,
    });
  }

  return {
    contentLayouts: [
      ...leftResult.contentLayouts,
      ...rightResult.contentLayouts,
    ],
    splitterLayouts,
  };
}

export function calculatePaneLayouts(
  treeState: PaneTreeState<unknown>,
): {
  contentLayouts: PaneLayout[];
  splitterLayouts: SplitterLayout[];
} {
  if (!treeState || !treeState.panes || !treeState.rootPaneId) {
    return { contentLayouts: [], splitterLayouts: [] };
  }
  return layoutPane(treeState.panes, treeState.rootPaneId, {
    top: 0,
    left: 0,
    width: 100,
    height: 100,
    isRightmostOfRow: true,
    isBottommostOfColumn: true,
  });
}
