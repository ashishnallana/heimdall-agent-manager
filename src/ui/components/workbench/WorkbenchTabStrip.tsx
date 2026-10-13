import React from 'react';
import { Icon, type IconName } from '@ui';
import type { SplitDirection } from '../../tiling/types';
import {
  NEW_TAB_ID,
  WORKBENCH_SURFACE_REGISTRY,
  type WorkbenchSurfaceKind,
  type WorkbenchTabState,
} from '../../store/workbenchTabId';

export const WORKBENCH_SURFACE_ICONS: Record<WorkbenchSurfaceKind, IconName> = {
  agentChat: 'chat',
  agentPty: 'terminal',
  shell: 'terminal',
  preview: 'eye',
  files: 'folder',
  vcs: 'git-branch',
  chainOverview: 'layers',
  tasks: 'tasks',
};

export interface WorkbenchTabStripProps {
  paneId: string;
  tabs: WorkbenchTabState[];
  activeTabId: string | undefined;
  isFocused: boolean;
  isMaximized: boolean;
  isSinglePane: boolean;
  onSelectTab: (tabId: string) => void;
  onCloseTab: (tabId: string) => void;
  onOpenNewTab: () => void;
  onSplitPane: (direction: SplitDirection) => void;
  onToggleMaximize: () => void;
  onClosePane: () => void;
  onReorderTabs?: (fromIndex: number, toIndex: number) => void;
  onTabDragStart?: (tabId: string, event: React.PointerEvent) => void;
}

export function WorkbenchTabStrip({
  paneId,
  tabs,
  activeTabId,
  isFocused,
  isMaximized,
  isSinglePane,
  onSelectTab,
  onCloseTab,
  onOpenNewTab,
  onSplitPane,
  onToggleMaximize,
  onClosePane,
  onTabDragStart,
}: WorkbenchTabStripProps) {
  const showNewTabPill =
    (activeTabId === NEW_TAB_ID || tabs.length === 0) &&
    !tabs.some((t) => t.id === NEW_TAB_ID);
  const renderedTabs: WorkbenchTabState[] = showNewTabPill
    ? [
        ...tabs,
        {
          id: NEW_TAB_ID,
          kind: 'agentChat' as const,
          title: 'New Tab',
          closable: tabs.length > 0,
        },
      ]
    : tabs;

  return (
    <div
      data-debug-id={`workbench-tab-strip-${paneId}`}
      className={`flex h-9 shrink-0 select-none items-center justify-between border-b border-subtle px-1.5 transition-colors ${
        isFocused ? 'bg-surface-raised/80' : 'bg-surface/60'
      }`}
    >
      {/* Scrollable Tabs Row */}
      <div
        role="tablist"
        aria-label="Workbench pane tabs"
        className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto no-scrollbar py-1"
      >
        {renderedTabs.map((tab) => {
          const isNewTab = tab.id === NEW_TAB_ID;
          const isActive =
            tab.id === activeTabId ||
            (isNewTab && (activeTabId === NEW_TAB_ID || tabs.length === 0));
          const meta = WORKBENCH_SURFACE_REGISTRY[tab.kind];
          const iconName: IconName = isNewTab
            ? 'plus'
            : WORKBENCH_SURFACE_ICONS[tab.kind] || 'file';
          const displayTitle: string = isNewTab
            ? 'New Tab'
            : tab.title || (meta ? meta.defaultTitle(tab) : tab.id);

          return (
            <div
              key={tab.id}
              role="tab"
              aria-selected={isActive}
              data-debug-id={`workbench-tab-${tab.id}`}
              data-tab-id={tab.id}
              onClick={() => onSelectTab(tab.id)}
              onMouseDown={(e) => {
                // Middle click closes tab
                if (e.button === 1 && tab.closable !== false) {
                  e.preventDefault();
                  onCloseTab(tab.id);
                }
              }}
              onPointerDown={(e) => {
                if (!isNewTab && e.button === 0 && onTabDragStart) {
                  onTabDragStart(tab.id, e);
                }
              }}
              className={`group relative flex h-7 max-w-[200px] shrink-0 cursor-pointer items-center gap-1.5 rounded-md border px-2 text-xs transition-colors ${
                isActive
                  ? 'border-accent/40 bg-surface font-semibold text-primary shadow-2xs'
                  : 'border-transparent bg-transparent text-muted hover:bg-neutral-soft/60 hover:text-primary'
              }`}
            >
              <Icon
                name={iconName}
                size={12}
                className={isActive ? 'text-accent shrink-0' : 'text-muted shrink-0'}
              />
              <span className="truncate" title={displayTitle}>
                {displayTitle}
              </span>
              {tab.closable !== false ? (
                <button
                  type="button"
                  aria-label={`Close ${displayTitle}`}
                  data-debug-id={`workbench-tab-close-${tab.id}`}
                  onClick={(e) => {
                    e.stopPropagation();
                    onCloseTab(tab.id);
                  }}
                  className="ml-0.5 grid h-4 w-4 shrink-0 place-items-center rounded text-muted opacity-70 hover:bg-neutral-soft hover:text-primary group-hover:opacity-100"
                >
                  <Icon name="close" size={10} />
                </button>
              ) : null}
            </div>
          );
        })}

        {/* `+` Open NEW_TAB_ID Launcher Button */}
        <button
          type="button"
          onClick={onOpenNewTab}
          title="New Tab (+)"
          aria-label="Open new tab"
          data-debug-id={`workbench-pane-new-tab-btn-${paneId}`}
          className="grid h-6 w-6 shrink-0 place-items-center rounded text-muted transition-colors hover:bg-neutral-soft hover:text-primary"
        >
          <Icon name="plus" size={13} />
        </button>
      </div>

      {/* Right Pane Split / Maximize / Close Controls */}
      <div className="ml-1 flex shrink-0 items-center gap-0.5">
        <button
          type="button"
          onClick={() => onSplitPane('right')}
          title="Split Right"
          aria-label="Split pane right"
          data-debug-id={`workbench-pane-split-right-${paneId}`}
          className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
        >
          <Icon name="panel-right" size={12} />
        </button>
        <button
          type="button"
          onClick={() => onSplitPane('bottom')}
          title="Split Down"
          aria-label="Split pane down"
          data-debug-id={`workbench-pane-split-bottom-${paneId}`}
          className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
        >
          <Icon name="chevron-down" size={12} />
        </button>
        <button
          type="button"
          onClick={() => onSplitPane('left')}
          title="Split Left"
          aria-label="Split pane left"
          data-debug-id={`workbench-pane-split-left-${paneId}`}
          className="hidden sm:grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
        >
          <Icon name="chevron-left" size={12} />
        </button>
        <button
          type="button"
          onClick={() => onSplitPane('top')}
          title="Split Up"
          aria-label="Split pane top"
          data-debug-id={`workbench-pane-split-top-${paneId}`}
          className="hidden sm:grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
        >
          <Icon name="chevron-up" size={12} />
        </button>
        <button
          type="button"
          onClick={onToggleMaximize}
          title={isMaximized ? 'Restore pane size' : 'Maximize pane'}
          aria-label={isMaximized ? 'Restore pane size' : 'Maximize pane'}
          data-debug-id={`workbench-pane-maximize-${paneId}`}
          className={`grid h-6 w-6 place-items-center rounded transition-colors ${
            isMaximized
              ? 'bg-accent/15 text-accent'
              : 'text-muted hover:bg-neutral-soft hover:text-primary'
          }`}
        >
          <Icon name={isMaximized ? 'minimize' : 'maximize'} size={12} />
        </button>
        {!isSinglePane ? (
          <button
            type="button"
            onClick={onClosePane}
            title="Close Pane"
            aria-label="Close pane"
            data-debug-id={`workbench-pane-close-${paneId}`}
            className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-danger-soft hover:text-danger"
          >
            <Icon name="close" size={12} />
          </button>
        ) : null}
      </div>
    </div>
  );
}

export default WorkbenchTabStrip;
