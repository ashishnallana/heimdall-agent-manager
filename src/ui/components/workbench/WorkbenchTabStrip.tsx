import React from 'react';
import { Icon, Menu, type IconName } from '@ui';
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
  const [menuOpen, setMenuOpen] = React.useState(false);
  const runAndClose = (fn: () => void) => {
    setMenuOpen(false);
    fn();
  };
  const activeClosableTabId =
    activeTabId &&
    activeTabId !== NEW_TAB_ID &&
    tabs.some((t) => t.id === activeTabId && t.closable !== false)
      ? activeTabId
      : null;
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

      {/* Right Pane Controls: overflow (⋮) menu with split / maximize / close actions */}
      <div className="ml-1 flex shrink-0 items-center gap-0.5">
        <Menu
          align="end"
          label="Pane options"
          open={menuOpen}
          onOpenChange={setMenuOpen}
          className="w-56 max-w-[calc(100vw-2rem)] z-30"
          trigger={
            <button
              type="button"
              title="More options"
              aria-label="Pane options"
              data-debug-id={`workbench-pane-overflow-menu-btn-${paneId}`}
              className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
            >
              <Icon name="more-vertical" size={14} />
            </button>
          }
        >
          <Menu.Item
            data-debug-id={`workbench-pane-new-tab-action-${paneId}`}
            onClick={() => runAndClose(onOpenNewTab)}
          >
            <Icon name="plus" size={15} />
            <span>New Tab</span>
          </Menu.Item>
          {activeClosableTabId ? (
            <Menu.Item
              data-debug-id={`workbench-pane-close-tab-action-${paneId}`}
              onClick={() => runAndClose(() => onCloseTab(activeClosableTabId))}
            >
              <Icon name="close" size={15} />
              <span>Close Tab</span>
            </Menu.Item>
          ) : null}
          <Menu.Separator />
          <Menu.Label>Split</Menu.Label>
          <Menu.Item
            data-debug-id={`workbench-pane-split-right-${paneId}`}
            onClick={() => runAndClose(() => onSplitPane('right'))}
          >
            <Icon name="panel-right" size={15} />
            <span>Split Right</span>
          </Menu.Item>
          <Menu.Item
            data-debug-id={`workbench-pane-split-bottom-${paneId}`}
            onClick={() => runAndClose(() => onSplitPane('bottom'))}
          >
            <Icon name="chevron-down" size={15} />
            <span>Split Down</span>
          </Menu.Item>
          <Menu.Item
            data-debug-id={`workbench-pane-split-left-${paneId}`}
            onClick={() => runAndClose(() => onSplitPane('left'))}
          >
            <Icon name="panel-left" size={15} />
            <span>Split Left</span>
          </Menu.Item>
          <Menu.Item
            data-debug-id={`workbench-pane-split-top-${paneId}`}
            onClick={() => runAndClose(() => onSplitPane('top'))}
          >
            <Icon name="chevron-up" size={15} />
            <span>Split Up</span>
          </Menu.Item>
          <Menu.Separator />
          <Menu.Item
            data-debug-id={`workbench-pane-maximize-action-${paneId}`}
            onClick={() => runAndClose(onToggleMaximize)}
          >
            <Icon name={isMaximized ? 'minimize' : 'maximize'} size={15} />
            <span>{isMaximized ? 'Restore Pane' : 'Maximize Pane'}</span>
          </Menu.Item>
          {!isSinglePane ? (
            <Menu.Item
              data-debug-id={`workbench-pane-close-action-${paneId}`}
              onClick={() => runAndClose(onClosePane)}
            >
              <Icon name="trash" size={15} />
              <span>Remove from Split</span>
            </Menu.Item>
          ) : null}
        </Menu>
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
