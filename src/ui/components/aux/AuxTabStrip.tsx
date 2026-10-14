import React from 'react';
import { Icon, Menu, type IconName } from '@ui';
import {
  NEW_TAB_ID,
  auxTabTitle,
  type AuxTab,
  type AuxTabKind,
} from '../../store/auxTabId';

export const AUX_TAB_ICONS: Record<AuxTabKind, IconName> = {
  chainOverview: 'layers',
  files: 'folder',
  vcs: 'git-branch',
  tasks: 'tasks',
  shell: 'terminal',
  agentPty: 'bot',
  preview: 'eye',
  subagentChat: 'chat',
};

export const AUX_TAB_DRAG_MIME = 'application/x-heimdall-aux-tab';

export interface AuxTabStripProps {
  /** Stable key of the tree (debug ids only). */
  treeKey: string;
  tabs: AuxTab[];
  activeTabId: string | undefined;
  onSelectTab: (tabId: string) => void;
  onCloseTab: (tabId: string) => void;
  onOpenNewTab: () => void;
  onMoveTab?: (tabId: string, toIndex: number) => void;
  /** ⋮ menu content for the active tab (rendered by the dock). */
  menuContent?: React.ReactNode;
  isMaximized?: boolean;
  onToggleMaximize?: () => void;
  onCloseDock: () => void;
  /** Optional status dot per tab (e.g. a PTY/sub-agent runtime state). */
  renderTabStatus?: (tab: AuxTab) => React.ReactNode;
  isMobile?: boolean;
}

/**
 * The aux dock's ONE tab strip: tabs (title, icon, status dot, close), `+`
 * new-tab launcher, the ⋮ menu for the active tab, maximize and close. There
 * are no split controls inside the aux (Jetski parity).
 */
export function AuxTabStrip({
  treeKey,
  tabs,
  activeTabId,
  onSelectTab,
  onCloseTab,
  onOpenNewTab,
  onMoveTab,
  menuContent,
  isMaximized = false,
  onToggleMaximize,
  onCloseDock,
  renderTabStatus,
  isMobile = false,
}: AuxTabStripProps) {
  const [menuOpen, setMenuOpen] = React.useState(false);
  const showNewTabPill = activeTabId === NEW_TAB_ID || tabs.length === 0;

  return (
    <div
      data-debug-id={`aux-tab-strip-${treeKey}`}
      className="flex h-10 shrink-0 select-none items-center justify-between border-b border-subtle bg-surface-raised/60 px-1.5"
    >
      <div
        role="tablist"
        aria-label="Aux tabs"
        className="no-scrollbar flex min-w-0 flex-1 items-center gap-1 overflow-x-auto py-1"
      >
        {tabs.map((tab, index) => {
          const isActive = tab.id === activeTabId;
          const title = auxTabTitle(tab);
          return (
            <div
              key={tab.id}
              role="tab"
              aria-selected={isActive}
              data-debug-id={`aux-tab-${tab.id}`}
              data-tab-id={tab.id}
              draggable={Boolean(onMoveTab) && !isMobile}
              onDragStart={(e) => {
                e.dataTransfer.effectAllowed = 'move';
                e.dataTransfer.setData(AUX_TAB_DRAG_MIME, tab.id);
                e.dataTransfer.setData('text/plain', tab.id);
              }}
              onDragOver={(e) => {
                if (onMoveTab) e.preventDefault();
              }}
              onDrop={(e) => {
                const dragged = e.dataTransfer.getData(AUX_TAB_DRAG_MIME);
                if (dragged && dragged !== tab.id && onMoveTab) {
                  e.preventDefault();
                  onMoveTab(dragged, index);
                }
              }}
              onClick={() => onSelectTab(tab.id)}
              onMouseDown={(e) => {
                if (e.button === 1) {
                  e.preventDefault();
                  onCloseTab(tab.id);
                }
              }}
              className={`group relative flex h-7 max-w-[200px] shrink-0 cursor-pointer items-center gap-1.5 rounded-md border px-2 text-xs transition-colors ${
                isActive
                  ? 'border-accent/40 bg-surface font-semibold text-primary shadow-2xs'
                  : 'border-transparent bg-transparent text-muted hover:bg-neutral-soft/60 hover:text-primary'
              }`}
            >
              <Icon
                name={AUX_TAB_ICONS[tab.content.type] || 'file'}
                size={12}
                className={isActive ? 'shrink-0 text-accent' : 'shrink-0 text-muted'}
              />
              {renderTabStatus ? renderTabStatus(tab) : null}
              <span className="truncate" title={title}>
                {title}
              </span>
              <button
                type="button"
                aria-label={`Close ${title}`}
                data-debug-id={`aux-tab-close-${tab.id}`}
                onClick={(e) => {
                  e.stopPropagation();
                  onCloseTab(tab.id);
                }}
                className="ml-0.5 grid h-4 w-4 shrink-0 place-items-center rounded text-muted opacity-70 hover:bg-neutral-soft hover:text-primary group-hover:opacity-100"
              >
                <Icon name="close" size={10} />
              </button>
            </div>
          );
        })}

        {showNewTabPill ? (
          <div
            role="tab"
            aria-selected={true}
            data-debug-id={`aux-tab-${NEW_TAB_ID}`}
            className="flex h-7 shrink-0 items-center gap-1.5 rounded-md border border-accent/40 bg-surface px-2 text-xs font-semibold text-primary"
          >
            <Icon name="plus" size={12} className="shrink-0 text-accent" />
            <span>New Tab</span>
            {tabs.length > 0 ? (
              <button
                type="button"
                aria-label="Close New Tab"
                data-debug-id={`aux-tab-close-${NEW_TAB_ID}`}
                onClick={() => onCloseTab(NEW_TAB_ID)}
                className="ml-0.5 grid h-4 w-4 shrink-0 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
              >
                <Icon name="close" size={10} />
              </button>
            ) : null}
          </div>
        ) : null}

        <button
          type="button"
          onClick={onOpenNewTab}
          title="New Tab (+)"
          aria-label="Open new tab"
          data-debug-id={`aux-new-tab-btn-${treeKey}`}
          className="grid h-6 w-6 shrink-0 place-items-center rounded text-muted transition-colors hover:bg-neutral-soft hover:text-primary"
        >
          <Icon name="plus" size={13} />
        </button>
      </div>

      <div className="ml-1 flex shrink-0 items-center gap-0.5">
        <Menu
          align="end"
          label="Tab options"
          open={menuOpen}
          onOpenChange={setMenuOpen}
          className="w-60 max-w-[calc(100vw-2rem)] z-50"
          trigger={
            <button
              type="button"
              title="More options"
              aria-label="Tab options"
              data-debug-id={`aux-overflow-menu-btn-${treeKey}`}
              className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
            >
              <Icon name="more-vertical" size={14} />
            </button>
          }
        >
          {menuContent}
        </Menu>
        {onToggleMaximize && !isMobile ? (
          <button
            type="button"
            onClick={onToggleMaximize}
            title={isMaximized ? 'Restore side panel' : 'Maximize side panel'}
            aria-label={isMaximized ? 'Restore side panel' : 'Maximize side panel'}
            data-debug-id={`aux-maximize-btn-${treeKey}`}
            className={`grid h-6 w-6 place-items-center rounded transition-colors ${
              isMaximized ? 'bg-accent/15 text-accent' : 'text-muted hover:bg-neutral-soft hover:text-primary'
            }`}
          >
            <Icon name={isMaximized ? 'minimize' : 'maximize'} size={12} />
          </button>
        ) : null}
        <button
          type="button"
          onClick={onCloseDock}
          title="Close side panel"
          aria-label="Close side panel"
          data-debug-id={`aux-close-dock-btn-${treeKey}`}
          className="grid h-6 w-6 place-items-center rounded text-muted hover:bg-neutral-soft hover:text-primary"
        >
          <Icon name="close" size={12} />
        </button>
      </div>
    </div>
  );
}

export default AuxTabStrip;
