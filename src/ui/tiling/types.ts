import type * as React from 'react';

export type Axis = 'vertical' | 'horizontal';
export type SplitDirection = 'top' | 'bottom' | 'left' | 'right';
export type SplitInputDirection = Axis | SplitDirection;

export type PaneState<T> =
  | {
      kind: 'split';
      axis: Axis;
      leftChildId: string;
      rightChildId: string;
      ratio: number; // 5..95 (% for left/top child)
    }
  | {
      kind: 'content';
      value: T;
    };

export interface PaneTreeState<T> {
  rootPaneId: string;
  panes: Record<string, PaneState<T>>;
  focusedPaneId: string;
  maximizedPaneId?: string | null;
}

export interface PaneBounds {
  top: number;
  left: number;
  width: number;
  height: number;
  isRightmostOfRow: boolean;
  isBottommostOfColumn: boolean;
}

export interface PaneLayout extends PaneBounds {
  paneId: string;
}

export interface SplitterLayout {
  paneId: string; // ID of the split node
  axis: Axis;
  top: number;
  left: number;
  width: number;
  height: number;
  splitPaneBounds: PaneBounds;
}

export interface RenderPaneProps<T> {
  paneId: string;
  value: T;
  isFocused: boolean;
  isMaximized: boolean;
  isSinglePane: boolean;
  isTopLeftMost?: boolean;
  isTopRightMost?: boolean;
}

export interface TilingContainerProps<T> {
  treeState: PaneTreeState<T>;
  renderPane: (props: RenderPaneProps<T>) => React.ReactNode;
  renderSash?: (props: { axis: Axis }) => React.ReactNode;
  onMovePane?: (
    sourcePaneId: string,
    targetPaneId: string,
    direction: SplitDirection,
  ) => void;
  onResizePane?: (paneId: string, ratio: number) => void;
  onFocusPane?: (paneId: string) => void;
  /** Draws a 1px border between adjacent panes. Defaults to true. */
  paneDividers?: boolean;
  className?: string;
  paneAttributeName?: string;
}
