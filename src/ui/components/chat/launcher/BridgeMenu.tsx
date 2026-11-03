/**
 * BridgeMenu — the `[bridge]` token of the launcher headline
 * (spec §3.1 bridge token, §3.3 bridge menu: 360px, label "Bridges").
 *
 *  - Rows: bridge label, OS (plus "last seen …" when it cannot be used), and a
 *    `StatusPill` with a word: "Online", "Offline", or the existing
 *    `COMPOSER_BRIDGE_STATUS_LABEL` text for update-required / plan-limited.
 *  - Which bridges are listed and which are usable comes from the shared
 *    `composerBridgeOptions` (revoked/archived excluded, unusable listed but
 *    disabled at 45% via the picker row style).
 *  - Choosing calls `onChange({ ...runtime, bridgeId })`, i.e. the page's
 *    existing `chooseRuntime`, so its provider/model reconciliation still runs.
 *
 * Whether the `on [bridge]` clause is shown at all (spec §3.1) is the page's call.
 */
import React, { useMemo } from 'react';
import { Icon, Menu, StatusDot, StatusPill } from '@ui';
import { formatRelativeTime } from '../../settings/bridgeEvents';
import {
  COMPOSER_BRIDGE_STATUS_LABEL,
  composerBridgeOptions,
  type ComposerBridgeDisabledReason,
} from '../../../utils/composerBridgeOptions';
import type { RuntimeSelection } from '../RuntimeConfigurationOptions';
import { SentenceToken, type SentenceTokenOption } from './SentenceToken';

export const BRIDGE_MENU_WIDTH = 360;
export const BRIDGE_MENU_LABEL = 'Bridges';

export function bridgeDisplayName(bridge: any, fallback = 'Bridge'): string {
  return String(bridge?.label || bridge?.machine_hostname || bridge?.bridge_id || bridge?.id || fallback);
}

const OS_NAMES: Record<string, string> = { linux: 'Linux', darwin: 'macOS', macos: 'macOS', mac: 'macOS', windows: 'Windows', win32: 'Windows', freebsd: 'FreeBSD' };

/** "Linux", "macOS", "Windows"; unknown values pass through; missing -> ''. */
export function bridgeOsLabel(bridge: any): string {
  const raw = String(bridge?.machine_os || bridge?.os || '').trim();
  return OS_NAMES[raw.toLowerCase()] ?? raw;
}

/** The pill word for a row. */
export function bridgeStatusWord(reason: ComposerBridgeDisabledReason): string {
  if (reason === null) return 'Online';
  if (reason === 'offline') return 'Offline';
  return COMPOSER_BRIDGE_STATUS_LABEL[reason];
}

function lastSeen(bridge: any, nowMs: number): string {
  const ms = Date.parse(String(bridge?.last_seen_at || ''));
  if (!Number.isFinite(ms)) return '';
  const rel = formatRelativeTime(ms, nowMs);
  return rel === '—' ? '' : `last seen ${rel}`;
}

export function bridgeMenuOptions(bridges: ReadonlyArray<any> | null | undefined, opts: { requireReconfiguration?: boolean; nowMs?: number } = {}): Array<SentenceTokenOption> {
  const nowMs = opts.nowMs ?? Date.now();
  return composerBridgeOptions(bridges as any[], opts.requireReconfiguration).map(({ id, bridge, disabledReason }) => {
    const usable = disabledReason === null;
    const word = bridgeStatusWord(disabledReason);
    const description = [bridgeOsLabel(bridge), usable ? '' : lastSeen(bridge, nowMs)].filter(Boolean).join(' · ');
    return {
      value: id,
      label: bridgeDisplayName(bridge),
      description: description || undefined,
      disabled: !usable,
      keywords: [String(bridge?.machine_hostname || '')].filter(Boolean),
      leading: <Icon name="device" size="md" />,
      trailing: (
        <StatusPill tone={usable ? 'success' : disabledReason === 'offline' ? 'neutral' : 'warning'} data-bridge-status={disabledReason ?? 'ok'}>
          <StatusDot size="sm" tone={usable ? 'success' : disabledReason === 'offline' ? 'neutral' : 'warning'} label={word} aria-hidden="true" />
          {word}
        </StatusPill>
      ),
      debugId: `new-convo-machine-option-${id}`,
    };
  });
}

export interface BridgeMenuProps {
  bridges: ReadonlyArray<any>;
  /** The page's current runtime; its `bridgeId` is the chosen bridge. */
  runtime: RuntimeSelection;
  /** The page's existing `chooseRuntime`; receives `{ ...runtime, bridgeId }`. */
  onChange: (next: RuntimeSelection) => void;
  /** Mark bridges without reconfiguration support "Update required" (as `RuntimeConfigurationOptions` does). */
  requireReconfiguration?: boolean;
  disabled?: boolean;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
}

export function BridgeMenu({ bridges, runtime, onChange, requireReconfiguration, disabled, open, onOpenChange }: BridgeMenuProps) {
  const options = useMemo(() => bridgeMenuOptions(bridges, { requireReconfiguration }), [bridges, requireReconfiguration]);
  const selected = options.find((option) => option.value === runtime.bridgeId);
  const online = !!selected && !selected.disabled;
  return (
    <SentenceToken
      value={runtime.bridgeId}
      options={options}
      onChange={(bridgeId) => onChange({ ...runtime, bridgeId })}
      label={BRIDGE_MENU_LABEL}
      debugId="new-convo-machine-token"
      menuWidth={BRIDGE_MENU_WIDTH}
      menuHeader={<Menu.Label>{BRIDGE_MENU_LABEL}</Menu.Label>}
      leading={<StatusDot tone={online ? 'success' : 'neutral'} label={online ? 'Online' : 'Offline'} />}
      disabled={disabled}
      open={open}
      onOpenChange={onOpenChange}
    >
      {selected ? undefined : 'a bridge'}
    </SentenceToken>
  );
}

export default BridgeMenu;
