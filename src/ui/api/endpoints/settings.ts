import * as daemonApi from '../daemonApi';
export type ExperimentFlag = { key: string; enabled: boolean };
import { heimdallApi, withSessionQuery } from '../heimdallApi';
import { apiUrl, cookieJsonFetch, cookieMutation } from '../cookieFetch';

function auth(session: any) {
  return { daemonUrl: session.daemonUrl, clientToken: session.clientToken };
}

export const TELEMETRY_DEFAULT_ENABLED_PREFERENCE_KEY = 'telemetry.default_enabled';

export const settingsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    fetchPreferences: build.query<any, { scope?: string } | void>({
      queryFn: withSessionQuery(async (_arg, { session }) => {
        let prefs: any[] = [];
        if (session?.clientToken) {
          try {
            const data = await daemonApi.fetchPreferences(auth(session));
            prefs = data?.preferences || [];
          } catch {}
        }
        if (typeof window !== 'undefined') {
          const stored = window.localStorage.getItem(`heimdall:preference:${TELEMETRY_DEFAULT_ENABLED_PREFERENCE_KEY}`);
          if (stored !== null && !prefs.some((p: any) => (p?.key || p?.id) === TELEMETRY_DEFAULT_ENABLED_PREFERENCE_KEY)) {
            prefs.push({ key: TELEMETRY_DEFAULT_ENABLED_PREFERENCE_KEY, value: stored });
          }
        }
        return { preferences: prefs };
      }),
      providesTags: (result) => [
        { type: 'Preferences' as const, id: 'ALL' },
        ...((result?.preferences || []).map((pref: any) => ({ type: 'Preferences' as const, id: String(pref.key || '') })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    savePreference: build.mutation<any, { key: string; value: string; interrupt?: boolean }>({
      queryFn: withSessionQuery(async ({ key, value, interrupt = false }, { session }) => {
        if (typeof window !== 'undefined') {
          window.localStorage.setItem(`heimdall:preference:${key}`, value);
        }
        if (session?.clientToken) {
          try {
            const data = await daemonApi.savePreference({ ...auth(session), key, value, interrupt });
            return { preference: data?.preference || data };
          } catch {}
        }
        return { preference: { key, value } };
      }),
      invalidatesTags: (_result, _error, { key }) => [
        { type: 'Preferences' as const, id: 'ALL' },
        { type: 'Preferences' as const, id: key },
      ],
    }),
    fetchTelemetryDefaultEnabled: build.query<{ enabled: boolean }, void>({
      queryFn: async (_arg, api) => {
        try {
          const state = api.getState() as any;
          const session = state?.chat?.session;
          if (session?.clientToken && session?.daemonUrl) {
            try {
              const data = await daemonApi.fetchPreferences(auth(session));
              const match = (data?.preferences || []).find((p: any) => (p?.key || p?.id) === TELEMETRY_DEFAULT_ENABLED_PREFERENCE_KEY);
              if (match) {
                return { data: { enabled: String(match.value).toLowerCase() === 'true' || match.value === true } };
              }
            } catch {}
          }
          if (typeof window !== 'undefined') {
            const stored = window.localStorage.getItem(`heimdall:preference:${TELEMETRY_DEFAULT_ENABLED_PREFERENCE_KEY}`);
            if (stored !== null) {
              return { data: { enabled: stored === 'true' } };
            }
          }
          return { data: { enabled: true } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [{ type: 'Preferences' as const, id: TELEMETRY_DEFAULT_ENABLED_PREFERENCE_KEY }],
    }),
    saveTelemetryDefaultEnabled: build.mutation<{ enabled: boolean }, { enabled: boolean }>({
      queryFn: async ({ enabled }, api) => {
        try {
          const strVal = enabled ? 'true' : 'false';
          const state = api.getState() as any;
          const session = state?.chat?.session;
          if (session?.clientToken && session?.daemonUrl) {
            try {
              await daemonApi.savePreference({ ...auth(session), key: TELEMETRY_DEFAULT_ENABLED_PREFERENCE_KEY, value: strVal, interrupt: false });
            } catch {}
          }
          if (typeof window !== 'undefined') {
            window.localStorage.setItem(`heimdall:preference:${TELEMETRY_DEFAULT_ENABLED_PREFERENCE_KEY}`, strVal);
          }
          return { data: { enabled } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [
        { type: 'Preferences' as const, id: 'ALL' },
        { type: 'Preferences' as const, id: TELEMETRY_DEFAULT_ENABLED_PREFERENCE_KEY },
      ],
    }),
    fetchAgentDefaults: build.query<any, { scope?: string } | void>({
      queryFn: withSessionQuery(async (_arg, { session }) => {
        if (!session?.clientToken || !session?.daemonUrl) return { defaults: [] };
        const data = await daemonApi.fetchAgentDefaults(auth(session));
        const defaults = data?.defaults || data?.records || [];
        return { defaults };
      }),
      providesTags: [{ type: 'Preferences' as const, id: 'AGENT_DEFAULTS' }],
    }),
    saveAgentDefault: build.mutation<any, { use: string; agentId: string }>({
      queryFn: withSessionQuery(async ({ use, agentId }, { session }) => {
        return daemonApi.setAgentDefault({ ...auth(session), use, agentId });
      }),
      invalidatesTags: [{ type: 'Preferences' as const, id: 'AGENT_DEFAULTS' }, { type: 'Agents' as const, id: 'LIST' }],
    }),
    fetchAgentTemplate: build.query<any, { templateId: string }>({
      queryFn: withSessionQuery(async ({ templateId }, { session }) => {
        if (!session?.daemonUrl || !templateId) return { template: null };
        const data = await daemonApi.showAgentTemplate({ daemonUrl: session.daemonUrl, templateId });
        return { template: data?.template || null };
      }),
      providesTags: (_result, _error, { templateId }) => [{ type: 'AgentTemplate' as const, id: templateId }],
    }),
    fetchSettingsCatalog: build.query<any, { scope?: string } | void>({
      queryFn: withSessionQuery(async (_arg, { session }) => {
        if (!session?.daemonUrl) return { templates: [], providers: [] };
        const [templates, providers] = await Promise.all([
          daemonApi.listAgentTemplates({ daemonUrl: session.daemonUrl }).catch(() => []),
          daemonApi.listAgentProviders({ daemonUrl: session.daemonUrl }).catch(() => []),
        ]);
        return { templates, providers };
      }),
      providesTags: [{ type: 'AgentTemplate' as const, id: 'LIST' }, { type: 'Preferences' as const, id: 'CATALOG' }],
    }),
    fetchExperiments: build.query<{ flags: ExperimentFlag[] }, void>({
      queryFn: async () => {
        try {
          const data = await cookieJsonFetch('/me/experiments');
          if (!Array.isArray(data?.experiments)) {
            return { error: { status: 'CUSTOM_ERROR', error: `Unexpected experiments response shape (got ${JSON.stringify(data)?.slice(0, 100)})` } as any };
          }
          const raw: Array<{ key: string; enabled: boolean }> = data.experiments;
          return { data: { flags: raw.map((f: any) => ({ key: String(f.key || ''), enabled: Boolean(f.enabled) })) } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [{ type: 'Experiments' as const, id: 'ALL' }],
    }),
    setExperiment: build.mutation<any, { key: string; enabled: boolean }>({
      queryFn: async ({ key, enabled }) => {
        try {
          const data = await cookieMutation(`/me/experiments/${encodeURIComponent(key)}`, 'PUT', { enabled });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: [{ type: 'Experiments' as const, id: 'ALL' }],
    }),
  }),
});

export type LspServerConfig = {
  config_id: string;
  bridge_id: string;
  language: string;
  cmd: string;
  args: string;
  file_extensions: string;
  root_markers: string;
  dir_prefix: string;
  dir_pattern?: string;
  dirPattern?: string;
  created_at: string;
  updated_at: string;
};

export const lspApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listLspServerConfigs: build.query<{ configs: LspServerConfig[] }, { bridgeId: string }>({
      queryFn: async ({ bridgeId }) => {
        try {
          const data = await cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/lsp-servers`);
          return { data: { configs: Array.isArray(data?.configs) ? data.configs : [] } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: (_result, _error, { bridgeId }) => [{ type: 'LspServerConfigs' as const, id: bridgeId }],
    }),
    upsertLspServerConfig: build.mutation<{ config: LspServerConfig }, {
      bridgeId: string;
      language: string;
      cmd: string;
      args?: string;
      fileExtensions?: string;
      rootMarkers?: string;
      dirPrefix?: string;
      dirPattern?: string;
      dir_pattern?: string;
    }>({
      queryFn: async ({ bridgeId, language, cmd, args = '', fileExtensions = '', rootMarkers = '', dirPrefix = '', dirPattern = '', dir_pattern = '' }) => {
        try {
          const normalizedPrefix = dirPrefix.replace(/\/+$/, '');
          const pattern = (dirPattern || dir_pattern || '').trim();
          const data = await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/lsp-servers`, 'POST', {
            language,
            cmd,
            args,
            file_extensions: fileExtensions,
            root_markers: rootMarkers,
            dir_prefix: normalizedPrefix,
            dir_pattern: pattern,
          });
          return { data: { config: data?.config } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_r, _e, { bridgeId }) => [{ type: 'LspServerConfigs' as const, id: bridgeId }],
    }),
    // REQ-LSP-UI-2: "which server config serves THIS file?"
    //
    // WHY THIS EXISTS. The Monaco LSP session is deliberately NOT keyed on the
    // file path — switching between two files of one language must reuse the
    // running server rather than restart it. But the Hub picks WHICH server to
    // run by longest-matching dir_prefix of the file path
    // (src/hub/domain/lsp_server_config.odin:31), so two same-language files
    // under DIFFERENT dir_prefix overrides need DIFFERENT servers. Without this
    // query the client cannot tell those two cases apart and silently serves the
    // second file from the first file's server — wrong toolchain, wrong project
    // root, plausible-looking but wrong answers. Observed, not theorised: see
    // REQ-LSP-E2E-1.
    //
    // WHY WE ASK THE HUB INSTEAD OF COMPUTING IT HERE. The resolution rule has a
    // path-boundary subtlety ("/work/exp" matches "/work/exp/main.go" but NOT
    // "/work/experiment/main.go") and reimplementing it in TypeScript would mean
    // two implementations of one rule, drifting. This endpoint runs the SAME
    // domain.lsp_server_config_resolve the websocket path runs
    // (lsp_server_config_rest_handlers.odin:152 and lsp_session_handlers.odin:734
    // both list-by-bridge, filter by language, then call it), so there is one
    // implementation exposed two ways.
    //
    // 404 IS A NORMAL ANSWER, NOT AN ERROR. "No server configured for this
    // language and path" is the common case for most languages, so it maps to
    // `{ config: null }` and the caller treats that as "no session". Any OTHER
    // failure stays an error: a 500 or a dropped connection must not be
    // indistinguishable from a deliberate absence of config.
    resolveLspServerConfig: build.query<{ config: LspServerConfig | null }, {
      bridgeId: string;
      language: string;
      path: string;
    }>({
      queryFn: async ({ bridgeId, language, path }) => {
        try {
          const url = apiUrl(
            `/bridges/${encodeURIComponent(bridgeId)}/lsp-servers/resolve` +
            `?language=${encodeURIComponent(language)}&path=${encodeURIComponent(path)}`
          );
          const res = await fetch(url, { credentials: 'include' });
          if (res.status === 404) return { data: { config: null } };
          if (!res.ok) {
            let msg = `Request failed (${res.status})`;
            try {
              const errBody = JSON.parse(await res.text());
              if (errBody?.error?.message) msg = errBody.error.message;
              else if (errBody?.message) msg = errBody.message;
            } catch {}
            throw new Error(msg);
          }
          const body = JSON.parse(await res.text());
          const envelope = body?.data !== undefined ? body.data : body;
          return { data: { config: (envelope?.config as LspServerConfig | undefined) ?? null } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      // Same tag the upsert and delete mutations already invalidate, so an
      // operator editing a server in Settings > LSP re-resolves every open file
      // for free — and because an upsert issues a fresh config_id, editing the
      // server for a directory correctly restarts the session serving it.
      providesTags: (_result, _error, { bridgeId }) => [{ type: 'LspServerConfigs' as const, id: bridgeId }],
    }),
    deleteLspServerConfig: build.mutation<void, { bridgeId: string; configId: string }>({
      queryFn: async ({ bridgeId, configId }) => {
        try {
          await cookieMutation(`/bridges/${encodeURIComponent(bridgeId)}/lsp-servers/${encodeURIComponent(configId)}`, 'DELETE');
          return { data: undefined };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_r, _e, { bridgeId }) => [{ type: 'LspServerConfigs' as const, id: bridgeId }],
    }),
  }),
});

export const {
  useListLspServerConfigsQuery,
  useResolveLspServerConfigQuery,
  useUpsertLspServerConfigMutation,
  useDeleteLspServerConfigMutation,
} = lspApi;

export const {
  useFetchExperimentsQuery,
  useSetExperimentMutation,
  useFetchTelemetryDefaultEnabledQuery,
  useSaveTelemetryDefaultEnabledMutation,
} = settingsApi;
