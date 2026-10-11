/**
 * Which bridges the composer's "Agent settings" picker (RuntimeConfigurationOptions)
 * offers, and which of those can be chosen.
 *
 *  - ARCHIVED bridges are not shown at all. "Archive" in Settings -> Bridges is the
 *    hub's revocation, so an archived bridge reports `status: "revoked"` (or carries
 *    `revoked_at`). It can never run an agent again and is only clutter here.
 *  - OFFLINE bridges are shown but disabled: online at the hub AND with a live runtime
 *    connection, or not selectable.
 *
 * Pure and import-free so `node --test` can pin it.
 */

export type ComposerBridgeDisabledReason = 'offline' | 'update_required' | null;

export interface ComposerBridgeOption {
  id: string;
  bridge: any;
  disabledReason: ComposerBridgeDisabledReason;
}

export function composerBridgeId(bridge: any): string {
  return String(bridge?.bridge_id || bridge?.id || '');
}

export function composerBridgeIsArchived(bridge: any): boolean {
  if (String(bridge?.status || '').trim().toLowerCase() === 'revoked') return true;
  return typeof bridge?.revoked_at === 'string' && bridge.revoked_at.trim() !== '';
}

export function composerBridgeIsOnline(bridge: any): boolean {
  return String(bridge?.status || '').trim().toLowerCase() === 'online' && bridge?.runtime_connected === true;
}

export function composerBridgeOptions(bridges: any[] | null | undefined, requireReconfiguration = false): ComposerBridgeOption[] {
  return (bridges || [])
    .filter((bridge) => composerBridgeId(bridge) !== '' && !composerBridgeIsArchived(bridge))
    .map((bridge) => {
      let disabledReason: ComposerBridgeDisabledReason = null;
      if (!composerBridgeIsOnline(bridge)) disabledReason = 'offline';
      else if (requireReconfiguration && !bridge?.reconfiguration_supported) disabledReason = 'update_required';
      return { id: composerBridgeId(bridge), bridge, disabledReason };
    });
}

export const COMPOSER_BRIDGE_STATUS_LABEL: Record<'offline' | 'update_required' | 'ok', string> = {
  offline: 'Offline',
  update_required: 'Update required',
  ok: 'Connected',
};
