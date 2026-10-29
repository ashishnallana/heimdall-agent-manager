// REQ-TB-5: pure helpers for the per-task bridge pin — the create-task select,
// the task-detail display, and the presence-aware wire serialization.
//
// A task either pins one specific bridge (bridge_id) or inherits the
// coordinator's bridge. Hub contract: CREATE treats an absent and an empty
// bridge_id identically (inherit), while PATCH is presence-checked — the key is
// always sent by the change control and '' is the explicit clear-to-inherit
// signal.
//
// Deliberately free of ANY import (not even bridgeLaunchOptions, whose
// bridgeSupport import chain cannot load under node --test): these helpers are
// unit-tested directly by tests/ui_fleet_actions_test.ts, so they must resolve
// from plain node. Keep it that way.

export const TASK_BRIDGE_INHERIT_LABEL = 'Inherit (coordinator bridge)';

/** Match the hub's chain bridge resolution before applying a task pin. */
export function effectiveChainBridgeId(chain: any, instances: any[], bridges: any[]): string {
  const instanceId = (instance: any) => String(instance?.agent_instance_id || instance?.agentInstanceId || '');
  const coordinatorId = String(chain?.coordinator_agent_instance_id || chain?.coordinatorAgentInstanceId || '');
  const coordinator = instances.find((instance) => instanceId(instance) === coordinatorId);
  if (bridgeIdOf(coordinator)) return bridgeIdOf(coordinator);
  for (const member of chain?.members || []) {
    const instance = instances.find((instance) => instanceId(instance) === instanceId(member));
    if (bridgeIdOf(instance)) return bridgeIdOf(instance);
  }
  const chainInstance = instances.find((instance) =>
    String(instance.chain_id || instance.chainId || '') === String(chain?.chain_id || chain?.chainId || chain?.id || '') && bridgeIdOf(instance)
  );
  return bridgeIdOf(chainInstance) || bridgeIdOf(chain?.directories?.[0]) || bridgeIdOf(bridges?.[0]);
}

function bridgeIdOf(bridge: any): string {
  return String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
}

function bridgeLabel(bridge: any): string {
  return String(bridge?.label || bridge?.machine_hostname || bridgeIdOf(bridge) || '');
}

// GET /bridges is owner-scoped but includes revoked rows (launch settings
// filters them the same way) — a revoked bridge can no longer host a task.
export function isRevokedBridge(bridge: any): boolean {
  return String(bridge?.status || bridge?.runtime_status || bridge?.state || '').includes('revoke');
}

// Only an online (connected, not revoked, not plan-disabled) bridge can take a
// task, so only those are offered.
export function isActiveBridge(bridge: any): boolean {
  return !isRevokedBridge(bridge) && !bridge?.plan_disabled_at && String(bridge?.status || '').toLowerCase() === 'online';
}

// The pin options: inherit, then every active bridge by name. keepId (the
// current pin) stays listed while offline, marked so, so the select can show it.
export function taskBridgeOptions(bridges: any[], keepId = ''): Array<{ value: string; label: string }> {
  return [
    { value: '', label: TASK_BRIDGE_INHERIT_LABEL },
    ...(bridges || [])
      .filter((bridge) => isActiveBridge(bridge) || (keepId !== '' && bridgeIdOf(bridge) === keepId))
      .map((bridge) => ({ value: bridgeIdOf(bridge), label: `${bridgeLabel(bridge)}${isActiveBridge(bridge) ? '' : ' (offline)'}` })),
  ];
}

// Wire fields for task CREATE: omit the key entirely on the default (inherit)
// create; include it only when a concrete bridge is chosen.
export function taskCreateBridgeFields(bridgeId: string | undefined): Record<string, string> {
  return bridgeId ? { bridge_id: bridgeId } : {};
}

// Wire fields for the presence-checked task PATCH: always carry the key — ''
// clears an existing pin back to inherit.
export function taskPatchBridgeFields(bridgeId: string): Record<string, string> {
  return { bridge_id: String(bridgeId ?? '') };
}

// Display name for a task's bridge pin: resolved from the /bridges list, with
// inherited=true when the task carries no pin (an unknown pinned id falls back
// to the raw id so a revoked/foreign pin never renders blank).
export function taskBridgeDisplay(bridgeId: string | undefined, bridges: any[]): { label: string; inherited: boolean } {
  const id = String(bridgeId || '');
  if (!id) return { label: '', inherited: true };
  const bridge = (bridges || []).find((b) => bridgeIdOf(b) === id);
  return { label: bridge ? bridgeLabel(bridge) : id, inherited: false };
}
