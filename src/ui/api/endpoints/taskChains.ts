import { announceTaskChainCreated } from '../taskChainCreationEvents';
import { heimdallApi } from '../heimdallApi';
import { cookieJsonFetch, cookieMutation } from '../cookieFetch';
import { encryptVaultText, isVaultArmored, getActiveVaultKey } from '../../utils/vaultContent';
import { decryptChainRecord, decryptChainList } from '../../utils/vaultChains';

export interface FleetRestartFailure {
  instance_id: string;
  message: string;
}

export type CreateTaskChainInput = {
  title: string;
  description?: string;
  kind?: string;
  coordinatorAgentId?: string;
  bridgeId?: string;
  provider?: string;
  model?: string;
  projectId?: string;
};

export type UpdateTaskChainInput = {
  chainId: string;
  title?: string;
  description?: string;
  status?: string;
  coordinatorAgentInstanceId?: string;
};

export interface TaskChainFleet {
  bridge_models?: Record<string, { provider: string; provider_profile?: string; model: string }>;
  task_chain_id?: string;
  taskChainId?: string;
  agent_id: string;
  agentId?: string;
  capacity: number;
  active_count?: number;
  activeCount?: number;
  min_warm?: number;
  minWarm?: number;
  idle_ttl_seconds?: number;
  idleTtlSeconds?: number;
  provider_profile?: string;
  provider?: string;
  model?: string;
  roles?: string[];
  /** REQ-TV2-5: roles that get no new lease (`task-chain fleet pause`); live work continues. */
  paused_roles?: string[];
  paused?: boolean;
  /** Advisory text from a fleet PUT (e.g. only unrequested custom roles). */
  warning?: string;
  /** What the matcher would apply for this row (hub-resolved, plan REQ-UI-12). */
  effective?: EffectivePlacement | null;
  bridge_id?: string;
  bridgeId?: string;
  // PUT-only additive fields, present when the request carried a well-formed
  // restart_live_instances boolean; absent on fleet list rows.
  restarted_instance_ids?: string[];
  restart_failures?: FleetRestartFailure[];
  created_at?: string;
  updated_at?: string;
}

/** A chain review role (hybrid review model). */
export interface ChainReviewRole {
  name: string;
  /** What the role checks; handed to the reviewing agent. */
  description: string;
  /** Agent template ids whose fleet row holds the role. */
  holders: string[];
  /** Open tasks whose brief requires the role (delete is refused while > 0). */
  openTaskCount: number;
}

export interface EffectivePlacement {
  bridge_id: string;
  /** task_pin | fleet | chain_directory | coordinator | none */
  bridge_source: string;
  provider: string;
  model: string;
  /** fleet | bridge_override | catalog_default | none */
  model_source: string;
}

export function normalizeFleet(f: any): TaskChainFleet {
  const rawRoles: string[] = Array.isArray(f?.roles)
    // `worker` or any review role name (`reviewer`, `security`, …) — same rule as
    // the hub's fleet_role_name_valid; custom review roles must survive the read.
    ? f.roles.map((r: any) => String(r || '').trim().toLowerCase()).filter((r: string) => /^[a-z][a-z0-9_-]{0,31}$/.test(r))
    : [];
  const roles: string[] = rawRoles.length > 0 ? Array.from(new Set(rawRoles)) : ['worker', 'reviewer'];
  const bridgeId = String(f?.bridge_id ?? f?.bridgeId ?? '');

  return {
    bridge_models: f?.bridge_models || f?.bridgeModels || {},
    task_chain_id: f?.task_chain_id || f?.taskChainId || '',
    taskChainId: f?.taskChainId || f?.task_chain_id || '',
    agent_id: f?.agent_id || f?.agentId || '',
    agentId: f?.agentId || f?.agent_id || '',
    capacity: typeof f?.capacity === 'number' ? f.capacity : 1,
    active_count: typeof f?.active_count === 'number' ? f.active_count : (typeof f?.activeCount === 'number' ? f.activeCount : 0),
    activeCount: typeof f?.activeCount === 'number' ? f.activeCount : (typeof f?.active_count === 'number' ? f.active_count : 0),
    min_warm: typeof f?.min_warm === 'number' ? f.min_warm : (typeof f?.minWarm === 'number' ? f.minWarm : 0),
    minWarm: typeof f?.minWarm === 'number' ? f.minWarm : (typeof f?.min_warm === 'number' ? f.min_warm : 0),
    idle_ttl_seconds: typeof f?.idle_ttl_seconds === 'number' ? f.idle_ttl_seconds : (typeof f?.idleTtlSeconds === 'number' ? f.idleTtlSeconds : 600),
    idleTtlSeconds: typeof f?.idleTtlSeconds === 'number' ? f.idleTtlSeconds : (typeof f?.idle_ttl_seconds === 'number' ? f.idle_ttl_seconds : 600),
    provider: f?.provider || '',
    provider_profile: f?.provider_profile || f?.provider || '',
    model: f?.model || '',
    roles,
    bridge_id: bridgeId,
    bridgeId,
    paused_roles: Array.isArray(f?.paused_roles) ? f.paused_roles.map((r: any) => String(r)) : [],
    paused: f?.paused === true,
    warning: typeof f?.warning === 'string' && f.warning ? f.warning : undefined,
    effective: f?.effective && typeof f.effective === 'object' ? (f.effective as EffectivePlacement) : null,
    restarted_instance_ids: Array.isArray(f?.restarted_instance_ids)
      ? f.restarted_instance_ids.map((id: any) => String(id))
      : undefined,
    restart_failures: Array.isArray(f?.restart_failures)
      ? f.restart_failures.map((entry: any) => ({
          instance_id: String(entry?.instance_id || ''),
          message: String(entry?.message || ''),
        }))
      : undefined,
    created_at: f?.created_at || '',
    updated_at: f?.updated_at || '',
  };
}

export const taskChainsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    getTaskChainFleets: build.query<TaskChainFleet[], { chainId: string }>({
      queryFn: async ({ chainId }) => {
        try {
          const raw = await cookieJsonFetch(`/task-chains/${encodeURIComponent(chainId)}/fleets`);
          const rawList = Array.isArray(raw) ? raw : (Array.isArray(raw?.data) ? raw.data : []);
          const list = rawList.map(normalizeFleet);
          return { data: list };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { chainId }) => [{ type: 'TaskChainFleets' as const, id: chainId }],
    }),

    // Hybrid review model: chain review roles (optional, for templates and
    // coordinators). Members are the fleet rows holding the role, so these share
    // the fleets tag and refresh together.
    listChainReviewRoles: build.query<ChainReviewRole[], { chainId: string }>({
      queryFn: async ({ chainId }) => {
        try {
          const raw = await cookieJsonFetch(`/task-chains/${encodeURIComponent(chainId)}/review-roles`);
          const list = Array.isArray(raw) ? raw : Array.isArray(raw?.data) ? raw.data : [];
          return {
            data: list.map((r: any) => ({
              name: String(r?.name || ''),
              description: String(r?.description || ''),
              holders: Array.isArray(r?.holders) ? r.holders.map(String) : [],
              openTaskCount: Number(r?.open_task_count || 0),
            })),
          };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { chainId }) => [{ type: 'TaskChainFleets' as const, id: chainId }],
    }),

    upsertChainReviewRole: build.mutation<any, { chainId: string; name: string; description: string }>({
      queryFn: async ({ chainId, name, description }) => {
        try {
          const data = await cookieMutation(
            `/task-chains/${encodeURIComponent(chainId)}/review-roles/${encodeURIComponent(name)}`,
            'PUT',
            { description },
          );
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [{ type: 'TaskChainFleets' as const, id: chainId }],
    }),

    deleteChainReviewRole: build.mutation<any, { chainId: string; name: string }>({
      queryFn: async ({ chainId, name }) => {
        try {
          const data = await cookieMutation(
            `/task-chains/${encodeURIComponent(chainId)}/review-roles/${encodeURIComponent(name)}`,
            'DELETE',
          );
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [{ type: 'TaskChainFleets' as const, id: chainId }],
    }),

    updateTaskChainFleet: build.mutation<TaskChainFleet, {
      chainId: string;
      agentId: string;
      capacity: number;
      minWarm?: number;
      min_warm?: number;
      idleTtlSeconds?: number;
      idle_ttl_seconds?: number;
      provider_profile?: string;
      provider?: string;
      model?: string;
      roles?: string[];
      bridgeId?: string;
      bridge_id?: string;
      /** Ask the hub to relaunch this role's live instances with the new provider/model. */
      restartLiveInstances?: boolean;
      bridgeModels?: Record<string, { provider: string; provider_profile?: string; model: string }>;
      bridge_models?: Record<string, { provider: string; provider_profile?: string; model: string }>;
    }>({
      queryFn: async ({
        chainId,
        agentId,
        capacity,
        minWarm,
        min_warm,
        idleTtlSeconds,
        idle_ttl_seconds,
        provider,
        provider_profile,
        model,
        roles,
        bridgeId,
        bridge_id,
        restartLiveInstances,
        bridgeModels,
        bridge_models,
      }) => {
        try {
          const body: any = { capacity, provider: provider ?? '', model: model ?? '' };
          if (provider_profile !== undefined) body.provider_profile = provider_profile;
          const resolvedBridgeModels = bridgeModels ?? bridge_models;
          if (resolvedBridgeModels !== undefined) body.bridge_models = resolvedBridgeModels;
          const resolvedMinWarm = minWarm ?? min_warm;
          if (resolvedMinWarm !== undefined) body.min_warm = resolvedMinWarm;
          const resolvedIdleTtl = idleTtlSeconds ?? idle_ttl_seconds;
          if (resolvedIdleTtl !== undefined) body.idle_ttl_seconds = resolvedIdleTtl;
          if (roles !== undefined) body.roles = roles;
          const resolvedBridgeId = bridgeId !== undefined ? bridgeId : bridge_id;
          if (resolvedBridgeId !== undefined) body.bridge_id = resolvedBridgeId;
          // Only a true flag reaches the wire: flag-less bodies stay byte-identical
          // to the pre-restart request shape.
          if (restartLiveInstances === true) body.restart_live_instances = true;
          const raw = await cookieMutation(
            `/task-chains/${encodeURIComponent(chainId)}/fleets/${encodeURIComponent(agentId)}`,
            'PUT',
            body
          );
          const data = normalizeFleet(raw?.data !== undefined ? raw.data : raw);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [
        { type: 'TaskChainFleets' as const, id: chainId },
        { type: 'Chain' as const, id: chainId },
      ],
    }),

    deleteTaskChainFleet: build.mutation<{ deleted: boolean; removed?: boolean }, { chainId: string; agentId: string }>({
      queryFn: async ({ chainId, agentId }) => {
        try {
          const raw = await cookieMutation(
            `/task-chains/${encodeURIComponent(chainId)}/fleets/${encodeURIComponent(agentId)}`,
            'DELETE'
          );
          const data = raw?.data !== undefined ? raw.data : raw;
          return { data: { deleted: Boolean(data?.deleted ?? true), removed: Boolean(data?.removed ?? true) } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [
        { type: 'TaskChainFleets' as const, id: chainId },
        { type: 'Chain' as const, id: chainId },
      ],
    }),

    getTaskChain: build.query<any, { chainId: string } | string>({
      queryFn: async (arg, api) => {
        const chainId = typeof arg === 'string' ? arg : arg?.chainId;
        if (!chainId) return { data: null };
        try {
          const raw = await cookieJsonFetch(`/task-chains/${encodeURIComponent(chainId)}`);
          let data = raw?.data ?? raw;
          const state: any = api?.getState?.();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          if (isUnlocked && activeKey && data) {
            data = await decryptChainRecord(data, activeKey);
          }
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, arg) => {
        const chainId = typeof arg === 'string' ? arg : arg?.chainId;
        return [{ type: 'Chain' as const, id: chainId }];
      },
    }),

    getTaskChains: build.query<any, { projectId?: string; hasTasks?: boolean; includeArchived?: boolean; pinned?: boolean } | void>({
      queryFn: async (arg, api) => {
        try {
          const options = typeof arg === 'object' && arg !== null ? arg : undefined;
          const params = new URLSearchParams();
          if (options?.projectId) params.set('project_id', options.projectId);
          if (options?.hasTasks) params.set('has_tasks', '1');
          if (options?.includeArchived) params.set('include_archived', '1');
          if (options?.pinned) params.set('pinned', '1');
          const qs = params.toString();
          const raw = await cookieJsonFetch(`/task-chains${qs ? `?${qs}` : ''}`);
          let data = raw?.data ?? raw;
          const state: any = api?.getState?.();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          if (isUnlocked && activeKey && Array.isArray(data)) {
            data = await decryptChainList(data, activeKey);
          }
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [{ type: 'Chain' as const, id: 'LIST' }],
    }),

    createTaskChain: build.mutation<any, CreateTaskChainInput>({
      queryFn: async (payload, api) => {
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();

          let title = payload.title;
          let description = payload.description || '';

          if (isUnlocked && activeKey) {
            if (!isVaultArmored(title)) {
              title = await encryptVaultText(title, activeKey);
            }
            if (description && !isVaultArmored(description)) {
              description = await encryptVaultText(description, activeKey);
            }
          }

          const body: any = {
            title,
            description,
            kind: payload.kind || 'team_work',
          };
          if (payload.coordinatorAgentId) body.coordinator_agent_id = payload.coordinatorAgentId;
          if (payload.bridgeId) body.bridge_id = payload.bridgeId;
          if (payload.provider) body.provider = payload.provider;
          if (payload.model) body.model = payload.model;
          if (payload.projectId) body.project_id = payload.projectId;

          const data = await cookieMutation('/task-chains', 'POST', body);
          announceTaskChainCreated(String(data?.chain_id || data?.chainId || ''));
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: ['ChainList', { type: 'Chain' as const }],
    }),

    updateTaskChain: build.mutation<any, UpdateTaskChainInput>({
      queryFn: async ({ chainId, title, description, status, coordinatorAgentInstanceId }, api) => {
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();

          const body: any = {};
          if (title !== undefined) {
            body.title =
              isUnlocked && activeKey && !isVaultArmored(title)
                ? await encryptVaultText(title, activeKey)
                : title;
          }
          if (description !== undefined) {
            body.description =
              isUnlocked && activeKey && description && !isVaultArmored(description)
                ? await encryptVaultText(description, activeKey)
                : description;
          }
          if (status !== undefined) body.status = status;
          if (coordinatorAgentInstanceId !== undefined) {
            body.coordinator_agent_instance_id = coordinatorAgentInstanceId;
          }

          const data = await cookieMutation(`/task-chains/${encodeURIComponent(chainId)}`, 'PATCH', body);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { chainId }) => [
        { type: 'Chain', id: chainId },
        'ChainList',
        { type: 'Chain' as const, id: 'GROUPED_LIST' },
        { type: 'Chain' as const, id: 'PINNED_LIST' },
      ],
    }),

    listFlatTaskChains: build.query<any, { includeArchived?: boolean } | void>({
      queryFn: async (arg) => {
        try {
          const options = typeof arg === 'object' && arg !== null ? arg : undefined;
          const params = new URLSearchParams();
          params.set('flat', '1');
          if (options?.includeArchived) params.set('include_archived', '1');
          const qs = params.toString();
          const raw = await cookieJsonFetch(`/task-chains?${qs}`);
          const data = raw?.data ?? raw;
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [{ type: 'ChainList' as const, id: 'FLAT' }, { type: 'Chain' as const, id: 'LIST' }],
    }),
  }),
});

export const {
  useListChainReviewRolesQuery,
  useUpsertChainReviewRoleMutation,
  useDeleteChainReviewRoleMutation,
  useGetTaskChainFleetsQuery,
  useLazyGetTaskChainFleetsQuery,
  useUpdateTaskChainFleetMutation,
  useDeleteTaskChainFleetMutation,
  useListFlatTaskChainsQuery,
} = taskChainsApi;
