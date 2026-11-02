import { refreshBridgeProviderCatalog } from '../../components/providers/providerSetupApi';
import { normalizeModelCatalog } from '../../components/providers/modelCatalogStatus';
import * as daemonApi from '../daemonApi';
import { heimdallApi, withSessionQuery } from '../heimdallApi';
import { profileLabel } from '../../components/providers/providerProfiles';
import { useMemo } from 'react';
import { cookieJsonFetch, cookieMutation, customQueryError } from '../cookieFetch';
import { type ExtensionCommandKind, type ProviderExtensionCommand, isExtensionInstallTerminal } from '../../components/extension/extensionInstallModel';

export type AgentBridgeSupportEntry = {
  bridgeId: string;
  enabled: boolean;
  providerProfile?: string;
  model?: string;
  priority?: number;
  maxInstances?: number;
};

export interface Bridge {
  bridge_id?: string;
  bridgeId?: string;
  id?: string;
  label?: string;
  machine_hostname?: string;
  hostname?: string;
  machine_os?: string;
  os?: string;
  machine_arch?: string;
  arch?: string;
  status?: string;
  runtime_status?: string;
  runtime_connected?: boolean;
  version?: string;
  commit_sha?: string;
  build_timestamp?: string;
  target?: string;
  update_available?: boolean;
  /** REQ-T13-2: false when the latest release ships no bundle for `target` (e.g. termux-arm64). */
  update_artifact_available?: boolean;
  latest_version?: string;
  latest_source?: 'promoted' | 'override' | 'manifest';
  update_warning?: string;
  update_fallback_reason?: string;
  latest_commit_sha?: string;
  update_status?: 'idle' | 'downloading' | 'validating' | 'restarting' | 'healthy' | 'complete' | 'failed' | string;
  update_message?: string;
  update_progress?: number;
  update_error?: string;
  active_instance_count?: number;
  instance_count?: number;
  instances?: any[];
  capabilities?: any[] | BridgeCapability[];
  provider_capabilities?: any[];
  provider_profiles?: any[];
  last_seen_at?: string;
  updated_at?: string;
  revoked_at?: string;
  /** Hub-owned plan suspension; existing agents are retained. */
  plan_disabled_at?: string;
  telemetry_enabled?: 'inherit' | 'enabled' | 'disabled' | string;
  public_key?: string;
  bridge_public_key?: string;
  /**
   * REQ-BVS-2/REQ-BVS-3: the vault state this bridge last reported, serialized
   * verbatim by the hub — `"disabled" | "locked" | "unlocked"`, or `""` when the
   * bridge has never reported one (older builds). Never infer "unlocked" from an
   * absent value; see `utils/bridgeVaultStatus.ts` for the derivation.
   */
  vault_status?: string;
}

/** One row of GET /api/v1/bridges/{id}/events. `fields` values are enum names or ints. */
export interface BridgeEvent {
  id: number;
  ts_ms: number;
  received_at: number;
  level: 'warn' | 'error' | string;
  code: string;
  fields: Record<string, string | number>;
  count: number;
  message: string;
}

export interface BridgeEventsPage {
  bridge_id: string;
  events: BridgeEvent[];
  has_more: boolean;
  next_before_id: number;
}

export function normalizeBridgeEventsPage(raw: any): BridgeEventsPage {
  const events = Array.isArray(raw?.events) ? raw.events : [];
  return {
    bridge_id: String(raw?.bridge_id || ''),
    events: events.map((e: any) => ({
      id: Number(e?.id || 0),
      ts_ms: Number(e?.ts_ms || 0),
      received_at: Number(e?.received_at || 0),
      level: String(e?.level || 'warn'),
      code: String(e?.code || 'other'),
      fields: e?.fields && typeof e.fields === 'object' ? e.fields : {},
      count: Math.max(1, Number(e?.count || 1)),
      message: String(e?.message || e?.code || ''),
    })),
    has_more: Boolean(raw?.has_more),
    next_before_id: Number(raw?.next_before_id || 0),
  };
}

export type BridgeCapability = {
  provider: string;
  profile_id?: string; label?: string; accent?: string;
  models: string[];
};

export function normalizeBridgeCapabilities(raw: any): BridgeCapability[] {
  const caps = raw?.capabilities || raw?.capability_report || raw?.provider_capabilities || raw || [];
  const source = Array.isArray(caps)
    ? caps
    : Array.isArray(caps?.providers)
      ? caps.providers
      : Array.isArray(caps?.provider_profiles)
        ? caps.provider_profiles
        : [];
  return source.map((entry: any) => {
    if (typeof entry === 'string') return { provider: entry, models: [] };
    const models = Array.isArray(entry?.models) ? entry.models.map((model: any) => String(model)).filter(Boolean) : [];
    return { provider: String(entry?.provider || entry?.name || ''), models, ...(entry?.profile_id ? { profile_id: String(entry.profile_id), label: String(entry.label || entry.profile_id), accent: String(entry.accent || '') } : {}) };
  }).filter((entry: BridgeCapability) => Boolean(entry.provider));
}

function normalizeBridgeSupportEntry(raw: any): AgentBridgeSupportEntry {
  return {
    bridgeId: String(raw?.bridge_id || raw?.bridgeId || ''),
    enabled: Boolean(raw?.enabled ?? raw?.is_enabled ?? false),
    providerProfile: raw?.provider || raw?.provider_profile || raw?.providerProfile || undefined,
    model: raw?.model || raw?.model || raw?.model || undefined,
    priority: raw?.priority !== undefined ? Number(raw.priority) : undefined,
    maxInstances: raw?.max_instances !== undefined ? Number(raw.max_instances) : raw?.maxInstances !== undefined ? Number(raw.maxInstances) : undefined,
  };
}

function normalizeBridgeSupport(data: any): { agentId: string; entries: AgentBridgeSupportEntry[] } {
  const rawEntries = data?.entries || data?.bridge_support || data?.supports || (Array.isArray(data) ? data : []);
  const list = Array.isArray(rawEntries) ? rawEntries : [];
  return {
    agentId: String(data?.agent_id || data?.agentId || ''),
    entries: list.map(normalizeBridgeSupportEntry).filter((entry: AgentBridgeSupportEntry) => Boolean(entry.bridgeId)),
  };
}

export const bridgeSupportApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listAgentBridgeSupport: build.query<any, { agentId: string }>({
      queryFn: async ({ agentId }) => {
        if (!agentId) return { data: { agentId, entries: [] } };
        try {
          const data = await cookieJsonFetch(`/agents/${encodeURIComponent(agentId)}/bridge-support`);
          return { data: normalizeBridgeSupport(data) };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { agentId }) => [{ type: 'BridgeSupport' as const, id: agentId }],
    }),
    patchAgentBridgeSupport: build.mutation<any, { agentId: string; bridgeId: string; enabled?: boolean; providerProfile?: string; model?: string; priority?: number; maxInstances?: number }>({
      queryFn: async (arg) => {
        if (!arg.agentId || !arg.bridgeId) return { data: { ok: false, message: 'Missing agentId/bridgeId' } };
        try {
          let current: AgentBridgeSupportEntry | undefined;
          const preservesFields = arg.providerProfile === undefined || arg.model === undefined || arg.priority === undefined || arg.maxInstances === undefined;
          if (preservesFields) {
            const rows = normalizeBridgeSupport(await cookieJsonFetch(`/agents/${encodeURIComponent(arg.agentId)}/bridge-support`)).entries;
            current = rows.find((row) => row.bridgeId === arg.bridgeId);
          }
          const payload = {
            bridge_id: arg.bridgeId,
            enabled: arg.enabled ?? current?.enabled ?? true,
            priority: arg.priority !== undefined ? arg.priority : (current?.priority || 0),
            max_instances: arg.maxInstances !== undefined ? arg.maxInstances : (current?.maxInstances || 0),
          };
          const data = await cookieMutation(`/agents/${encodeURIComponent(arg.agentId)}/bridge-support/${encodeURIComponent(arg.bridgeId)}`, 'PATCH', payload);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { agentId }) => [{ type: 'BridgeSupport' as const, id: agentId }, { type: 'Agents' as const, id: 'LIST' }],
    }),
    // Plain GET /bridges: one request, no per-bridge fan-out. Provider availability is
    // NOT here: capability consumers read it per bridge, lazily, through
    // useBridgeProviderStatus (listBridgeProviders). The hub's own row `capabilities`
    // are dropped because they are not filtered to enabled/present/active providers,
    // so a consumer reading them would offer providers the bridge cannot run.
    listBridges: build.query<any, void | {}>({
      queryFn: async () => {
        try {
          const data = await cookieJsonFetch('/bridges');
          const rows = data?.bridges || data || [];
          const bridges = (Array.isArray(rows) ? rows : []).map((bridge: any) => {
            const { capabilities: _unfiltered, ...rest } = bridge || {};
            return rest;
          });
          return { data: { bridges } };
        } catch (error: any) {
          return { error: customQueryError(error) as any };
        }
      },
      providesTags: [{ type: 'Bridges' as const, id: 'LIST' }],
      // Bridges change rarely; keep cached across conversation switches (was the
      // 30s global default). Bridge mutations invalidate the LIST tag.
      keepUnusedDataFor: 600,
    }),
    fetchBridgeDetail: build.query<any, { bridgeId: string; expand?: string }>({
      queryFn: withSessionQuery(async ({ bridgeId, expand }, { session }) => {
        if (!session?.daemonUrl || !session?.clientToken || !bridgeId) return { bridge: null };
        const data = await daemonApi.fetchBridgeDetail({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, bridgeId, expand });
        return { bridge: data?.bridge || data, instances: data?.instances || [], project_paths: data?.project_paths || [] };
      }),
      providesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: bridgeId }],
    }),
    renameBridge: build.mutation<any, { bridgeId: string; label?: string; telemetry_enabled?: string }>({
      queryFn: async ({ bridgeId, label, telemetry_enabled }) => {
        try {
          const body: Record<string, any> = {};
          if (label !== undefined) body.label = label;
          if (telemetry_enabled !== undefined) body.telemetry_enabled = telemetry_enabled;
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}`, 'PATCH', body);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: 'LIST' }, { type: 'Bridges' as const, id: bridgeId }],
    }),
    updateBridgeTelemetry: build.mutation<any, { bridgeId: string; telemetry_enabled: 'inherit' | 'enabled' | 'disabled' | string }>({
      queryFn: async ({ bridgeId, telemetry_enabled }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}`, 'PATCH', { telemetry_enabled });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: 'LIST' }, { type: 'Bridges' as const, id: bridgeId }],
    }),
    // Bridge error events (bridge_logs plan v2 §4.4): the hub's per-bridge ring of
    // structured warn/error events, with `message` rendered server-side. Owner
    // scoped; a purge invalidates the same cache key.
    listBridgeEvents: build.query<BridgeEventsPage, { bridgeId: string; limit?: number; beforeId?: number }>({
      queryFn: async ({ bridgeId, limit, beforeId }) => {
        try {
          const params = new URLSearchParams();
          params.set('limit', String(limit ?? 50));
          if (beforeId) params.set('before_id', String(beforeId));
          const data = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/events?${params.toString()}`);
          return { data: normalizeBridgeEventsPage(data) };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: `events:${bridgeId}` }],
    }),
    purgeBridgeEvents: build.mutation<any, { bridgeId: string }>({
      queryFn: async ({ bridgeId }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/events`, 'DELETE');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: `events:${bridgeId}` }],
    }),
    revokeBridge: build.mutation<any, { bridgeId: string }>({
      queryFn: async ({ bridgeId }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/revoke`, 'POST');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: 'LIST' }, { type: 'Bridges' as const, id: bridgeId }],
    }),
    // REQ-ENR-10: ask a live bridge to uninstall itself (ham-bridge uninstall,
    // which revokes it and wipes its secrets). An offline bridge answers 422:
    // revoke it instead.
    uninstallBridge: build.mutation<any, { bridgeId: string; purge?: boolean }>({
      queryFn: async ({ bridgeId, purge }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/uninstall`, 'POST', { purge: purge !== false });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: 'LIST' }, { type: 'Bridges' as const, id: bridgeId }],
    }),
    updateBridge: build.mutation<any, { bridgeId: string; targetVersion?: string; force?: boolean; drainTimeoutSeconds?: number; updateExtensions?: boolean }>({
      queryFn: async ({ bridgeId, targetVersion, force, drainTimeoutSeconds, updateExtensions }) => {
        try {
          const body: Record<string, any> = {};
          if (targetVersion !== undefined) body.target_version = targetVersion;
          if (force !== undefined) body.force = force;
          if (updateExtensions !== undefined) body.update_extensions = updateExtensions;
          if (drainTimeoutSeconds !== undefined) body.drain_timeout_seconds = drainTimeoutSeconds;
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/update`, 'POST', body);
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'Bridges' as const, id: 'LIST' }, { type: 'Bridges' as const, id: bridgeId }],
    }),
    installProviderExtension: build.mutation<ProviderExtensionCommand, { bridgeId: string; provider: string; profileId?: string }>({
      queryFn: async ({ bridgeId, provider, profileId }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/providers/${encodeURIComponent(provider)}/extension-install`, 'POST', profileId ? { profile_id: profileId } : {});
          return { data };
        } catch (error: any) {
          return { error: customQueryError(error) as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'BridgeProviders' as const, id: bridgeId }],
    }),
    uninstallProviderExtension: build.mutation<ProviderExtensionCommand, { bridgeId: string; provider: string; profileId?: string }>({
      queryFn: async ({ bridgeId, provider, profileId }) => {
        try {
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/providers/${encodeURIComponent(provider)}/extension-uninstall`, 'POST', profileId ? { profile_id: profileId } : {});
          return { data };
        } catch (error: any) {
          return { error: customQueryError(error) as any };
        }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'BridgeProviders' as const, id: bridgeId }],
    }),
    getProviderExtensionInstall: build.query<ProviderExtensionCommand, { bridgeId: string; provider: string; commandId: string; profileId?: string; kind?: ExtensionCommandKind }>({
      queryFn: async ({ bridgeId, provider, commandId, kind, profileId }) => {
        try {
          const verb = kind === 'uninstall' ? 'extension-uninstall' : 'extension-install';
          const data = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/providers/${encodeURIComponent(provider)}/${verb}/${encodeURIComponent(commandId)}${profileId ? "?profile_id=" + encodeURIComponent(profileId) : ""}`);
          return { data };
        } catch (error: any) {
          return { error: customQueryError(error) as any };
        }
      },
      async onQueryStarted({ bridgeId }, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          if (isExtensionInstallTerminal(data.status)) {
            dispatch(heimdallApi.util.invalidateTags([{ type: 'BridgeProviders', id: bridgeId }]));
          }
        } catch { /* Request errors are shown by the caller; retain the tracked command. */ }
      },
      keepUnusedDataFor: 0,
    }),
    // The three bridge-enrollment endpoints are DELETED (REQ-ENROLL-9):
    // POST/GET /bridge-enrollments and DELETE /bridge-enrollments/<id>. They minted,
    // listed and revoked the one-time enrollment token, and all three now 404.
    // Enrollment is browser-approved and the bridge drives it, so the UI mints
    // nothing and has no enrollment rows to list or revoke.
    refreshBridgeModels: build.mutation<any, { bridgeId: string }>({
      queryFn: async ({ bridgeId }) => {
        try { return { data: await refreshBridgeProviderCatalog(bridgeId) }; }
        catch (error: any) { return { error: customQueryError(error) as any }; }
      },
      invalidatesTags: (_result, _error, { bridgeId }) => [{ type: 'BridgeProviders' as const, id: bridgeId }],
    }),
    listBridgeProviders: build.query<any, { bridgeId: string }>({
      queryFn: async ({ bridgeId }) => {
        if (!bridgeId) return { data: { bridge_id: '', providers: [] } };
        try {
          const data = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/provider-status`);
          const providers = await Promise.all((Array.isArray(data?.providers) ? data.providers : [])
            .filter((entry: any) => entry?.enabled && entry?.state === 'present' && entry?.catalog_state === 'active')
            .map(async (entry: any) => ({
              ...(entry?.profile_id ? { profile_id: String(entry.profile_id), label: await profileLabel(entry, entry.profile_id === entry.provider ? entry.display_name : ''), accent: String(entry.accent || '') } : {}),
              provider: String(entry?.provider || ''),
              enabled: true,
              models: (Array.isArray(entry?.models) ? entry.models : [])
                .filter((model: any) => model?.state === 'active')
                .map((model: any) => String(model?.model_id || ''))
                .filter(Boolean),
              // REQ-EXT-DET-1: the catalog's extension descriptor + measured state
              // (null when the provider ships no extension).
              extension: entry?.extension ?? null,
              ...normalizeModelCatalog(entry),
            })));
          return { data: { bridge_id: data?.bridge_id || bridgeId, providers,
            extension_commands: Array.isArray(data?.extension_commands) ? data.extension_commands : [] } };
        } catch (error: any) {
          return { error: customQueryError(error) as any };
        }
      },
      providesTags: (_result, _error, { bridgeId }) => [{ type: 'BridgeProviders' as const, id: bridgeId }],
      // Shared by every pane/picker on the same bridge; survive brief unmounts.
      keepUnusedDataFor: 300,
    }),
    putProjectBridgePath: build.mutation<any, { projectId: string; bridgeId: string; path: string }>({
      queryFn: withSessionQuery(async ({ projectId, bridgeId, path }, { session }) => daemonApi.putProjectBridgePath({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, projectId, bridgeId, path })),
      invalidatesTags: (_result, _error, { projectId }) => [{ type: 'ProjectBridgePaths' as const, id: projectId }],
    }),
    deleteProjectBridgePath: build.mutation<any, { projectId: string; bridgeId: string }>({
      queryFn: withSessionQuery(async ({ projectId, bridgeId }, { session }) => daemonApi.deleteProjectBridgePath({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, projectId, bridgeId })),
      invalidatesTags: (_result, _error, { projectId }) => [{ type: 'ProjectBridgePaths' as const, id: projectId }],
    }),
    validateProjectBridgePath: build.mutation<any, { projectId: string; bridgeId: string }>({
      queryFn: withSessionQuery(async ({ projectId, bridgeId }, { session }) => daemonApi.validateProjectBridgePath({ daemonUrl: session.daemonUrl, clientToken: session.clientToken, projectId, bridgeId })),
    }),
  }),
});

export const {
  useListAgentBridgeSupportQuery,
  useListBridgesQuery,
  useRenameBridgeMutation,
  useUpdateBridgeTelemetryMutation,
  useRevokeBridgeMutation,
  useListBridgeEventsQuery,
  usePurgeBridgeEventsMutation,
  useUpdateBridgeMutation,
  useUninstallBridgeMutation,
  useInstallProviderExtensionMutation,
  useUninstallProviderExtensionMutation,
  useGetProviderExtensionInstallQuery,
  useListBridgeProvidersQuery,
  useRefreshBridgeModelsMutation,
} = bridgeSupportApi;

/** How long a visible, open runtime/provider picker may show provider status. */
export const PROVIDER_STATUS_LIVE_POLL_MS = 30000;

export type BridgeProviderStatus = {
  /** The bridge row with `capabilities` and `provider_status_error` filled in. */
  bridge: any;
  capabilities: BridgeCapability[];
  /** Provider status answered (or failed, or cannot exist for this bridge). */
  loaded: boolean;
};

/**
 * Provider availability for ONE bridge, keyed by its id (GET
 * /bridges/{id}/provider-status). `skip` keeps it lazy: callers pass it until the
 * capability is needed (a selected bridge, an open runtime picker). `live` adds a
 * bounded poll while a picker is open and the window is focused; nothing pushes
 * provider changes yet.
 */
export function useBridgeProviderStatus(bridge: any, opts: { skip?: boolean; live?: boolean } = {}): BridgeProviderStatus {
  const bridgeId = String(bridge?.bridge_id || bridge?.id || '');
  const revoked = String(bridge?.status || '').toLowerCase() === 'revoked';
  const query = useListBridgeProvidersQuery({ bridgeId }, {
    skip: Boolean(opts.skip) || !bridgeId || revoked,
    pollingInterval: opts.live ? PROVIDER_STATUS_LIVE_POLL_MS : 0,
    skipPollingIfUnfocused: true,
  });
  const { currentData: data, isError } = query;
  return useMemo(() => {
    if (!bridge) return { bridge, capabilities: [], loaded: false };
    const capabilities = data ? normalizeBridgeCapabilities(data) : [];
    return {
      bridge: { ...bridge, capabilities, provider_status_error: Boolean(isError) },
      capabilities,
      loaded: Boolean(data) || Boolean(isError) || revoked,
    };
  }, [bridge, data, isError, revoked]);
}
