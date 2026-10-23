// Provider extension permission cards. Changes arrive through the user WS;
// AgentBlockers invalidation refreshes the in-memory blocker snapshot.
import { cookieJsonFetch, cookieMutation, customQueryError } from '../cookieFetch';
import { heimdallApi } from '../heimdallApi';
import {
  normalizeBlockersSnapshot,
  type AgentBlockersSnapshot,
  type BlockerDecision,
} from '../../components/extension/blockersModel';

function instancePath(instanceId: string, leaf: string): string {
  return `/agent-instances/${encodeURIComponent(instanceId)}/${leaf}`;
}

export const extensionApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    getAgentBlockers: build.query<AgentBlockersSnapshot, string>({
      queryFn: async (instanceId) => {
        try {
          const raw = await cookieJsonFetch(instancePath(instanceId, 'blockers'));
          return { data: normalizeBlockersSnapshot(raw, instanceId) };
        } catch (error) {
          return { error: customQueryError(error) as any };
        }
      },
      providesTags: (_r, _e, instanceId) => [{ type: 'AgentBlockers' as const, id: instanceId }],
    }),
    resolveAgentBlocker: build.mutation<
      { resolved: boolean; delivered: boolean },
      { instanceId: string; blockerId: string; decision: BlockerDecision; message?: string }
    >({
      queryFn: async ({ instanceId, blockerId, decision, message }) => {
        try {
          const raw = await cookieMutation(
            `${instancePath(instanceId, 'blockers')}/${encodeURIComponent(blockerId)}/resolve`,
            'POST',
            message ? { decision, message } : { decision },
          );
          return { data: { resolved: Boolean(raw?.resolved ?? true), delivered: Boolean(raw?.delivered) } };
        } catch (error) {
          return { error: customQueryError(error) as any };
        }
      },
      // The bridge's next snapshot (agent_blockers_changed) drops the blocker; the
      // card hides it locally until then.
    }),
  }),
});

export const {
  useGetAgentBlockersQuery,
  useResolveAgentBlockerMutation,
} = extensionApi;
