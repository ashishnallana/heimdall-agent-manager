// Bridge approval on /device/add: register the enrolling bridge as a NEW bridge, or let it
// take over an EXISTING bridge identity (same bridge_id: agents, fleet entries and project
// paths stay attached). Reuse is opt-in by the approver; the bridge's previous_bridge_id
// is an untrusted hint the hub only echoes when it names one of the approver's reusable
// bridges, and this page re-checks that against the list before preselecting it.

import type { BridgeApprovalBody, BridgeCodeInfo, ReusableBridge } from '../../api/endpoints/vaultDevices';

export type BridgeMode = 'new' | 'reuse';

export interface BridgeChoice {
  mode: BridgeMode;
  /** The bridge to reuse; kept while the user flips to New so flipping back restores it. */
  targetBridgeId: string;
}

const BRIDGE_ID = /^brg_[A-Za-z0-9_-]{1,60}$/;

export const REUSE_WARNING = 'Reusing hands this identity to the new machine: the old bridge credentials are revoked, and if that bridge is online now its machine is disconnected. Its agents, fleet entries and project paths are kept.';

/** The well-formed, de-duplicated reusable bridges the hub listed (its order: most recently seen first). */
export function reusableBridgesOf(info: Pick<BridgeCodeInfo, 'reusable_bridges'> | null | undefined): ReusableBridge[] {
  const raw = Array.isArray(info?.reusable_bridges) ? info.reusable_bridges : [];
  const seen = new Set<string>();
  const out: ReusableBridge[] = [];
  for (const b of raw) {
    const id = typeof b?.bridge_id === 'string' ? b.bridge_id : '';
    if (!BRIDGE_ID.test(id) || seen.has(id)) continue;
    seen.add(id);
    out.push({
      bridge_id: id,
      label: typeof b.label === 'string' ? b.label : '',
      machine_hostname: typeof b.machine_hostname === 'string' ? b.machine_hostname : '',
      status: b.status === 'online' ? 'online' : 'offline',
      last_seen: typeof b.last_seen === 'string' ? b.last_seen : '',
    });
  }
  return out;
}

/** Reuse with the hinted bridge when the hint names a listed bridge; otherwise New. */
export function initialBridgeChoice(info: Pick<BridgeCodeInfo, 'reusable_bridges' | 'previous_bridge_id'> | null | undefined): BridgeChoice {
  const list = reusableBridgesOf(info);
  const hint = typeof info?.previous_bridge_id === 'string' ? info.previous_bridge_id : '';
  if (hint && list.some((b) => b.bridge_id === hint)) return { mode: 'reuse', targetBridgeId: hint };
  return { mode: 'new', targetBridgeId: list[0]?.bridge_id ?? '' };
}

/** The listed bridge a reuse choice names, or null when it is not (or no longer) listed. */
export function reuseTarget(list: readonly ReusableBridge[], choice: BridgeChoice): ReusableBridge | null {
  if (choice.mode !== 'reuse') return null;
  return list.find((b) => b.bridge_id === choice.targetBridgeId) ?? null;
}

/** The label signed into the vault approval: the reused bridge keeps its name. */
export function approvalLabel(target: ReusableBridge | null, typedLabel: string): string {
  return (target ? target.label.trim() : '') || typedLabel;
}

/** POST /device/approve body: target_bridge_id for reuse, new_bridge_label for new — never both. */
export function bridgeApproveBody(
  pairLookup: string,
  vaultApproval: NonNullable<BridgeApprovalBody['vault_approval']>,
  target: ReusableBridge | null,
  newLabel: string,
  sunsetBridgeId = '',
): BridgeApprovalBody {
  const base = { pair_lookup: pairLookup, approve: true, vault_approval: vaultApproval };
  if (target) {
    // An attach takes no new plan slot, so there is nothing to sunset for; the hub
    // refuses the pair, and so do we, before anything is sent.
    if (sunsetBridgeId) throw new Error('A reused bridge identity cannot also sunset a bridge.');
    return { ...base, target_bridge_id: target.bridge_id };
  }
  return sunsetBridgeId ? { ...base, new_bridge_label: newLabel, sunset_bridge_id: sunsetBridgeId } : { ...base, new_bridge_label: newLabel };
}

export function bridgeApprovedMessage(target: ReusableBridge | null, label: string, bridgeId: string, sunsetLabel = ''): string {
  const what = target
    ? `Reused bridge identity “${label}” (${bridgeId}); its old credentials are revoked`
    : sunsetLabel
      ? `Registered new bridge “${label}” (${bridgeId}) and sunset “${sunsetLabel}”`
      : `Registered new bridge “${label}” (${bridgeId})`;
  return `${what}. The vault key was delivered: the bridge restarts its service and comes online unsealed.`;
}

/** "online", or "offline · last seen <local time>" for the picker. */
export function reusableBridgeStatusText(b: ReusableBridge): string {
  if (b.status === 'online') return 'online';
  const at = Date.parse(b.last_seen);
  return Number.isFinite(at) ? `offline · last seen ${new Date(at).toLocaleString()}` : 'offline';
}


/** At capacity, a new approval must reuse a listed identity (zero also means full). */
export function bridgeChoiceAtLimit(info: Pick<BridgeCodeInfo, 'reusable_bridges'>, choice: BridgeChoice, atCapacity: boolean): BridgeChoice {
  if (!atCapacity) return choice;
  const list = reusableBridgesOf(info);
  return { mode: 'reuse', targetBridgeId: list.some((b) => b.bridge_id === choice.targetBridgeId) ? choice.targetBridgeId : list[0]?.bridge_id || '' };
}
