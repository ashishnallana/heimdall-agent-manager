import { tasksApi } from '../api/endpoints/tasks';

/**
 * A task chain's conversation is its coordinator's conversation.
 *
 * The chain list's `coordinator_agent_instance_id` column can be empty: the
 * canonical coordinator lives in `task_chain_members` (role 'coordinator'). This
 * resolves the agent from the chain detail when the list didn't carry it.
 */
export function coordinatorFromChainDetail(chain: any): string {
  if (!chain) return '';
  const direct = String(chain.coordinatorAgentInstanceId || chain.coordinator_agent_instance_id || '').trim();
  if (direct) return direct;
  const members: any[] = Array.isArray(chain.members) ? chain.members : [];
  const memberId = (m: any) => String(m?.agentInstanceId || m?.agent_instance_id || '').trim();
  const coordinator = members.find((m) => String(m?.role || '').toLowerCase() === 'coordinator' && memberId(m));
  return coordinator ? memberId(coordinator) : '';
}

/**
 * The agent whose conversation opening this chain should show, or '' when the
 * chain has no coordinator (callers then fall back to the chain page).
 */
export async function resolveChainConversationAgent(
  dispatch: (action: any) => any,
  chainId: string,
  knownCoordinator?: string,
): Promise<string> {
  const known = String(knownCoordinator || '').trim();
  if (known) return known;
  if (!chainId) return '';
  try {
    const result: any = await dispatch(
      (tasksApi.endpoints.fetchTaskChainDetail as any).initiate({ chainId }, { subscribe: false }),
    );
    return coordinatorFromChainDetail(result?.data?.chain);
  } catch {
    return '';
  }
}
