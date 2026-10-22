import { useMemo } from 'react';
import { useFetchAgentInstanceQuery } from '../../api/endpoints/agents';
import { useFetchConversationQuery } from '../../api/endpoints/chats';
import { useFetchProjectQuery } from '../../api/endpoints/projects';
import { useFetchExperimentsQuery } from '../../api/endpoints/settings';
import { useFetchTaskChainDetailQuery } from '../../api/endpoints/tasks';
import { chainParticipantIdsFromMembers } from '../../store/auxTabGuards';
import { resolveProjectVcsExperiment } from '../chat/projectVcsExperiment';
import { resolveProjectBridgeShellCwd } from '../shells/interactiveShellLaunch';

export interface AuxChainMember {
  agentInstanceId: string;
  agentId: string;
  displayName: string;
  role: string;
}

/**
 * Everything an aux tab needs about the agent that owns the shown strip (the
 * focused Main pane's agent): chain, project, bridge, shell cwd, chain
 * participants. The chain is CONTEXT only; it never keys the layout.
 */
export interface AgentAuxContext {
  agentInstanceId: string;
  conversationId: string;
  title: string;
  chainId: string;
  projectId: string;
  projectName: string;
  bridgeId: string;
  defaultCwd: string;
  shellDefaultCwd?: string;
  shellCwdReady: boolean;
  projectVcsEnabled: boolean;
  directories: string[];
  members: AuxChainMember[];
  /** Participant ids once the chain detail has loaded; null otherwise. */
  participantIds: Set<string> | null;
  /** True once we know whether the agent belongs to a chain. */
  isResolved: boolean;
}

export function useAgentAuxContext(agentInstanceId: string | null | undefined): AgentAuxContext {
  const id = String(agentInstanceId || '');
  const { data: instanceData, isSuccess: instanceLoaded } = useFetchAgentInstanceQuery(
    { instanceId: id },
    // Event-driven (agent_instance/* full summary); see wsInvalidation.ts.
    { skip: !id },
  );
  const { data: convData, isSuccess: convLoaded } = useFetchConversationQuery(
    { conversationId: '', agentInstanceId: id },
    { skip: !id },
  );
  const instance: any = instanceData?.instance;
  const conversation: any = convData?.conversation;

  const chainId = String(
    conversation?.chain_id || conversation?.chainId || instance?.chain_id || instance?.chainId || '',
  );
  const projectId = String(
    conversation?.project_id || conversation?.projectId || instance?.project_id || instance?.projectId || '',
  );
  const bridgeId = String(
    instance?.bridge_id || instance?.bridgeId || conversation?.bridge_id || conversation?.bridgeId || '',
  );
  const conversationId = String(conversation?.conversation_id || conversation?.conversationId || '');
  const title = String(
    conversation?.title || instance?.display_name || instance?.displayName || id || 'Agent',
  );

  const {
    data: projectData,
    isLoading: isProjectLoading,
    isFetching: isProjectFetching,
  } = useFetchProjectQuery({ projectId }, { skip: !projectId });
  const { data: experimentsData } = useFetchExperimentsQuery();
  const { data: chainData } = useFetchTaskChainDetailQuery(
    { chainId },
    { skip: !chainId },
  );

  const project: any = projectData?.project;
  const projectName = String(project?.name || '');
  const defaultCwd = String(
    project?.default_path || project?.defaultPath || instance?.cwd || instance?.working_dir || '',
  );
  const shellDefaultCwd = resolveProjectBridgeShellCwd(project, bridgeId);
  const shellCwdReady = !projectId || (!isProjectLoading && !isProjectFetching);
  const projectVcsEnabled = useMemo(
    () => resolveProjectVcsExperiment(experimentsData?.flags) === 'enabled',
    [experimentsData?.flags],
  );

  const directories = useMemo<string[]>(() => {
    const raw = (chainData?.chain as any)?.directories || project?.directories || [];
    if (Array.isArray(raw)) return raw.map((d) => String(d || '').trim()).filter(Boolean);
    return defaultCwd ? [defaultCwd] : [];
  }, [chainData?.chain, defaultCwd, project]);

  const members = useMemo<AuxChainMember[]>(() => {
    const raw = (chainData as any)?.members || (chainData?.chain as any)?.members || [];
    if (!Array.isArray(raw)) return [];
    return raw
      .map((m: any) => ({
        // task_chain_members is keyed by (chain_id, agent_instance_id): the agent
        // instance id is the stable participant identity within a chain.
        agentInstanceId: String(m?.agentInstanceId || m?.agent_instance_id || ''),
        agentId: String(m?.agentId || m?.agent_id || ''),
        displayName: String(m?.displayName || m?.display_name || ''),
        role: String(m?.role || ''),
      }))
      .filter((m: AuxChainMember) => m.agentInstanceId);
  }, [chainData]);

  const participantIds = useMemo(() => {
    if (!chainId || members.length === 0) return null;
    const ids = chainParticipantIdsFromMembers(members);
    if (id) ids.add(id);
    return ids;
  }, [chainId, id, members]);

  return {
    agentInstanceId: id,
    conversationId,
    title,
    chainId,
    projectId,
    projectName,
    bridgeId,
    defaultCwd,
    shellDefaultCwd,
    shellCwdReady,
    projectVcsEnabled,
    directories,
    members,
    participantIds,
    isResolved: Boolean(chainId) || instanceLoaded || convLoaded,
  };
}
