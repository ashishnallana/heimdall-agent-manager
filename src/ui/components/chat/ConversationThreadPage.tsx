import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { useSelector } from 'react-redux';
import { useFetchAgentInstanceQuery } from '../../api/endpoints/agents';
import {
  useFetchConversationQuery,
  useSendConversationMessageMutation,
} from '../../api/endpoints/chats';
import { useFetchProjectQuery } from '../../api/endpoints/projects';
import { useFetchExperimentsQuery } from '../../api/endpoints/settings';
import { useFetchTaskChainDetailQuery } from '../../api/endpoints/tasks';
import { selectIsVaultUnlocked, getActiveVaultKey } from '../../store/vaultSlice';
import { getRouteSearch } from '../../utils/appLocation';
import { resolveWorkbenchWorkspaceKey } from '../../utils/clientPersistence';
import { encryptVaultText } from '../../utils/vaultContent';
import { resolveProjectVcsExperiment } from './projectVcsExperiment';
import { resolveProjectBridgeShellCwd } from '../shells/interactiveShellLaunch';
import { ConversationWorkbench } from '../workbench/ConversationWorkbench';
import { WindowTilingHost } from '../windowTiling/WindowTilingHost';

export const COMPOSER_DRAFT_KEY = 'heimdall:composer:draft';

export interface ConversationThreadPageProps {
  agentInstanceId: string;
  focusMessageId?: string;
  workspaceKey?: string;
  chainId?: string;
  projectId?: string;
  initialPanelParam?: string | null;
  initialFilePathParam?: string | null;
  initialTaskIdParam?: string | null;
  isMobile?: boolean;
  withWindowTiling?: boolean;
}

export function ConversationThreadPage({
  agentInstanceId,
  focusMessageId,
  workspaceKey: explicitWorkspaceKey,
  chainId: explicitChainId,
  projectId: explicitProjectId,
  initialPanelParam,
  initialFilePathParam,
  initialTaskIdParam,
  isMobile: explicitIsMobile,
  withWindowTiling = false,
}: ConversationThreadPageProps) {
  const isVaultUnlocked = useSelector(selectIsVaultUnlocked);

  const [isMobileViewport, setIsMobileViewport] = useState<boolean>(() =>
    typeof window !== 'undefined' ? window.innerWidth < 768 : false,
  );

  useEffect(() => {
    if (typeof window === 'undefined') return;
    const onResize = () => setIsMobileViewport(window.innerWidth < 768);
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, []);

  const { data: instanceData } = useFetchAgentInstanceQuery(
    { instanceId: agentInstanceId },
    { skip: !agentInstanceId, pollingInterval: 10000 },
  );
  const { data: convData } = useFetchConversationQuery(
    { conversationId: '', agentInstanceId },
    { skip: !agentInstanceId, pollingInterval: 8000 },
  );

  const instance = instanceData?.instance;
  const conversation = convData?.conversation;

  const conversationId = String(
    conversation?.conversation_id || conversation?.conversationId || '',
  );
  const chainId = String(
    explicitChainId ||
      conversation?.chain_id ||
      conversation?.chainId ||
      instance?.chain_id ||
      instance?.chainId ||
      '',
  );
  const projectId = String(
    explicitProjectId ||
      conversation?.project_id ||
      conversation?.projectId ||
      instance?.project_id ||
      instance?.projectId ||
      '',
  );
  const bridgeId = String(
    instance?.bridge_id ||
      instance?.bridgeId ||
      conversation?.bridge_id ||
      conversation?.bridgeId ||
      '',
  );
  const primaryAgentTitle = String(
    conversation?.title ||
      instance?.display_name ||
      instance?.displayName ||
      agentInstanceId ||
      'Agent Chat',
  );

  const { data: projectData, isLoading: isProjectLoading, isFetching: isProjectFetching } = useFetchProjectQuery(
    { projectId },
    { skip: !projectId },
  );
  const { data: experimentsData } = useFetchExperimentsQuery();
  const { data: chainData } = useFetchTaskChainDetailQuery(
    { chainId },
    { skip: !chainId, pollingInterval: 10000 },
  );

  const project = projectData?.project;
  const projectName = String(project?.name || '');
  const defaultCwd = String(
    project?.default_path ||
      project?.defaultPath ||
      instance?.cwd ||
      instance?.working_dir ||
      '',
  );
  const shellDefaultCwd = resolveProjectBridgeShellCwd(project, bridgeId);
  const shellCwdReady = !projectId || (!isProjectLoading && !isProjectFetching);
  const projectVcsEnabled = useMemo(
    () => resolveProjectVcsExperiment(experimentsData?.flags) === 'enabled',
    [experimentsData?.flags],
  );

  const directories = useMemo<string[]>(() => {
    const rawDirs =
      (chainData?.chain as any)?.directories ||
      (project as any)?.directories ||
      [];
    if (Array.isArray(rawDirs)) {
      return rawDirs.map((d) => String(d || '').trim()).filter(Boolean);
    }
    return defaultCwd ? [defaultCwd] : [];
  }, [chainData?.chain, defaultCwd, project]);

  const members = useMemo(() => {
    const rawMembers = (chainData as any)?.members || (chainData?.chain as any)?.members || [];
    if (!Array.isArray(rawMembers)) return [];
    return rawMembers
      .map((m: any) => ({
        // task_chain_members is keyed by (chain_id, agent_instance_id), so the
        // agent instance id is the stable participant identity within a chain.
        agentInstanceId: String(m?.agentInstanceId || m?.agent_instance_id || ''),
        agentId: String(m?.agentId || m?.agent_id || ''),
        displayName: String(m?.displayName || m?.display_name || ''),
        role: String(m?.role || ''),
      }))
      .filter((m: any) => m.agentInstanceId);
  }, [chainData]);

  const routeParams = useMemo(() => {
    const search = getRouteSearch();
    const params = new URLSearchParams(search || '');
    return {
      panel: params.get('panel') || params.get('sidebar') || null,
      file: params.get('file') || params.get('path') || null,
      task: params.get('task') || params.get('taskId') || null,
      focus: params.get('focus') || params.get('messageId') || undefined,
    };
  }, [agentInstanceId]);

  const workspaceKey = useMemo(
    () =>
      explicitWorkspaceKey ||
      resolveWorkbenchWorkspaceKey({
        chainId: chainId || null,
        agentInstanceId,
      }),
    [agentInstanceId, chainId, explicitWorkspaceKey],
  );

  const [sendConversationMessage] = useSendConversationMessageMutation();

  const handlePublishComments = useCallback(
    async (formattedMessage: string): Promise<boolean> => {
      const text = formattedMessage.trim();
      if (!text || !agentInstanceId) return false;
      let payloadBody = text;
      const key = getActiveVaultKey();
      if (isVaultUnlocked && key) {
        try {
          payloadBody = await encryptVaultText(text, key);
        } catch {
          // Fallback to plaintext if encryption fails
        }
      }
      await sendConversationMessage({
        conversationId: conversationId || agentInstanceId,
        body: payloadBody,
      }).unwrap();
      return true;
    },
    [agentInstanceId, conversationId, isVaultUnlocked, sendConversationMessage],
  );

  const workbenchProps = {
    workspaceKey,
    primaryAgentInstanceId: agentInstanceId,
    primaryAgentTitle,
    chainId: chainId || undefined,
    projectId: projectId || undefined,
    projectName: projectName || undefined,
    bridgeId: bridgeId || undefined,
    defaultCwd: defaultCwd || undefined,
    shellDefaultCwd,
    shellCwdReady,
    projectVcsEnabled,
    directories,
    members,
    focusMessageId: focusMessageId || routeParams.focus,
    initialPanelParam:
      initialPanelParam !== undefined ? initialPanelParam : routeParams.panel,
    initialFilePathParam:
      initialFilePathParam !== undefined ? initialFilePathParam : routeParams.file,
    initialTaskIdParam:
      initialTaskIdParam !== undefined ? initialTaskIdParam : routeParams.task,
    isMobile: explicitIsMobile ?? isMobileViewport,
    onPublishComments: handlePublishComments,
  };

  // Mobile flattens everything into one side-scrolling pane pager, so the
  // window-level tiling layer is skipped there.
  if (withWindowTiling && !(explicitIsMobile ?? isMobileViewport)) {
    return (
      <section
        data-debug-id="conversation-thread-page"
        className="relative flex h-full min-h-0 w-full max-w-full flex-1 flex-col overflow-hidden bg-canvas p-0 text-left"
      >
        <WindowTilingHost
          activeAgentInstanceId={agentInstanceId}
          activeChainId={chainId || null}
          activeProjectId={projectId || null}
          activeFocusMessageId={focusMessageId || routeParams.focus}
          activeTitle={primaryAgentTitle}
          activeWorkbenchProps={workbenchProps}
        />
      </section>
    );
  }

  return (
    <section
      data-debug-id="conversation-thread-page"
      className="relative flex h-full min-h-0 w-full max-w-full flex-1 flex-col overflow-hidden bg-canvas p-0 text-left"
    >
      <ConversationWorkbench {...workbenchProps} />
    </section>
  );
}

export default ConversationThreadPage;
