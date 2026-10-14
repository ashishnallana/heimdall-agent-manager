import type { LiveProject } from '../../api/endpoints/agentsLive';

export function findChainIdForInstance(
  instanceId: string,
  liveProjects?: LiveProject[],
): string | undefined {
  if (!instanceId || !liveProjects) return undefined;
  for (const project of liveProjects) {
    for (const chain of project.chains || []) {
      if (chain.coordinatorAgentInstanceId === instanceId) return chain.chainId;
      if (chain.liveAgents?.some((a) => a.agentInstanceId === instanceId)) return chain.chainId;
      if (chain.members?.some((m) => m.agentInstanceId === instanceId)) return chain.chainId;
    }
  }
  return undefined;
}

/**
 * Resolves the chain of the conversation the route points at.
 *
 * `conversation` MUST be the result for `agentInstanceId` only (RTK Query's
 * `currentData`, not `data`): `data` still holds the PREVIOUS instance's
 * conversation while the new one loads, and feeding its chain id into the
 * window layout pins the new pane to the previous chain's workbench (whose chat
 * tab is the previous agent). A conversation for a different instance is
 * ignored here as a second line of defence.
 */
export function resolveActiveChainId(
  agentInstanceId: string,
  conversation: any,
  liveProjects?: LiveProject[],
): string | undefined {
  if (!agentInstanceId) return undefined;
  const convInstanceId = String(
    conversation?.agent_instance_id || conversation?.agentInstanceId || '',
  );
  if (conversation && (!convInstanceId || convInstanceId === agentInstanceId)) {
    const fromConv = conversation.chain_id || conversation.chainId;
    if (fromConv) return String(fromConv);
  }
  return findChainIdForInstance(agentInstanceId, liveProjects);
}
