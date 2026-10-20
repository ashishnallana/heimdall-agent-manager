import * as daemonApi from '../daemonApi';
import { heimdallApi, withSessionQuery } from '../heimdallApi';

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
export function normalizeChain(chain: any) {
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const result: any = {
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    id: chain.chain_id || chain.chainId || chain.id || '',
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    chainId: chain.chain_id || chain.chainId || chain.id || '',
    title: chain.title || '',
    status: chain.status || 'active',
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    projectId: chain.project_id || chain.projectId || '',
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    vcsWorkspaceId: chain.vcs_workspace_id || chain.vcsWorkspaceId || '',
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    diffBaseSha: chain.diff_base_sha || chain.diffBaseSha || '',
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    repoDiffSupported: Boolean(chain.repo_diff_supported || chain.repoDiffSupported),
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    coordinatorAgentInstanceId: chain.coordinator_agent_instance_id || chain.coordinatorAgentInstanceId || '',
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    defaultReviewerAgentInstanceId: chain.default_reviewer_agent_instance_id || chain.defaultReviewerAgentInstanceId || '',
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    createdAtUnixMs: Number(chain.created_at_unix_ms || chain.createdAtUnixMs || 0),
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    completedAtUnixMs: Number(chain.completed_at_unix_ms || chain.completedAtUnixMs || 0),
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    archivePending: Boolean(chain.archive_pending || chain.archivePending),
    archived: Boolean(chain.archived),
    evaluation: chain.evaluation || 'unreviewed',
  };
  if (chain.description !== undefined) {
    result.description = chain.description;
  }
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const summary = chain.final_summary !== undefined ? chain.final_summary : chain.finalSummary;
  if (summary !== undefined) {
    result.finalSummary = summary;
  }
  return result;
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function auth(session: any) {
  return { daemonUrl: session.daemonUrl, clientToken: session.clientToken };
}

export const workspaceApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    listChains: build.query<any, { createdAfter?: number; createdBefore?: number; limit?: number; offset?: number; status?: string } | void>({
      queryFn: withSessionQuery(async (arg, { session }) => {
        if (!session?.clientToken) return { chains: [], totalCount: 0, hasMore: false, offset: 0 };
        const args = (arg && typeof arg === 'object') ? arg : {};
        const limit = args.limit ?? 10000;
        const offset = args.offset ?? 0;
        const status = args.status;
        const data = await daemonApi.listTaskChains({
          ...auth(session),
          createdAfter: args.createdAfter,
          createdBefore: args.createdBefore,
          limit,
          offset,
          status,
        });
        const chains = (data.chains || []).map(normalizeChain);
        const totalCount = data.total_count || 0;
        const hasMore = offset + chains.length < totalCount;
        return { chains, totalCount, hasMore, offset };
      }),
      providesTags: (result, _error, arg) => [
        { type: 'ChainList' as const, id: JSON.stringify(arg || {}) },
        // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
        ...((result?.chains || []).map((chain: any) => ({ type: 'Chain' as const, id: chain.chainId })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    fetchChainsPage: build.query<any, { createdAfter?: number; createdBefore?: number; limit: number; offset: number; status?: string }>({
      queryFn: withSessionQuery(async (arg, { session }) => {
        if (!session?.clientToken) return { chains: [], totalCount: 0, hasMore: false, offset: 0 };
        const data = await daemonApi.listTaskChains({
          ...auth(session),
          createdAfter: arg.createdAfter,
          createdBefore: arg.createdBefore,
          limit: arg.limit,
          offset: arg.offset,
          status: arg.status,
        });
        const chains = (data.chains || []).map(normalizeChain);
        const totalCount = data.total_count || 0;
        const hasMore = arg.offset + chains.length < totalCount;
        return { chains, totalCount, hasMore, offset: arg.offset };
      }),
      async onQueryStarted(arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
          const baseArgs = {} as any;
          if (arg.createdAfter !== undefined) baseArgs.createdAfter = arg.createdAfter;
          if (arg.createdBefore !== undefined) baseArgs.createdBefore = arg.createdBefore;
          if (arg.status !== undefined) baseArgs.status = arg.status;
          dispatch(
            // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
            workspaceApi.util.updateQueryData('listChains', baseArgs, (draft: any) => {
              if (!draft) return;
              // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
              const existingIds = new Set(draft.chains.map((c: any) => c.chainId));
              for (const chain of data.chains) {
                if (!existingIds.has(chain.chainId)) {
                  draft.chains.push(chain);
                }
              }
              draft.totalCount = data.totalCount;
              draft.hasMore = data.hasMore;
              draft.offset = data.offset;
            })
          );
        } catch (_error) {
          // noop
        }
      },
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    fetchChain: build.query<any, { chainId: string }>({
      queryFn: withSessionQuery(async ({ chainId }, { session }) => {
        if (!session?.clientToken || !chainId) return { chain: null };
        const data = await daemonApi.fetchTaskChain({ ...auth(session), chainId });
        return { chain: data?.chain ? normalizeChain(data.chain) : null };
      }),
      providesTags: (_result, _error, { chainId }) => [{ type: 'Chain' as const, id: chainId }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    focusChain: build.mutation<any, { chainId: string }>({
      queryFn: withSessionQuery(async ({ chainId }, { session }) => {
        if (!session?.clientToken || !chainId) return { ok: false, message: 'Missing chain' };
        return daemonApi.focusTaskChain({ ...auth(session), chainId });
      }),
      invalidatesTags: (_result, _error, { chainId }) => [{ type: 'Chain' as const, id: chainId }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    updateChain: build.mutation<any, { chainId: string; title?: string; description?: string; coordinatorAgentInstanceId?: string; defaultReviewerAgentInstanceId?: string; finalSummary?: string }>({
      queryFn: withSessionQuery(async ({ chainId, title, description, coordinatorAgentInstanceId, defaultReviewerAgentInstanceId, finalSummary }, { session }) => {
        if (!session?.clientToken || !chainId) return { ok: false, message: 'Missing chain' };
        return daemonApi.updateTaskChain({ ...auth(session), chainId, title, description, coordinatorAgentInstanceId, defaultReviewerAgentInstanceId, finalSummary });
      }),
      invalidatesTags: (_result, _error, { chainId }) => [
        { type: 'Chain' as const, id: chainId },
        { type: 'ChainList' as const, id: 'ALL' },
      ],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    updateChainStatus: build.mutation<any, { chainId: string; status: string; finalSummary?: string }>({
      queryFn: withSessionQuery(async ({ chainId, status, finalSummary }, { session }) => {
        if (!session?.clientToken || !chainId) return { ok: false, message: 'Missing chain' };
        return daemonApi.updateTaskChainStatus({ ...auth(session), chainId, status, finalSummary });
      }),
      invalidatesTags: (_result, _error, { chainId }) => [
        { type: 'Chain' as const, id: chainId },
        { type: 'ChainList' as const, id: 'ALL' },
      ],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    fetchWorkspace: build.query<any, { chainId: string }>({
      queryFn: withSessionQuery(async ({ chainId }, { session }) => {
        if (!session?.clientToken || !chainId) return { chainId, workspace: null };
        const data = await daemonApi.fetchWorkspace({ ...auth(session), chainId });
        return { chainId, workspace: data?.workspace || null };
      }),
      providesTags: (_result, _error, { chainId }) => [{ type: 'Workspace' as const, id: chainId }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    previewWorkspaceMerge: build.query<any, { chainId: string }>({
      queryFn: withSessionQuery(async ({ chainId }, { session }) => {
        if (!session?.clientToken || !chainId) return { chainId, preview: null };
        // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
        const preview = await daemonApi.previewWorkspaceMerge({ ...auth(session), chainId }).catch((err: any) => ({ ok: false, message: err?.message || 'preview failed' }));
        return { chainId, preview };
      }),
      providesTags: (_result, _error, { chainId }) => [{ type: 'Workspace' as const, id: chainId }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    fetchWorkspaceDiff: build.query<any, { chainId: string; file?: string }>({
      queryFn: withSessionQuery(async ({ chainId, file = '' }, { session }) => {
        if (!session?.clientToken || !chainId) return { chainId, file, diff: null };
        const diff = await daemonApi.fetchWorkspaceDiff({ ...auth(session), chainId, file }).catch(() => null);
        return { chainId, file, diff };
      }),
      providesTags: (_result, _error, { chainId, file = '' }) => [{ type: 'WorkspaceDiff' as const, id: `${chainId}:${file}` }],
    }),
  }),
});
