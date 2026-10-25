import { tasksApi } from '../api/endpoints/tasks';

/**
 * A task chain's conversation is its coordinator's conversation. Chain-entry
 * links address it by CHAIN (`chainConversationRoute`, REQ-TV2-7), never by
 * the coordinator instance id.
 */
export { chainConversationRoute } from './paneTarget';

/**
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
 * The chain's current coordinator instance, or '' when the chain has none
 * (callers then fall back to the chain page). Callers open the chain's
 * `chain:<id>` target when this is non-empty; the instance itself is resolved
 * again by the pane (GET /task-chains/{id}/conversation).
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
