// Pure helpers for deriving the launch option lists (bridge -> provider -> model)
// from a bridge's normalized capabilities. Extracted from AgentDetailPanel so the
// same logic backs both the agent-detail launch UI and the "Add agent to chain"
// popup, and so it can be unit-tested without React (see
// tests/ui_bridge_launch_options_test.ts).
//
// These functions are intentionally free of any RTK/query/DOM dependency: feed
// them plain bridge objects (as returned by useListBridgesQuery) and they return
// the option arrays the selects render.

import { normalizeBridgeCapabilities, type BridgeCapability } from '../api/endpoints/bridgeSupport';

export type LaunchBridgeRow = { bridgeId: string; bridge: any };

export function bridgeIdOf(bridge: any): string {
  return String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
}

export function bridgeIsOnline(bridge: any): boolean {
  return !bridge?.plan_disabled_at && String(bridge?.status || '').toLowerCase() === 'online';
}

export function bridgeLabel(bridge: any): string {
  return String(bridge?.label || bridge?.machine_hostname || bridgeIdOf(bridge) || '');
}

export function defaultCapability(bridge: any, provider?: string): BridgeCapability | undefined {
	const caps = normalizeBridgeCapabilities(bridge);
	if (provider) return caps.find((cap) => cap.provider === provider);
	return undefined;
}

export function capSupports(bridge: any, provider: string, model: string): boolean {
  if (!provider || !model) return false;
  const cap = defaultCapability(bridge, provider);
  if (!cap) return false;
	return (cap.models || []).includes(model);
}

// Providers a bridge advertises (sorted, de-duped).
export function launchProvidersFor(bridge: any): string[] {
  return normalizeBridgeCapabilities(bridge)
    .map((cap) => cap.provider)
    .filter(Boolean)
    .sort();
}

// Models valid for the given bridge + (optional) requested provider. Falls back to
// the agent/bridge default provider when none is requested. Canonical models first,
// then any extra advertised models, filtered to those the bridge actually supports.
export function launchModelsFor(bridge: any, requestedProvider: string): string[] {
	const provider = requestedProvider;
	const cap = defaultCapability(bridge, provider);
	return [...(cap?.models || [])].filter((model, index, all) => all.indexOf(model) === index).sort();
}

// Online bridges that advertise at least one provider — the only bridges a launch
// can target. Returns { bridgeId, bridge } rows for the select.
export function launchableBridgeRows(bridges: any[]): LaunchBridgeRow[] {
  return (bridges || [])
    .filter((bridge) => bridgeIsOnline(bridge) && launchProvidersFor(bridge).length > 0)
    .map((bridge) => ({ bridgeId: bridgeIdOf(bridge), bridge }));
}
