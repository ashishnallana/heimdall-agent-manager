import { normalizeModelCatalog, type ModelCatalogMetadata } from './modelCatalogStatus';
import { cookieJsonFetch, cookieMutation } from '../../api/cookieFetch';
import { normalizeProviderExtension, type ProviderExtensionStatus } from '../extension/extensionBadgeModel';

export type DiscoveryState = 'idle' | 'running' | 'complete' | 'failed';
export type DetectionState = 'absent' | 'present';
export type ProviderTestRunState = 'starting' | 'detecting' | 'awaiting_validation' | 'stopping' | 'stopped' | 'failed' | 'cancelled' | 'expired';

export interface ProviderModelStatus { model_id: string; label: string; state: 'active' | 'deprecated'; resolved_model?: string }
export interface BridgeProviderStatus extends ModelCatalogMetadata {
  profile_id?: string; label_enc?: string; accent?: string; profile_state?: string;
  provider: 'claude' | 'codex' | 'copilot' | 'antigravity' | 'pi';
  display_name: string; icon_url: string; catalog_state: 'active' | 'deprecated';
  state: DetectionState; binary_path: string; version_text: string; checked_at: string | null;
  enabled: boolean; models: ProviderModelStatus[];
  /** REQ-EXT-DET-1/2: the bridge's probe of the provider's Heimdall extension; null = provider has none. */
  extension: ProviderExtensionStatus | null;
}
export interface ProviderSetupResponse {
  bridge: { bridge_id: string; label: string; machine_hostname: string; status: 'online' | 'offline' };
  discovery: { state: DiscoveryState; requested_at: string | null; completed_at: string | null };
  providers: BridgeProviderStatus[];
}
export interface ProviderTestRunResponse {
  run_id: string; agent_instance_id: string; bridge_id: string; provider: string; model: string;
  state: ProviderTestRunState; expires_at: string; error: string | null;
}

function normalizeStatus(raw: any): BridgeProviderStatus {
  return {
    provider: String(raw?.provider || '') as BridgeProviderStatus['provider'],
    profile_id: String(raw?.profile_id || raw?.provider || ''), label_enc: String(raw?.label_enc || ''), accent: String(raw?.accent || ''), profile_state: String(raw?.profile_state || ''),
    display_name: String(raw?.display_name || raw?.provider || ''), icon_url: String(raw?.icon_url || ''),
    catalog_state: raw?.catalog_state === 'deprecated' ? 'deprecated' : 'active',
    state: raw?.state === 'present' ? 'present' : 'absent', binary_path: String(raw?.binary_path || ''),
    version_text: String(raw?.version_text || ''), checked_at: raw?.checked_at ? String(raw.checked_at) : null,
    enabled: Boolean(raw?.enabled),
    ...normalizeModelCatalog(raw),
    extension: normalizeProviderExtension(raw?.extension),
    models: Array.isArray(raw?.models) ? raw.models.map((model: any) => ({
      model_id: String(model?.model_id || ''), label: String(model?.label || model?.model_id || ''),
      state: model?.state === 'deprecated' ? 'deprecated' : 'active',
      resolved_model: model?.resolved_model ? String(model.resolved_model) : undefined,
    })) : [],
  };
}

async function bridgeDetails(bridgeId: string) {
  const raw = await cookieJsonFetch('/bridges');
  const bridges = raw?.bridges || (Array.isArray(raw) ? raw : []);
  return bridges.find((bridge: any) => String(bridge?.bridge_id || bridge?.id || '') === bridgeId) || {};
}

export const providerSetupApi = {
  async get(bridgeId: string, includeProfiles = false): Promise<ProviderSetupResponse> {
    if (!bridgeId) throw new Error('Bridge id is required.');
    const [status, bridge] = await Promise.all([
      cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/provider-status`), bridgeDetails(bridgeId),
    ]);
    return {
      bridge: { bridge_id: bridgeId, label: String(bridge?.label || bridge?.machine_hostname || bridgeId),
        machine_hostname: String(bridge?.machine_hostname || ''),
        status: String(bridge?.status || '').toLowerCase() === 'online' ? 'online' : 'offline' },
      discovery: { state: 'idle', requested_at: null, completed_at: null },
      providers: (Array.isArray(status?.providers) ? status.providers : []).filter((p: any) => includeProfiles || !p.profile_id || p.profile_id === p.provider).map(normalizeStatus),
    };
  },
  async discover(current: ProviderSetupResponse): Promise<ProviderSetupResponse> {
    const requestedAt = new Date().toISOString();
    const status = await cookieMutation(`/bridges/${encodeURIComponent(current.bridge.bridge_id)}/providers/discover`, 'POST', { stage: 'providers' });
    return { ...current, discovery: { state: 'complete', requested_at: requestedAt, completed_at: new Date().toISOString() },
      providers: (Array.isArray(status?.providers) ? status.providers : []).filter((p: any) => !p.profile_id || p.profile_id === p.provider).map(normalizeStatus) };
  },
  /** Explicit second stage. Hub derives the present + enabled provider filter. */
  async refreshModels(current: ProviderSetupResponse): Promise<ProviderSetupResponse> {
    const status = await cookieMutation(`/bridges/${encodeURIComponent(current.bridge.bridge_id)}/providers/discover`, 'POST', { stage: 'models' });
    return { ...current, providers: (Array.isArray(status?.providers) ? status.providers : []).filter((p: any) => !p.profile_id || p.profile_id === p.provider).map(normalizeStatus) };
  },
  async setEnabled(current: ProviderSetupResponse, provider: string, enabled: boolean, profileId?: string): Promise<ProviderSetupResponse> {
    await cookieMutation(`/bridges/${encodeURIComponent(current.bridge.bridge_id)}/providers/${encodeURIComponent(provider)}`, 'PUT', { enabled, ...(profileId ? { profile_id: profileId } : {}) });
    return { ...current, providers: current.providers.map((entry) => entry.provider === provider ? { ...entry, enabled } : entry) };
  },
  async startTestRun(current: ProviderSetupResponse, provider: string, model: string, profileId?: string): Promise<ProviderTestRunResponse> {
    return cookieMutation(`/bridges/${encodeURIComponent(current.bridge.bridge_id)}/provider-tests`, 'POST', { provider, model, ...(profileId ? { profile_id: profileId } : {}) });
  },
  async getTestRun(runId: string): Promise<ProviderTestRunResponse> {
    return cookieJsonFetch(`/provider-tests/${encodeURIComponent(runId)}`);
  },
  async validateTestRun(runId: string): Promise<ProviderTestRunResponse> {
    return cookieMutation(`/provider-tests/${encodeURIComponent(runId)}/validate`, 'POST', {});
  },
  async cancelTestRun(runId: string): Promise<void> {
    await cookieMutation(`/provider-tests/${encodeURIComponent(runId)}`, 'DELETE');
  },
};

/** Only user Refresh actions call this; neither stage is retried automatically. */
export async function refreshBridgeProviderCatalog(bridgeId: string): Promise<any> {
  const path = `/bridges/${encodeURIComponent(bridgeId)}/providers/discover`;
  await cookieMutation(path, 'POST', { stage: 'providers' });
  return cookieMutation(path, 'POST', { stage: 'models' });
}
