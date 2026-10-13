import React from 'react';
import type { SplitDirection } from '../../tiling/types';
import {
  NEW_TAB_ID,
  type WorkbenchSurfaceKind,
  type WorkbenchTabState,
} from '../../store/workbenchTabId';
import type { TabbedPaneState } from '../../store/workbenchSlice';
import { WorkbenchTabStrip } from './WorkbenchTabStrip';
import { WorkbenchNewTabLauncher } from './WorkbenchNewTabLauncher';
import { AgentChatPane } from './AgentChatPane';
import { AgentPtyWorkbenchPane } from './AgentPtyWorkbenchPane';
import { ShellWorkbenchPane } from './ShellWorkbenchPane';
import { PreviewWorkbenchPane } from './PreviewWorkbenchPane';
import ChainOverviewPanel from '../chat/ChainOverviewPanel';
import TaskChainOverview from '../taskchain/TaskChainOverview';

const ProjectFilesPanel = React.lazy(() => import('../chat/ProjectFilesPanel'));
const ProjectVcsPanel = React.lazy(() => import('../chat/ProjectVcsPanel'));

export interface WorkbenchPaneViewProps {
  paneId: string;
  pane: TabbedPaneState;
  workspaceKey: string;
  primaryAgentInstanceId: string;
  chainId?: string;
  projectId?: string;
  projectName?: string;
  bridgeId?: string;
  defaultCwd?: string;
  projectVcsEnabled?: boolean;
  directories?: any[];
  members?: any[];
  focusMessageId?: string;
  isFocused: boolean;
  isMaximized: boolean;
  isSinglePane: boolean;
  isMobile?: boolean;
  pendingDropDirection?: SplitDirection | null;
  onFocusPane: () => void;
  onSelectTab: (tabId: string) => void;
  onCloseTab: (tabId: string) => void;
  onOpenNewTab: () => void;
  onReplaceNewTab: (tab: Partial<WorkbenchTabState> & { kind: WorkbenchSurfaceKind }) => void;
  onOpenOrFocusTab: (tab: Partial<WorkbenchTabState> & { kind: WorkbenchSurfaceKind }) => void;
  onOpenInRightSplit?: (tab: Partial<WorkbenchTabState> & { kind: WorkbenchSurfaceKind }) => void;
  onUpdateTabParams: (tabId: string, patch: Partial<WorkbenchTabState>) => void;
  onReplaceTab?: (
    tabId: string,
    tab: Partial<WorkbenchTabState> & { kind: WorkbenchSurfaceKind },
  ) => void;
  onSplitPane: (direction: SplitDirection) => void;
  onToggleMaximize: () => void;
  onClosePane: () => void;
  onTabDragStart?: (tabId: string, event: React.PointerEvent) => void;
  onPublishComments?: (markdown: string) => Promise<boolean>;
  onOpenQuickOpen?: () => void;
}

function getDropOverlayClasses(direction: SplitDirection): string {
  switch (direction) {
    case 'left':
      return 'inset-y-0 left-0 w-1/2';
    case 'right':
      return 'inset-y-0 right-0 w-1/2';
    case 'top':
      return 'inset-x-0 top-0 h-1/2';
    case 'bottom':
      return 'inset-x-0 bottom-0 h-1/2';
  }
}

export function WorkbenchPaneView({
  paneId,
  pane,
  workspaceKey,
  primaryAgentInstanceId,
  chainId,
  projectId,
  projectName,
  bridgeId,
  defaultCwd,
  projectVcsEnabled = true,
  directories,
  members,
  focusMessageId,
  isFocused,
  isMaximized,
  isSinglePane,
  isMobile = false,
  pendingDropDirection,
  onFocusPane,
  onSelectTab,
  onCloseTab,
  onOpenNewTab,
  onReplaceNewTab,
  onOpenOrFocusTab,
  onOpenInRightSplit,
  onUpdateTabParams,
  onReplaceTab,
  onSplitPane,
  onToggleMaximize,
  onClosePane,
  onTabDragStart,
  onPublishComments,
  onOpenQuickOpen,
}: WorkbenchPaneViewProps) {
  const tabs = pane.tabs;
  const activeTabId = pane.activeTabId ?? tabs[0]?.id;
  const isNewTabLauncherActive = activeTabId === NEW_TAB_ID || tabs.length === 0;
  const hideTabStrip =
    tabs.length === 1 && tabs[0]?.kind === 'agentChat' && !isNewTabLauncherActive;
  const openFromChatPane = onOpenInRightSplit || onOpenOrFocusTab;

  return (
    <div
      data-debug-id={`workbench-pane-view-${paneId}`}
      onMouseDown={onFocusPane}
      className={`relative flex h-full min-h-0 w-full min-w-0 flex-col overflow-hidden bg-surface ${
        isFocused && !isSinglePane ? 'ring-1 ring-inset ring-accent/30' : ''
      }`}
    >
      {/* Per-Pane Tab Strip (hidden visually when a pane has only a single agentChat tab so the chat header is the sole bar, matching Jetski) */}
      <div
        data-debug-id={`workbench-pane-tabstrip-wrapper-${paneId}`}
        className={hideTabStrip ? 'hidden' : 'shrink-0'}
      >
        <WorkbenchTabStrip
          paneId={paneId}
          tabs={tabs}
          activeTabId={activeTabId}
          isFocused={isFocused}
          isMaximized={isMaximized}
          isSinglePane={isSinglePane}
          onSelectTab={onSelectTab}
          onCloseTab={onCloseTab}
          onOpenNewTab={onOpenNewTab}
          onSplitPane={onSplitPane}
          onToggleMaximize={onToggleMaximize}
          onClosePane={onClosePane}
          onTabDragStart={onTabDragStart}
          isMobile={isMobile}
        />
      </div>

      {/* Keep-Alive Tab Content Stack: all open tabs in the pane stay mounted with CSS `hidden` when inactive */}
      <div
        data-debug-id={`workbench-pane-body-${paneId}`}
        className="relative flex flex-1 min-h-0 w-full min-w-0 flex-col overflow-hidden"
      >
        {tabs.map((tab) => {
          const isActive = !isNewTabLauncherActive && tab.id === activeTabId;

          return (
            <div
              key={tab.id}
              data-debug-id={`workbench-tab-panel-${tab.id}`}
              aria-hidden={!isActive}
              className={
                isActive
                  ? 'flex h-full min-h-0 w-full min-w-0 flex-1 flex-col overflow-hidden'
                  : 'hidden'
              }
            >
              {tab.id === NEW_TAB_ID ? (
                <WorkbenchNewTabLauncher
                  paneId={paneId}
                  primaryAgentInstanceId={primaryAgentInstanceId}
                  chainId={chainId}
                  projectId={projectId}
                  bridgeId={bridgeId}
                  projectVcsEnabled={projectVcsEnabled}
                  onSelectSurface={onReplaceNewTab}
                />
              ) : tab.kind === 'agentChat' ? (
                <AgentChatPane
                  agentInstanceId={tab.agentInstanceId || primaryAgentInstanceId}
                  workspaceKey={workspaceKey}
                  paneId={paneId}
                  tabId={tab.id}
                  focusMessageId={
                    (tab.agentInstanceId || primaryAgentInstanceId) === primaryAgentInstanceId
                      ? tab.focusMessageId || focusMessageId
                      : tab.focusMessageId
                  }
                  isActiveTab={isActive}
                  isMobile={isMobile}
                  isSinglePane={isSinglePane}
                  projectVcsEnabled={projectVcsEnabled}
                  onOpenSurface={(kind, params) => openFromChatPane({ kind, ...params })}
                  onOpenPty={(targetId, ptyTitle) =>
                    openFromChatPane({
                      kind: 'agentPty',
                      agentInstanceId: targetId,
                      title: ptyTitle || `${targetId} PTY`,
                    })
                  }
                  onSwitchAgent={(nextAgentId, nextTitle) =>
                    onReplaceTab
                      ? onReplaceTab(tab.id, {
                          kind: 'agentChat',
                          agentInstanceId: nextAgentId,
                          ...(nextTitle ? { title: nextTitle } : {}),
                        })
                      : onUpdateTabParams(tab.id, {
                          agentInstanceId: nextAgentId,
                          ...(nextTitle ? { title: nextTitle } : {}),
                        })
                  }
                  onSplitPane={onSplitPane}
                  onReplaceWithNew={onOpenNewTab}
                  onClosePane={onClosePane}
                />
              ) : tab.kind === 'agentPty' ? (
                <AgentPtyWorkbenchPane
                  agentInstanceId={tab.agentInstanceId || primaryAgentInstanceId}
                  title={tab.title}
                  workspaceKey={workspaceKey}
                  paneId={paneId}
                  chainId={chainId}
                  projectId={projectId}
                  members={members}
                  isActiveTab={isActive}
                  onSelectAgentInstance={(nextAgentId, nextTitle) =>
                    onUpdateTabParams(tab.id, {
                      agentInstanceId: nextAgentId,
                      ...(nextTitle ? { title: nextTitle } : {}),
                    })
                  }
                  onOpenChat={(targetId) =>
                    onOpenOrFocusTab({
                      kind: 'agentChat',
                      agentInstanceId: targetId,
                    })
                  }
                  onClose={() => onCloseTab(tab.id)}
                />
              ) : tab.kind === 'shell' ? (
                <ShellWorkbenchPane
                  sessionId={
                    tab.sessionId && tab.sessionId !== 'default' && tab.sessionId !== 'new'
                      ? tab.sessionId
                      : undefined
                  }
                  bridgeId={tab.bridgeId || bridgeId}
                  projectId={projectId}
                  chainId={chainId}
                  agentInstanceId={tab.agentInstanceId || primaryAgentInstanceId}
                  defaultCwd={tab.currentPath || defaultCwd}
                  isActiveTab={isActive}
                  onSelectSession={(nextSessionId) =>
                    onUpdateTabParams(tab.id, { sessionId: nextSessionId })
                  }
                />
              ) : tab.kind === 'preview' ? (
                <PreviewWorkbenchPane
                  sessionId={tab.sessionId || 'default'}
                  port={tab.port}
                  currentPath={tab.currentPath}
                  label={tab.title}
                  workspaceKey={workspaceKey}
                  paneId={paneId}
                  tabId={tab.id}
                  isActiveTab={isActive}
                  onClose={() => onCloseTab(tab.id)}
                />
              ) : tab.kind === 'files' ? (
                <React.Suspense fallback={null}>
                  <ProjectFilesPanel
                    agentInstanceId={tab.agentInstanceId || primaryAgentInstanceId}
                    projectId={projectId || ''}
                    chainId={chainId}
                    directories={directories}
                    members={members}
                    bridgeId={tab.bridgeId || bridgeId}
                    projectName={projectName}
                    conversationKey={workspaceKey}
                    onPublishComments={
                      onPublishComments || (async () => false)
                    }
                    onClose={() => onCloseTab(tab.id)}
                    isMobile={isMobile}
                    openFilePath={tab.openFilePath || tab.initialFilePath || null}
                    onFileOpened={() =>
                      onUpdateTabParams(tab.id, { openFilePath: null, initialFilePath: null })
                    }
                    onOpenQuickOpen={onOpenQuickOpen}
                    initialOpenSearchInFiles={tab.initialOpenSearchInFiles}
                    onSearchDrawerConsumed={() =>
                      onUpdateTabParams(tab.id, { initialOpenSearchInFiles: false })
                    }
                    initialOpenCommandPalette={tab.initialOpenCommandPalette}
                    onCommandPaletteConsumed={() =>
                      onUpdateTabParams(tab.id, { initialOpenCommandPalette: false })
                    }
                  />
                </React.Suspense>
              ) : tab.kind === 'vcs' ? (
                <React.Suspense fallback={null}>
                  <ProjectVcsPanel
                    projectId={projectId || ''}
                    experimentEnabled={Boolean(projectVcsEnabled)}
                    bridgeId={tab.bridgeId || bridgeId}
                    onClose={() => onCloseTab(tab.id)}
                    isMobile={isMobile}
                    openFilePath={tab.openFilePath || tab.initialFilePath || null}
                    onFileOpened={() =>
                      onUpdateTabParams(tab.id, { openFilePath: null, initialFilePath: null })
                    }
                    onOpenDirectory={(dirPath: string) =>
                      onOpenOrFocusTab({
                        kind: 'files',
                        title: 'Files',
                        openFilePath: dirPath,
                        initialFilePath: dirPath,
                      })
                    }
                  />
                </React.Suspense>
              ) : tab.kind === 'chainOverview' ? (
                <ChainOverviewPanel
                  chainId={chainId || ''}
                  projectId={projectId || ''}
                  bridgeId={tab.bridgeId || bridgeId}
                  agentInstanceId={tab.agentInstanceId || primaryAgentInstanceId}
                  projectVcsEnabled={Boolean(projectVcsEnabled)}
                  onClose={() => onCloseTab(tab.id)}
                  onSelectTask={(taskId) =>
                    onOpenOrFocusTab({
                      kind: 'tasks',
                      title: 'Tasks',
                      focusTaskId: taskId || undefined,
                    })
                  }
                  onOpenFileDiff={(filePath) =>
                    onOpenOrFocusTab({
                      kind: 'vcs',
                      title: 'VCS / Diff',
                      openFilePath: filePath,
                      initialFilePath: filePath,
                    })
                  }
                  onOpenVcsFiles={() =>
                    onOpenOrFocusTab({
                      kind: 'vcs',
                      title: 'VCS / Diff',
                    })
                  }
                  onOpenAgentChat={(targetInstId, agentTitle) =>
                    onOpenOrFocusTab({
                      kind: 'agentChat',
                      agentInstanceId: targetInstId,
                      title: agentTitle || targetInstId,
                    })
                  }
                  onOpenAgentPty={(targetInstId, agentTitle) =>
                    onOpenOrFocusTab({
                      kind: 'agentPty',
                      agentInstanceId: targetInstId,
                      title: agentTitle ? `${agentTitle} PTY` : `${targetInstId} PTY`,
                    })
                  }
                  isMobile={isMobile}
                />
              ) : tab.kind === 'tasks' ? (
                <TaskChainOverview
                  chainId={chainId || ''}
                  focusTaskId={tab.focusTaskId}
                  onClose={() => onCloseTab(tab.id)}
                  isMobile={isMobile}
                  embedded={true}
                />
              ) : null}
            </div>
          );
        })}

        {isNewTabLauncherActive ? (
          <div
            key={NEW_TAB_ID}
            data-debug-id={`workbench-tab-panel-${NEW_TAB_ID}`}
            aria-hidden={false}
            className="flex h-full min-h-0 w-full min-w-0 flex-1 flex-col overflow-hidden"
          >
            <WorkbenchNewTabLauncher
              paneId={paneId}
              primaryAgentInstanceId={primaryAgentInstanceId}
              chainId={chainId}
              projectId={projectId}
              bridgeId={bridgeId}
              projectVcsEnabled={projectVcsEnabled}
              onSelectSurface={onReplaceNewTab}
            />
          </div>
        ) : null}
      </div>

      {/* Drag-and-drop split preview overlay */}
      {pendingDropDirection ? (
        <div
          data-debug-id={`workbench-pane-drop-overlay-${paneId}`}
          className={`pointer-events-none absolute z-30 border-2 border-accent bg-accent/15 transition-all ${getDropOverlayClasses(
            pendingDropDirection,
          )}`}
        />
      ) : null}
    </div>
  );
}

export default WorkbenchPaneView;
