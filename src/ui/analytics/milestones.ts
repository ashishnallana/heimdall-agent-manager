// REQ-PH-5: funnel milestones read from the Redux/RTK Query layer — the Hub's
// answers — rather than from button clicks, so an event means the thing happened.
// Each milestone goes through analytics.trackOnce (once per user). See docs/analytics.md.
import { analytics, type Analytics } from './analytics';

// Endpoints whose success means the Hub accepted an agent launch/start.
const AGENT_START_ENDPOINTS = new Set([
  'createLaunchConversation',
  'launchAgentInstance',
  'startAgentInstance',
  'startAgent',
  'createAgentInstanceInChain',
]);

/** Same rule as the Bridges panel (components/settings/BridgesPanel.tsx). */
export function bridgeIsOnline(bridge: any): boolean {
  const status = String(bridge?.status || bridge?.runtime_status || '').toLowerCase();
  return bridge?.runtime_connected === true || status === 'online' || status === 'connected';
}

/** The cached `listBridges` rows, including in-place patches from the user WebSocket. */
function cachedBridges(state: any): any[] | null {
  const queries = state?.heimdallApi?.queries;
  if (!queries) return null;
  for (const entry of Object.values<any>(queries)) {
    if (entry?.endpointName === 'listBridges' && Array.isArray(entry?.data?.bridges)) return entry.data.bridges;
  }
  return null;
}

function typeSlug(value: unknown): string | undefined {
  const name = String(value ?? '').trim().toLowerCase();
  // Provider types and chain kinds are short slugs (claude, codex, team_work…);
  // anything else is not sent.
  return /^[a-z0-9][a-z0-9_.-]{0,31}$/.test(name) ? name : undefined;
}

/** Inspect one dispatched action (and the state after it) for a milestone. */
export function observeMilestones(target: Analytics, action: any, state: any): void {
  if (!target.enabled || !target.currentUserId) return;
  const type = String(action?.type || '');
  if (!type.startsWith('heimdallApi/')) return;

  // bridge_connected: any enrolled bridge online. Read from the cache so both a fetch
  // and a WebSocket status patch count.
  const bridges = target.hasSentOnce('bridge_connected') ? null : cachedBridges(state);
  if (bridges) {
    const online = bridges.filter(bridgeIsOnline).length;
    if (online > 0) target.trackOnce('bridge_connected', { bridge_count: bridges.length, online_count: online });
  }

  if (!type.endsWith('/fulfilled')) return;
  const endpoint = String(action?.meta?.arg?.endpointName || '');
  const arg = action?.meta?.arg?.originalArgs || {};

  if (endpoint === 'listBridgeProviders') {
    // listBridgeProviders keeps only enabled + present + active providers.
    const providers = Array.isArray(action?.payload?.providers) ? action.payload.providers : [];
    if (providers.length > 0) {
      target.trackOnce('provider_configured', {
        provider: typeSlug(providers[0]?.provider) ?? 'other',
        provider_count: providers.length,
      });
    }
  } else if (endpoint === 'createTaskChain') {
    target.trackOnce('first_chain_created', { chain_kind: typeSlug(arg?.kind) });
  } else if (AGENT_START_ENDPOINTS.has(endpoint)) {
    target.trackOnce('first_agent_started', { via: endpoint, provider: typeSlug(arg?.provider) });
  }
}

/** Redux middleware wiring observeMilestones to the app store. */
export const analyticsMiddleware = (store: any) => (next: any) => (action: any) => {
  const result = next(action);
  if (analytics.enabled) {
    try { observeMilestones(analytics, action, store.getState()); } catch { /* never break dispatch */ }
  }
  return result;
};
