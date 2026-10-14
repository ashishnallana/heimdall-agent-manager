import * as daemonApi from '../daemonApi';
import { applyAgentRuntimeEvent, loadKnownAgents, mapAgent, mergeKnownAndLiveAgents, storeKnownAgents, upsertKnownAgentRecord } from '../agentCatalog';
import { apiErrorText, cookieMutation, cookieJsonFetch, cookieJsonFetchEnvelope, customQueryError } from '../cookieFetch';
import { announcePaneVaultLocked } from '../../utils/vaultLockedError';
import { heimdallApi, withSessionQuery } from '../heimdallApi';

export interface GetAgentPaneArgs {
  agentInstanceId: string;
  sinceHash?: string;
  width?: number;
  lineLimit?: number;
}

export interface AgentPaneResult {
  ok?: boolean;
  status?: string;
  unchanged?: boolean;
  hash?: string;
  output?: string;
  line_count?: number;
  truncated?: boolean;
  [key: string]: any;
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function agentTagId(agent: any, fallback = '') {
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  return String(agent?.id || agent?.agent_instance_id || agent?.agentInstanceId || fallback || '');
}

export const agentsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    listAgentIdentities: build.query<{ agents: any[] }, { limit?: number; cursor?: string } | void>({
      queryFn: async (arg) => {
        try {
          const params = new URLSearchParams();
          const opts = (arg && typeof arg === 'object') ? arg : undefined;
          if (opts?.limit) params.set('limit', String(opts.limit));
          if (opts?.cursor) params.set('cursor', opts.cursor);
          const qs = params.toString() ? `?${params.toString()}` : '';
          const data = await cookieJsonFetch(`/agents${qs}`);
          const agents = Array.isArray(data) ? data : (data?.agents || []);
          return { data: { agents } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [{ type: 'Agents' as const, id: 'LIST' }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    listAgentTemplates: build.query<any, void>({
      queryFn: async () => {
        try {
          const data = await cookieJsonFetch('/templates');
          return { data: { templates: data || [] } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [{ type: 'AgentTemplate' as const, id: 'LIST' }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    createAgentTemplate: build.mutation<any, { name: string; description?: string; persona?: string; instructions?: string }>({
      queryFn: async (payload) => {
        try {
          const data = await cookieMutation('/templates', 'POST', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: 'AgentTemplate' as const, id: 'LIST' }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    updateAgentTemplate: build.mutation<any, { templateId: string; name?: string; description?: string; persona?: string; instructions?: string }>({
      queryFn: async ({ templateId, ...payload }) => {
        try {
          const data = await cookieMutation(`/templates/${encodeURIComponent(templateId)}`, 'PATCH', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: 'AgentTemplate' as const, id: 'LIST' }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    deleteAgentTemplate: build.mutation<any, { templateId: string }>({
      queryFn: async ({ templateId }) => {
        try {
          const data = await cookieMutation(`/templates/${encodeURIComponent(templateId)}`, 'DELETE');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: 'AgentTemplate' as const, id: 'LIST' }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    fetchAgentIdentity: build.query<any, { agentId: string }>({
      queryFn: async ({ agentId }) => {
        if (!agentId) return { data: { agent: null } };
        try {
          const data = await cookieJsonFetch(`/agents/${encodeURIComponent(agentId)}`);
          return { data: { agent: data || null } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { agentId }) => [{ type: 'Agents' as const, id: agentId }],
      // Agent identities (name/persona) change rarely; keep cached across chain +
      // conversation switches (was the 30s global default). Identity mutations
      // invalidate the Agents id tag.
      keepUnusedDataFor: 600,
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    updateAgentIdentity: build.mutation<any, { agentId: string; name?: string; slug?: string; templateId?: string; instructions?: string }>({
      queryFn: async ({ agentId, name, slug, templateId, instructions }) => {
        try {
          // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
          const payload: any = {};
          if (name !== undefined) payload.name = name;
          // Slug is mutable (`agent_service.odin:115`: `if input.slug != "" do agent.slug = input.slug`).
          // Send only when non-empty; an empty slug is treated as "no change" server-side.
          if (slug) payload.slug = slug;
          // Only send template_id when explicitly provided; the hub applies it only
          // when the key is present (has_template_id), so omitting it leaves the
          // agent's template unchanged.
          if (templateId !== undefined) payload.template_id = templateId;
          if (instructions !== undefined) payload.instructions = instructions;
          const data = await cookieMutation(`/agents/${encodeURIComponent(agentId)}`, 'PATCH', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { agentId }) => [{ type: 'Agents' as const, id: 'LIST' }, { type: 'Agents' as const, id: agentId }, { type: 'BridgeSupport' as const, id: agentId }],
    }),
    enableBridgeSupport: build.mutation<any, { agentId: string; bridges?: Array<{ bridgeId?: string; bridge_id?: string; enabled?: boolean; provider?: string; providerProfile?: string; model?: string; priority?: number; maxInstances?: number }> }>({
      queryFn: async ({ agentId, bridges }) => {
        try {
          let rows = bridges || [];
          if (!rows.length) {
            const bridgesData = await cookieJsonFetch('/bridges');
            rows = (bridgesData?.bridges || bridgesData || []).map((b: any) => ({ bridgeId: b.bridge_id, enabled: true }));
          }
          const payload = {
            bridges: rows.map((b: any) => ({
              bridge_id: b.bridge_id || b.bridgeId,
              enabled: b.enabled !== false,
              provider: b.provider || b.providerProfile || '',
              model: b.model || b.model || '',
              priority: b.priority || 0,
              max_instances: b.maxInstances || 0,
            }))
          };
          const data = await cookieMutation(`/agents/${encodeURIComponent(agentId)}/bridge-support`, 'PUT', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { agentId }) => [{ type: 'Agents' as const, id: 'LIST' }, { type: 'BridgeSupport' as const, id: agentId }],
    }),
    listAgents: build.query<any, { limit?: number; offset?: number; projectId?: string; running?: boolean } | void>({
      queryFn: withSessionQuery(async (arg, { session }) => {
        const localKnown = loadKnownAgents();
        if (!session?.daemonUrl) {
          const agents = mergeKnownAndLiveAgents(localKnown, [], false, false);
          storeKnownAgents(agents);
          return { agents, identities: [], totalCount: 0, hasMore: false, offset: 0 };
        }

        const args = (arg && typeof arg === 'object') ? arg : {};
        const limit = args.limit ?? 10000;
        const offset = args.offset ?? 0;
        const projectId = args.projectId ?? '';
        const running = args.running;
        const isPaged = args.limit !== undefined || args.offset !== undefined;

        let daemonAgents: any[] = [];
        let daemonIdentities: any[] = [];
        let daemonReachable = false;
        let totalCount = 0;
        let hasMore = false;
        try {
          const catalog = await daemonApi.listKnownAgentsCatalog({
            daemonUrl: session.daemonUrl,
            projectId,
            includeIdentities: true,
            includeConversations: true,
            limit,
            offset,
            running,
          });
          daemonAgents = catalog.agents || [];
          daemonIdentities = catalog.identities || [];
          daemonReachable = true;
          totalCount = catalog.total || 0;
          hasMore = catalog.hasMore || false;
        } catch {
          daemonAgents = [];
          daemonIdentities = [];
        }

        const agents = mergeKnownAndLiveAgents(localKnown, daemonAgents, daemonReachable, isPaged);
        storeKnownAgents(agents);
        return { agents, identities: daemonIdentities, totalCount, hasMore, offset };
      }),
      providesTags: (result, _error, arg) => [
        { type: 'Agents' as const, id: JSON.stringify(arg || {}) },
        ...((result?.agents || []).map((agent: any) => ({ type: 'Agents' as const, id: agentTagId(agent) })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    fetchAgentsPage: build.query<any, { limit: number; offset: number; projectId?: string; running?: boolean }>({
      queryFn: withSessionQuery(async (arg, { session }) => {
        const localKnown = loadKnownAgents();
        if (!session?.daemonUrl) {
          const agents = mergeKnownAndLiveAgents(localKnown, [], false, false);
          return { agents, identities: [], totalCount: 0, hasMore: false, offset: arg.offset };
        }
        const data = await daemonApi.listKnownAgentsCatalog({
          daemonUrl: session.daemonUrl,
          projectId: arg.projectId,
          includeIdentities: true,
          includeConversations: true,
          limit: arg.limit,
          offset: arg.offset,
          running: arg.running,
        });
        const daemonAgents = data.agents || [];
        const daemonIdentities = data.identities || [];
        const agents = mergeKnownAndLiveAgents(localKnown, daemonAgents, true, true);
        return {
          agents,
          identities: daemonIdentities,
          totalCount: data.total || 0,
          hasMore: data.hasMore || false,
          offset: arg.offset,
        };
      }),
      async onQueryStarted(arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          const baseArgs: any = {};
          if (arg.projectId) baseArgs.projectId = arg.projectId;
          if (arg.running !== undefined) baseArgs.running = arg.running;
          const cacheKeyArgs = Object.keys(baseArgs).length > 0 ? baseArgs : undefined;
          dispatch(
            agentsApi.util.updateQueryData('listAgents', cacheKeyArgs as any, (draft: any) => {
              if (!draft) return;
              const existingIds = new Set(draft.agents.map((a: any) => a.id));
              for (const agent of data.agents) {
                if (!existingIds.has(agent.id)) {
                  draft.agents.push(agent);
                }
              }
              const existingIdentities = new Set(draft.identities.map((id: any) => id.agent_id || id.agentId));
              for (const identity of data.identities) {
                const id = identity.agent_id || identity.agentId;
                if (!existingIdentities.has(id)) {
                  draft.identities.push(identity);
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
    fetchAgent: build.query<any, { agentInstanceId?: string; agentRecordId?: string }>({
      queryFn: withSessionQuery(async ({ agentInstanceId = '', agentRecordId = '' }, { session }) => {
        if (!session?.daemonUrl || (!agentInstanceId && !agentRecordId)) return { agent: null };
        const data = await daemonApi.showAgent({ daemonUrl: session.daemonUrl, agentInstanceId, agentRecordId });
        const rawAgent = data?.agent || data?.record || data || null;
        return { agent: rawAgent ? mapAgent(rawAgent) : null };
      }),
      providesTags: (result, _error, { agentInstanceId = '', agentRecordId = '' }) => [{
        type: 'Agents' as const,
        id: agentTagId(result?.agent, agentInstanceId || agentRecordId),
      }],
      async onQueryStarted(_arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          if (!data?.agent) return;
          dispatch(agentsApi.util.updateQueryData('listAgents', undefined, (draft: any) => {
            const rows = draft?.agents || (draft.agents = []);
            upsertKnownAgentRecord(rows, data.agent);
          }));
        } catch (_error) {
          // noop
        }
      },
    }),
    startAgent: build.mutation<any, { agentInstanceId: string; provider: string; templateId?: string; projectId?: string; projectIdSet?: boolean; alias?: string; displayName?: string; model?: string }>({
      queryFn: withSessionQuery(async ({ agentInstanceId, provider, templateId, projectId, projectIdSet, alias, displayName, model }, { session }) => {
        if (!session?.daemonUrl || !agentInstanceId) return { ok: false, message: 'Missing agent' };
        return daemonApi.startAgent({ daemonUrl: session.daemonUrl, agentInstanceId, provider, templateId, projectId, projectIdSet, alias, displayName, model });
      }),
      invalidatesTags: (_result, _error, { agentInstanceId }) => [
        { type: 'Agents' as const, id: 'LIST' },
        { type: 'Agents' as const, id: agentInstanceId },
      ],
    }),
    stopAgent: build.mutation<any, { agentInstanceId: string; timeInSec?: number }>({
      queryFn: withSessionQuery(async ({ agentInstanceId, timeInSec }, { session }) => {
        if (!session?.daemonUrl || !agentInstanceId) return { ok: false, message: 'Missing agent' };
        return daemonApi.stopAgent({ daemonUrl: session.daemonUrl, agentInstanceId, timeInSec });
      }),
      invalidatesTags: (_result, _error, { agentInstanceId }) => [
        { type: 'Agents' as const, id: 'LIST' },
        { type: 'Agents' as const, id: agentInstanceId },
      ],
    }),
    // UI-8: Add agent to chain via the rewrite API (POST /api/v1/agent-instances
    // with existing chain_id). Hydrates a fresh AgentInstance into the chain and
    // creates its 1:1 conversation; never attaches an unrelated live instance.
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    createAgentInstanceInChain: build.mutation<any, { agentId: string; chainId: string; bridgeId?: string; providerProfile?: string; model?: string; projectId?: string; displayName?: string; templateId?: string }>({
      // Launch a new instance of a durable agent, bound to a chain. Uses the cookie
      // path (POST /agent-instances) like launchAgentInstance, so it works in the
      // trusted-proxy/cookie-auth shell. The previous token-based path required a
      // session.clientToken that the cookie shell never has, so "Launch new" from
      // the Add-Member dialog always failed with "Missing agentId/chainId" even
      // with an agent selected. The hub create endpoint reads provider/model (not
      // provider_profile/model), so map to those field names.
      queryFn: async ({ agentId, chainId, bridgeId, providerProfile, model, projectId, displayName, templateId }) => {
        if (!agentId || !chainId) return { data: { ok: false, message: 'Choose an agent identity to launch.' } };
        try {
          // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
          const payload: any = { agent_id: agentId, chain_id: chainId };
          if (bridgeId) payload.bridge_id = bridgeId;
          if (providerProfile) payload.provider = providerProfile;
          if (model) payload.model = model;
          if (projectId) payload.project_id = projectId;
          if (displayName) payload.display_name = displayName;
          if (templateId) payload.template_id = templateId;
          const data = await cookieMutation('/agent-instances', 'POST', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [
        { type: 'Agents' as const, id: 'LIST' },
        { type: 'ChainTasks' as const, id: chainId },
      ],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    createAgent: build.mutation<any, { name: string; slug?: string; templateId?: string; instructions?: string; favorite?: boolean }>({
      queryFn: async (arg) => {
        try {
          // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
          const payload: any = {
            name: arg.name,
            // TODO(FIX): Replace loose fallback chain with canonical typed schema property
            slug: arg.slug || arg.name,
            ...(arg.favorite !== undefined ? { favorite: arg.favorite } : {}),
            template_id: arg.templateId || '',
            instructions: arg.instructions || '',
          };
          const data = await cookieMutation('/agents', 'POST', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: 'Agents' as const, id: 'LIST' }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    archiveAgentIdentity: build.mutation<any, { agentId: string }>({
      queryFn: async ({ agentId }) => {
        try {
          const data = await cookieMutation(`/agents/${encodeURIComponent(agentId)}/archive`, 'POST');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: 'Agents' as const, id: 'LIST' }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    listAgentInstances: build.query<any, { agentId?: string; projectId?: string; limit?: number; cursor?: string } | void>({
      queryFn: async (arg) => {
        try {
          const params = new URLSearchParams();
          const opts = (arg && typeof arg === 'object') ? arg : undefined;
          if (opts?.agentId) params.set('agent_id', opts.agentId);
          if (opts?.projectId) params.set('project_id', opts.projectId);
          if (opts?.limit) params.set('limit', String(opts.limit));
          if (opts?.cursor) params.set('cursor', opts.cursor);
          const qs = params.toString() ? `?${params.toString()}` : '';
          const data = await cookieJsonFetch(`/agent-instances${qs}`);
          return { data: { instances: data || [] } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, arg) => {
        const opts = (arg && typeof arg === 'object') ? arg : undefined;
        return [
          { type: 'AgentInstances' as const, id: 'LIST' },
          ...(opts?.agentId ? [{ type: 'AgentInstances' as const, id: opts.agentId }] : []),
          ...(opts?.projectId ? [{ type: 'AgentInstances' as const, id: `PROJECT:${opts.projectId}` }] : []),
        ];
      },
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    fetchAgentInstance: build.query<any, { instanceId: string }>({
      queryFn: async ({ instanceId }) => {
        if (!instanceId) return { data: { instance: null } };
        try {
          const data = await cookieJsonFetch(`/agent-instances/${encodeURIComponent(instanceId)}`);
          return { data: { instance: data || null } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { instanceId }) => [{ type: 'AgentInstances' as const, id: instanceId }],
      // Keep the instance runtime cached across conversation switches (was the 30s
      // global default). WS resource_changed(agent_instance) patches it live and
      // reconfigure invalidates it, so cached-on-switch stays correct.
      keepUnusedDataFor: 300,
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    launchAgentInstance: build.mutation<any, { agentId: string; bridgeId?: string; provider?: string; model?: string; projectId?: string }>({
      queryFn: async ({ agentId, bridgeId, provider, model, projectId }) => {
        try {
          // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
          const payload: any = { agent_id: agentId };
          if (bridgeId) payload.bridge_id = bridgeId;
          if (provider) payload.provider = provider;
          if (model) payload.model = model;
          if (projectId) payload.project_id = projectId;
          const data = await cookieMutation('/agent-instances', 'POST', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { agentId }) => [{ type: 'Agents' as const, id: 'LIST' }, { type: 'Agents' as const, id: agentId }, { type: 'AgentInstances' as const, id: agentId }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    stopAgentInstance: build.mutation<any, { agentId: string; instanceId: string; force?: boolean }>({
      queryFn: async ({ instanceId, force = false }) => {
        try {
          const data = await cookieMutation(`/agent-instances/${encodeURIComponent(instanceId)}/stop`, 'POST', { force, reason: force ? 'user_force_stop' : 'user_requested' });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { agentId, instanceId }) => [
        { type: 'Agents' as const, id: 'LIST' },
        { type: 'Agents' as const, id: agentId },
        { type: 'AgentInstances' as const, id: agentId },
        { type: 'AgentInstances' as const, id: instanceId },
      ],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    restartAgentInstance: build.mutation<any, { agentId?: string; instanceId: string }>({
      queryFn: async ({ instanceId }) => {
        try {
          const data = await cookieMutation(`/agent-instances/${encodeURIComponent(instanceId)}/restart`, 'POST', {});
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { agentId, instanceId }) => [
        { type: 'Agents' as const, id: 'LIST' },
        ...(agentId ? [{ type: 'Agents' as const, id: agentId }, { type: 'AgentInstances' as const, id: agentId }] : []),
        { type: 'AgentInstances' as const, id: instanceId },
      ],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    startAgentInstance: build.mutation<any, { agentId?: string; instanceId: string }>({
      queryFn: async ({ instanceId }) => {
        try {
          const data = await cookieMutation(`/agent-instances/${encodeURIComponent(instanceId)}/start`, 'POST', {});
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { agentId, instanceId }) => [
        { type: 'Agents' as const, id: 'LIST' },
        ...(agentId ? [{ type: 'Agents' as const, id: agentId }, { type: 'AgentInstances' as const, id: agentId }] : []),
        { type: 'AgentInstances' as const, id: instanceId },
      ],
    }),
    listInstanceReconfigurations: build.query<{ operations: InstanceReconfiguration[] }, { instanceId: string }>({
      queryFn: async ({ instanceId }) => {
        try {
          const data = await cookieJsonFetch(`/agent-instances/${encodeURIComponent(instanceId)}/reconfigurations`);
          return { data: { operations: (data?.operations || []).map(normalizeInstanceReconfiguration) } };
        } catch (error: any) { return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any }; }
      },
      providesTags: (_data, _error, { instanceId }) => [{ type: 'AgentInstances' as const, id: instanceId }],
      // When an operation settles, the instance runtime, the conversation header and its
      // messages all change server-side. Invalidate their tags here rather than having
      // views refetch: invalidation only touches started subscriptions, so it is safe
      // while a view's dependent queries are still skipped.
      async onQueryStarted(arg, { dispatch, getCacheEntry, queryFulfilled }) {
        const previous = getCacheEntry().data?.operations?.[0];
        let next: InstanceReconfiguration | undefined;
        try {
          next = (await queryFulfilled).data.operations[0];
        } catch {
          return;
        }
        if (!next || !reconfigurationSettled(previous, next)) return;
        dispatch(heimdallApi.util.invalidateTags([
          { type: 'AgentInstances' as const, id: arg.instanceId },
          ...(next.conversation_id
            ? [{ type: 'Chat' as const, id: next.conversation_id }, { type: 'ConversationSummaries' as const, id: next.conversation_id }]
            : []),
        ]));
      },
    }),
    retryInstanceConfiguration: build.mutation<InstanceReconfiguration, { instanceId: string; idempotency_key: string; expected_operation_revision: number }>({
      queryFn: async ({ instanceId, ...body }) => {
        try {
          const data = await cookieMutation(`/agent-instances/${encodeURIComponent(instanceId)}/reconfigurations/retry`, 'POST', body);
          return { data: normalizeInstanceReconfiguration(data) };
        } catch (error: any) { return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any }; }
      },
      invalidatesTags: (_data, _error, { instanceId }) => [{ type: 'AgentInstances' as const, id: instanceId }],
    }),
    applyInstanceConfiguration: build.mutation<InstanceReconfiguration, ApplyInstanceConfigurationInput>({
      queryFn: async ({ instanceId, ...body }) => {
        try {
          const data = await cookieMutation(`/agent-instances/${encodeURIComponent(instanceId)}/reconfigurations`, 'POST', body);
          return { data: normalizeInstanceReconfiguration(data) };
        } catch (error: any) { return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any }; }
      },
      invalidatesTags: (_data, _error, { instanceId }) => [{ type: 'AgentInstances' as const, id: instanceId }, { type: 'Agents' as const, id: 'LIST' }],
    }),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    reconfigureAgentInstance: build.mutation<any, { agentId: string; instanceId: string; provider?: string; model?: string; bridgeId?: string }>({
      queryFn: async ({ instanceId, provider, model, bridgeId }) => {
        try {
          // Legacy PATCH supports provider/model only. Location changes use the
          // explicit durable reconfiguration operation endpoint above.
          const body: Record<string, string> = { provider: provider || '', model: model || '' };
          if (bridgeId) body.bridge_id = bridgeId;
          const data = await cookieMutation(`/agent-instances/${encodeURIComponent(instanceId)}`, 'PATCH', body);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { agentId }) => [{ type: 'Agents' as const, id: 'LIST' }, { type: 'Agents' as const, id: agentId }, { type: 'AgentInstances' as const, id: agentId }],
    }),
    getAgentPane: build.query<AgentPaneResult, GetAgentPaneArgs>({
      queryFn: async ({ agentInstanceId, sinceHash, width = 80, lineLimit = 120 }) => {
        if (!agentInstanceId) {
          return { data: { ok: false, unchanged: true, hash: '', output: '' } };
        }
        try {
          const path = `/agent-instances/${encodeURIComponent(agentInstanceId)}/pane?since_hash=${encodeURIComponent(sinceHash || '')}&width=${width || 80}&line_limit=${lineLimit || 120}`;
          const data = await cookieJsonFetch(path);
          return { data: data || {} };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      serializeQueryArgs: ({ endpointName, queryArgs }) => {
        return `${endpointName}-${queryArgs.agentInstanceId}-${queryArgs.width || 80}-${queryArgs.lineLimit || 120}`;
      },
      merge: (currentCache, newItems) => {
        if (newItems?.unchanged && currentCache?.output !== undefined) {
          return {
            ...currentCache,
            ...newItems,
            output: currentCache.output,
            line_count: currentCache.line_count ?? newItems.line_count,
            truncated: currentCache.truncated ?? newItems.truncated,
          };
        }
        return newItems;
      },
      providesTags: (_result, _error, { agentInstanceId }) => [
        { type: 'AgentInstances' as const, id: `${agentInstanceId}:PANE` },
      ],
    }),
    sendAgentPaneInput: build.mutation<{ ok?: boolean; [key: string]: any }, { agentInstanceId: string; data: string }>({
      queryFn: async ({ agentInstanceId, data }) => {
        if (!agentInstanceId) {
          return { error: { status: 'CUSTOM_ERROR', error: 'Missing agentInstanceId' } as any };
        }
        try {
          const res = await cookieMutation(`/agent-instances/${encodeURIComponent(agentInstanceId)}/input`, 'POST', { data });
          return { data: res || { ok: true } };
        } catch (error: any) {
          // T10: a 423 vault_locked reaches the pane showing this agent.
          announcePaneVaultLocked(agentInstanceId, customQueryError(error));
          return { error: customQueryError(error) as any };
        }
      },
    }),
    sendAgentPaneResize: build.mutation<{ ok?: boolean; [key: string]: any }, { agentInstanceId: string; rows: number; cols: number }>({
      queryFn: async ({ agentInstanceId, rows, cols }) => {
        if (!agentInstanceId) {
          return { error: { status: 'CUSTOM_ERROR', error: 'Missing agentInstanceId' } as any };
        }
        try {
          const res = await cookieMutation(`/agent-instances/${encodeURIComponent(agentInstanceId)}/resize`, 'POST', { rows, cols });
          return { data: res || { ok: true } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
    }),
  }),
});

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
export function upsertAgentInCaches(dispatch: any, rawAgent: any) {
  const mapped = mapAgent(rawAgent);
  if (!mapped?.id) return '';
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  dispatch(agentsApi.util.updateQueryData('listAgents', undefined, (draft: any) => {
    const rows = draft?.agents || (draft.agents = []);
    upsertKnownAgentRecord(rows, mapped);
  }));
  dispatch(agentsApi.util.upsertQueryData('fetchAgent', { agentInstanceId: mapped.id }, { agent: mapped }));
  return mapped.id;
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
export function patchAgentCachesFromWs(dispatch: any, payload: any) {
  const type = String(payload?.type || '');
  if (type === 'agent_runtime_changed') {
    let agentId = '';
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    dispatch(agentsApi.util.updateQueryData('listAgents', undefined, (draft: any) => {
      const rows = draft?.agents || (draft.agents = []);
      agentId = applyAgentRuntimeEvent(rows, payload) || agentId;
    }));
    if (!agentId) return;
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    dispatch(agentsApi.util.updateQueryData('fetchAgent', { agentInstanceId: agentId }, (draft: any) => {
      if (!draft?.agent) return;
      const rows = [draft.agent];
      applyAgentRuntimeEvent(rows, payload);
      draft.agent = rows[0];
    }));
    return;
  }

  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const agentId = String(payload?.target_agent_instance_id || payload?.agent_instance_id || payload?.agent?.agent_instance_id || payload?.record?.agent_instance_id || '');
  if (!agentId) return;

  const reason = String(payload?.reason || '');
  if (reason === 'heartbeat') {
    const lastSeenUnixMs = Number(payload?.last_seen_unix_ms || 0);
    if (lastSeenUnixMs) {
      const formatted = new Date(lastSeenUnixMs).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      dispatch(agentsApi.util.updateQueryData('listAgents', undefined, (draft: any) => {
        const rows = draft?.agents || (draft.agents = []);
        // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
        const idx = rows.findIndex((r: any) => r.id === agentId);
        if (idx >= 0) {
          rows[idx].lastSeenUnixMs = lastSeenUnixMs;
          rows[idx].lastSeen = formatted;
        }
      }));
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      dispatch(agentsApi.util.updateQueryData('fetchAgent', { agentInstanceId: agentId }, (draft: any) => {
        if (draft?.agent) {
          draft.agent.lastSeenUnixMs = lastSeenUnixMs;
          draft.agent.lastSeen = formatted;
        }
      }));
    }
    return;
  }

  // Status/runtime changes (the common, high-frequency case — now that the bridge
  // pushes an immediate agent_instance_status on every transition) are patched IN
  // PLACE rather than invalidating the Agents LIST tag. A blind LIST invalidation
  // forced a full /agents refetch on every mounted useListAgentsQuery subscriber
  // on each status blip, which is the periodic /agents traffic we want to avoid:
  // agent IDENTITIES rarely change, and genuine identity mutations
  // (create/archive/rename/reconfigure) already invalidate the LIST via their own
  // mutation invalidatesTags. So here we only patch the live runtime fields.
  const summary = payload?.summary || {};
  const runtimePatch = {
    agent_instance_id: agentId,
    runtime_status: payload?.runtime_status ?? summary?.runtime_status,
    startup_status: payload?.startup_status ?? summary?.startup_status,
    activity_status: payload?.activity_status ?? summary?.activity_status,
    exec_state: payload?.exec_state,
  };
  let known = false;
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  dispatch(agentsApi.util.updateQueryData('listAgents', undefined, (draft: any) => {
    const rows = draft?.agents || (draft.agents = []);
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    known = rows.some((r: any) => r.id === agentId);
    if (known) applyAgentRuntimeEvent(rows, runtimePatch);
  }));
  // Also patch the per-instance runtime cache (fetchAgentInstance) used by the
  // conversation page's runtime chip / model switcher / current-task strip, so a
  // WS status change updates it live without a refetch-on-switch.
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  dispatch(agentsApi.util.updateQueryData('fetchAgentInstance', { instanceId: agentId }, (draft: any) => {
    if (!draft?.instance) return;
    if (runtimePatch.runtime_status != null) draft.instance.runtime_status = runtimePatch.runtime_status;
    if (runtimePatch.startup_status != null) draft.instance.startup_status = runtimePatch.startup_status;
    if (runtimePatch.activity_status != null) draft.instance.activity_status = runtimePatch.activity_status;
  }));
  if (known) {
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    dispatch(agentsApi.util.updateQueryData('fetchAgent', { agentInstanceId: agentId }, (draft: any) => {
      if (!draft?.agent) return;
      const rows = [draft.agent];
      applyAgentRuntimeEvent(rows, runtimePatch);
      draft.agent = rows[0];
    }));
    return;
  }
  // An agent id we don't have cached yet (e.g. an instance launched elsewhere):
  // invalidate the LIST ONCE so it appears. This is the rare case; steady-state
  // status blips for already-known agents are patched in place above and do NOT
  // trigger a refetch.
  dispatch(heimdallApi.util.invalidateTags([{ type: 'Agents', id: 'LIST' }]));
}

export const { useRetryInstanceConfigurationMutation, useListInstanceReconfigurationsQuery, useApplyInstanceConfigurationMutation, useListAgentIdentitiesQuery, useListAgentTemplatesQuery, useCreateAgentTemplateMutation, useUpdateAgentTemplateMutation, useDeleteAgentTemplateMutation, useFetchAgentIdentityQuery, useUpdateAgentIdentityMutation, useEnableBridgeSupportMutation, useListAgentsQuery, useFetchAgentsPageQuery, useLazyFetchAgentsPageQuery, useFetchAgentQuery, useStartAgentMutation, useStopAgentMutation, useCreateAgentInstanceInChainMutation, useCreateAgentMutation, useArchiveAgentIdentityMutation, useListAgentInstancesQuery, useFetchAgentInstanceQuery, useLaunchAgentInstanceMutation, useStopAgentInstanceMutation, useRestartAgentInstanceMutation, useStartAgentInstanceMutation, useReconfigureAgentInstanceMutation, useGetAgentPaneQuery, useLazyGetAgentPaneQuery, useSendAgentPaneInputMutation, useSendAgentPaneResizeMutation } = agentsApi;

export function useStartInstanceMutation() {
  const [mutate, result] = useStartAgentInstanceMutation();
  const trigger = (arg: string | { instanceId: string; agentId?: string }) => {
    return mutate(typeof arg === 'string' ? { instanceId: arg } : arg);
  };
  return [trigger, result] as const;
}

/* ------------------------------------------------------------------ *
 * Rebuilt Agents pages — data layer
 * ------------------------------------------------------------------ *
 * `useListAgentIdentitiesQuery` loads EVERY agent unpaginated and is what the
 * sidebar and launch modal want. The list page needs keyset pages, abortable
 * fetches, and the `page` envelope, so it uses the imperative helpers below.
 */

/** An agent identity as the rebuilt pages use it: camelCase, every field present. */
export type AgentRecord = {
  agentId: string;
  name: string;
  slug: string;
  templateId: string;
  instructions: string;
  /** `active` | `archived` */
  state: string;
  supportedBridgeCount: number;
  activeInstanceCount: number;
  updatedAt: string;
};

/**
 * Normalises a wire agent identity.
 *
 * Note what is NOT here: `created_at` and `owner_user_id`. `write_agent_json`
 * (`agent_handlers.odin:338-351`) serialises neither — even though the list's
 * cursor IS `created_at` — so the pages have exactly one timestamp to show.
 */
export function normalizeAgent(raw: any): AgentRecord {
  const src = raw?.agent || raw || {};
  return {
    agentId: String(src.agent_id || src.agentId || ''),
    name: String(src.name || ''),
    slug: String(src.slug || ''),
    templateId: String(src.template_id || src.templateId || ''),
    instructions: String(src.instructions || ''),
    state: String(src.state || 'active'),
    supportedBridgeCount: Number(src.supported_bridge_count ?? src.supportedBridgeCount ?? 0),
    activeInstanceCount: Number(src.active_instance_count ?? src.activeInstanceCount ?? 0),
    updatedAt: String(src.updated_at || src.updatedAt || ''),
  };
}

export type AgentPage = {
  items: AgentRecord[];
  next_cursor: string;
  has_more: boolean;
};

/**
 * One keyset page of agent identities.
 *
 * The endpoint takes `limit` and `cursor` and NOTHING else
 * (`agent_handlers.odin:17-36`) — no `state`, no type filter. Tab filtering
 * is applied in the browser, exactly as on Projects.
 */
export async function fetchAgentPage(
  args: { limit?: number; cursor?: string; signal?: AbortSignal } = {},
): Promise<AgentPage> {
  const params = new URLSearchParams({ limit: String(args.limit || 50) });
  if (args.cursor) params.set('cursor', args.cursor);
  const body = await cookieJsonFetchEnvelope(`/agents?${params.toString()}`, { signal: args.signal });
  const data = body?.data ?? body;
  const rawItems = Array.isArray(data) ? data : data?.items || data?.agents || [];
  const page = body?.page ?? {};
  return {
    items: rawItems.map(normalizeAgent),
    next_cursor: String(page?.next_cursor || ''),
    has_more: Boolean(page?.has_more),
  };
}

/**
 * A search hit: label plus a sublabel derived from the server's response.
 * No state on a hit, so search results are navigation-only.
 */
export type AgentHit = {
  id: string;
  label: string;
  slug: string;
  preview: string;
};

export type AgentHitPage = {
  items: AgentHit[];
  next_cursor: string;
  has_more: boolean;
};

function agentHitFrom(raw: any): AgentHit {
  return {
    id: String(raw?.id || ''),
    label: String(raw?.label || ''),
    slug: String(raw?.sublabel || raw?.sub || '').split('·')[0]?.trim() || '',
    preview: String(raw?.preview || raw?.snippet || ''),
  };
}

/**
 * Server-scoped agent search (`types=agent`, G-2).
 *
 * Matches name, slug, agent_id — NOT instructions.
 */
export async function searchAgentPage(
  args: { q: string; limit?: number; cursor?: string; signal?: AbortSignal },
): Promise<AgentHitPage> {
  const query = String(args.q || '').trim();
  if (!query) return { items: [], next_cursor: '', has_more: false };
  const params = new URLSearchParams({ q: query, types: 'agent', limit: String(args.limit || 50) });
  if (args.cursor) params.set('cursor', args.cursor);
  const body = await cookieJsonFetchEnvelope(`/search?${params.toString()}`, { signal: args.signal });
  const data = body?.data ?? body;
  const page = body?.page ?? {};
  const groups = Array.isArray(data?.groups) ? data.groups : [];
  const hits = groups
    .filter((group: any) => String(group?.type || '') === 'agent')
    .flatMap((group: any) => (Array.isArray(group?.hits) ? group.hits : []));
  return {
    items: hits.map(agentHitFrom).filter((hit: AgentHit) => Boolean(hit.id)),
    next_cursor: String(page?.next_cursor || ''),
    has_more: Boolean(page?.has_more),
  };
}

/** Human-readable text for anything an agent mutation rejects with. */
export function agentErrorText(err: unknown, fallback = 'Something went wrong'): string {
  return apiErrorText(err, fallback);
}

export type InstanceConfiguration = {
  bridge_id: string; bridge_label: string; project_id: string; project_label: string;
  project_path: string; provider: string; model: string;
};
export type InstanceReconfiguration = {
  operation_id: string; agent_instance_id: string; conversation_id: string; idempotency_key: string;
  phase: 'prepared' | 'stopping' | 'source_stopped' | 'launching' | 'ready' | 'failed' | 'recovery_required';
  source: InstanceConfiguration; destination: InstanceConfiguration;
  source_stopped: boolean; destination_committed: boolean;
  failure_code: string; failure_message: string; revision: number; updated_at?: string;
};
export type ApplyInstanceConfigurationInput = {
  instanceId: string; bridge_id: string; project_id: string; provider: string; model: string;
  idempotency_key: string; expected_revision: number;
};
/** Whether an operation reached a phase that changes the instance and conversation. */
export function isSettledReconfiguration(operation: InstanceReconfiguration): boolean {
  return operation.phase === 'ready' || (operation.phase === 'failed' && operation.failure_code === 'recovery_stopped');
}

/**
 * True only when `next` settled since `previous` was observed. The first observation
 * (no `previous`) is history, not a transition: an instance reconfigured last week
 * reports a `ready` operation on every fetch.
 */
export function reconfigurationSettled(
  previous: InstanceReconfiguration | undefined,
  next: InstanceReconfiguration,
): boolean {
  if (!previous || !isSettledReconfiguration(next)) return false;
  return previous.operation_id !== next.operation_id || !isSettledReconfiguration(previous);
}
function normalizeInstanceReconfiguration(raw: any): InstanceReconfiguration {
  const phases = ['prepared', 'stopping', 'source_stopped', 'launching', 'ready', 'failed', 'recovery_required'];
  const phase = typeof raw?.phase === 'number' ? phases[raw.phase] : String(raw?.phase || '').toLowerCase();
  return { ...raw, phase: phases.includes(phase) ? phase : 'recovery_required' };
}
