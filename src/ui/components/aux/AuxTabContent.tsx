import React, { Suspense } from 'react';
import {
  isProvisionalShellSessionId,
  newShellTabContent,
  type AuxContent,
  type AuxTab,
} from '../../store/auxTabId';
import { isAuxContentAllowed } from '../../store/auxTabGuards';
import ChainOverviewPanel from '../chat/ChainOverviewPanel';
import TaskChainOverview from '../taskchain/TaskChainOverview';
import { AgentChatPane } from '../workbench/AgentChatPane';
import { AgentPtyWorkbenchPane } from '../workbench/AgentPtyWorkbenchPane';
import { PreviewWorkbenchPane } from '../workbench/PreviewWorkbenchPane';
import { ShellWorkbenchPane } from '../workbench/ShellWorkbenchPane';
import type { AgentAuxContext } from './useAgentAuxContext';

const ProjectFilesPanel = React.lazy(() => import('../chat/ProjectFilesPanel'));
const ProjectVcsPanel = React.lazy(() => import('../chat/ProjectVcsPanel'));

export interface AuxTabContentProps {
  tab: AuxTab;
  ctx: AgentAuxContext;
  isMobile?: boolean;
  onOpenTab: (content: AuxContent, title?: string) => void;
  onUpdateTab: (tabId: string, patch: Record<string, unknown>) => void;
  onRekeyTab: (tabId: string, content: AuxContent, title?: string) => void;
  onPublishComments?: (markdown: string) => Promise<boolean>;
}

function EmptyNotice({ debugId, children }: { debugId: string; children: React.ReactNode }) {
  return (
    <div
      data-debug-id={debugId}
      className="grid h-full min-h-[160px] place-items-center p-6 text-center text-xs text-muted"
    >
      {children}
    </div>
  );
}

/**
 * Renders ONE aux tab's main content and nothing else: no title bar, close
 * button, selector or status pill (the strip owns those; actions live in ⋮).
 * The dock mounts only the active tab, keyed by tab id (Jetski keep-alive
 * parity), so terminals and previews reattach when re-activated.
 */
export function AuxTabContent({
  tab,
  ctx,
  isMobile = false,
  onOpenTab,
  onUpdateTab,
  onRekeyTab,
  onPublishComments,
}: AuxTabContentProps) {
  const c = tab.content;
  switch (c.type) {
    case 'chainOverview':
      if (!ctx.chainId) {
        return (
          <EmptyNotice debugId="aux-overview-no-chain">
            This agent is not part of a task chain.
          </EmptyNotice>
        );
      }
      return (
        <ChainOverviewPanel
          chainId={ctx.chainId}
          projectId={ctx.projectId}
          bridgeId={ctx.bridgeId}
          agentInstanceId={ctx.agentInstanceId}
          projectVcsEnabled={ctx.projectVcsEnabled}
          isMobile={isMobile}
          onSelectTask={(taskId) => onOpenTab({ type: 'tasks', ...(taskId ? { taskId } : {}) })}
          onOpenFileDiff={(filePath) => onOpenTab({ type: 'vcs', filePath })}
          onOpenVcsFiles={() => onOpenTab({ type: 'vcs' })}
          onOpenAgentChat={(agentInstanceId, title) => {
            if (agentInstanceId === ctx.agentInstanceId) return; // already in Main
            onOpenTab({ type: 'subagentChat', agentInstanceId }, title);
          }}
          onOpenAgentPty={(agentInstanceId, title) =>
            onOpenTab({ type: 'agentPty', agentInstanceId }, title ? `${title} terminal` : undefined)
          }
        />
      );
    case 'files':
      return (
        <Suspense fallback={null}>
          <ProjectFilesPanel
            agentInstanceId={ctx.agentInstanceId}
            projectId={ctx.projectId}
            chainId={ctx.chainId || undefined}
            directories={ctx.directories as any}
            members={ctx.members}
            bridgeId={ctx.bridgeId}
            projectName={ctx.projectName}
            conversationKey={ctx.agentInstanceId}
            onPublishComments={onPublishComments || (async () => false)}
            isMobile={isMobile}
            openFilePath={c.path || null}
            onFileOpened={() => onUpdateTab(tab.id, { path: null })}
            initialOpenSearchInFiles={c.openSearch}
            onSearchDrawerConsumed={() => onUpdateTab(tab.id, { openSearch: false })}
            initialOpenCommandPalette={c.openCommandPalette}
            onCommandPaletteConsumed={() => onUpdateTab(tab.id, { openCommandPalette: false })}
          />
        </Suspense>
      );
    case 'vcs':
      return (
        <Suspense fallback={null}>
          <ProjectVcsPanel
            projectId={ctx.projectId}
            experimentEnabled={ctx.projectVcsEnabled}
            bridgeId={ctx.bridgeId}
            isMobile={isMobile}
            openFilePath={c.filePath || null}
            onFileOpened={() => onUpdateTab(tab.id, { filePath: null })}
            onOpenDirectory={(dirPath: string) => onOpenTab({ type: 'files', path: dirPath })}
          />
        </Suspense>
      );
    case 'tasks':
      if (!ctx.chainId) {
        return (
          <EmptyNotice debugId="aux-tasks-no-chain">
            This agent is not part of a task chain.
          </EmptyNotice>
        );
      }
      return (
        <TaskChainOverview
          chainId={ctx.chainId}
          focusTaskId={c.taskId}
          isMobile={isMobile}
          embedded={true}
          hideTitleBar={true}
        />
      );
    case 'shell': {
      const bound = isProvisionalShellSessionId(c.sessionId) ? undefined : c.sessionId;
      return (
        <ShellWorkbenchPane
          sessionId={bound}
          bridgeId={c.bridgeId || ctx.bridgeId}
          projectId={ctx.projectId}
          chainId={ctx.chainId}
          agentInstanceId={ctx.agentInstanceId}
          defaultCwd={c.cwd || ctx.shellDefaultCwd}
          cwdReady={ctx.shellCwdReady}
          autoCreate={!bound}
          isActiveTab={true}
          onSelectSession={(sessionId) => {
            if (sessionId && sessionId !== c.sessionId) {
              onRekeyTab(tab.id, { ...c, sessionId });
            }
          }}
          onNewShell={() => onOpenTab(newShellTabContent())}
        />
      );
    }
    case 'agentPty':
      return <AgentPtyWorkbenchPane agentInstanceId={c.agentInstanceId} isActiveTab={true} />;
    case 'preview':
      return (
        <PreviewWorkbenchPane
          sessionId={c.sessionId}
          port={c.port}
          currentPath={c.path}
          label={tab.title}
          isActiveTab={true}
        />
      );
    case 'subagentChat': {
      const allowed = isAuxContentAllowed(c, {
        ownerAgentId: ctx.agentInstanceId,
        chainId: ctx.chainId,
        participantIds: ctx.participantIds,
      });
      if (!allowed && ctx.participantIds) {
        return (
          <EmptyNotice debugId="aux-subagent-not-participant">
            This agent is not a participant of the current task chain.
          </EmptyNotice>
        );
      }
      return (
        <AgentChatPane
          agentInstanceId={c.agentInstanceId}
          variant="auxSubagent"
          isMobile={isMobile}
          projectVcsEnabled={ctx.projectVcsEnabled}
          onOpenAuxTab={onOpenTab}
        />
      );
    }
    default:
      return null;
  }
}

export default AuxTabContent;
