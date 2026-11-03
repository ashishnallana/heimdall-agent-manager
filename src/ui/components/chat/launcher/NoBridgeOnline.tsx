/**
 * The launcher's no-bridge states (spec §3.5 inline banner, §3.6 full screen).
 *
 *  - `NoBridgeOnline` (§3.6) replaces the whole launcher on a cold start with no
 *    usable bridge online: a warning well, "No bridge is online", the bridges
 *    panel ("Your bridges", "0 of N online", one Offline row per non-revoked
 *    bridge), "Check again" / "Download the bridge", the notes, and a
 *    `role="status"` "Waiting for a bridge to connect" line with a breathing dot.
 *  - `NoBridgeBanner` (§3.5) sits above the composer when the chosen bridge
 *    drops while the user is on the page, so a typed message is kept.
 *
 * User decision (2026-11-03): NO bridge start command anywhere. Only in the
 * desktop app (`desktopBridgeManager()` non-null), and only for the bridge that
 * belongs to this host (`useThisMachineBridge`, matched on its verified
 * `bridge_id` like ThisMachineCard), we offer "Open setup wizard"; with no bridge
 * installed on this machine, "Set up this machine". Both go to `/setup`. A
 * browser shows neither. Starting a detected bridge directly is future work.
 */
import React, { useMemo } from 'react';
import { Alert, Button, ButtonLink, EmptyState, Icon, IconWell, Link, Panel, StatusDot, StatusPill, Text } from '@ui';
import { desktopBridgeManager, type DesktopBridgeManagerApi } from '../../../bridge/desktopBridge';
import { useThisMachineBridge } from '../../../bridge/useThisMachineBridge';
import { buildRouteHash } from '../../../utils/appLocation';
import { composerBridgeIsOnline, composerBridgeOptions } from '../../../utils/composerBridgeOptions';
import { formatRelativeTime } from '../../settings/bridgeEvents';
import { bridgeDisplayName, bridgeOsLabel } from './BridgeMenu';

export const BRIDGE_DOWNLOAD_URL = 'https://www.ninjy.ai/download';
export const SETUP_WIZARD_DEBUG_ID = 'no-bridge-setup-wizard';

/** Non-revoked, non-archived bridges (the same list the bridge menu uses). */
export function noBridgeRows(bridges: ReadonlyArray<any> | null | undefined): any[] {
  return composerBridgeOptions(bridges as any[]).map(option => option.bridge);
}

/** True when no non-revoked bridge is online and usable. */
export function noBridgeOnline(bridges: ReadonlyArray<any> | null | undefined): boolean {
  return !noBridgeRows(bridges).some(composerBridgeIsOnline);
}

/** "3 h ago" / "just now" from `last_seen_at`; '' when unknown. */
export function bridgeLastSeen(bridge: any, nowMs: number = Date.now()): string {
  const ms = Date.parse(String(bridge?.last_seen_at || ''));
  if (!Number.isFinite(ms)) return '';
  const rel = formatRelativeTime(ms, nowMs);
  return rel === '—' ? '' : rel;
}

/** "{most recently seen} was last seen {relative}." or '' when no bridge has a time. */
export function mostRecentlySeenLine(bridges: ReadonlyArray<any> | null | undefined, nowMs: number = Date.now()): string {
  const latest = noBridgeRows(bridges)
    .map(bridge => ({ bridge, ms: Date.parse(String(bridge?.last_seen_at || '')) }))
    .filter(row => Number.isFinite(row.ms))
    .sort((a, b) => b.ms - a.ms)[0];
  if (!latest) return '';
  const rel = bridgeLastSeen(latest.bridge, nowMs);
  return rel ? `${bridgeDisplayName(latest.bridge)} was last seen ${rel}.` : '';
}

/**
 * Which setup-wizard action this host gets: `open` on the row of this machine's
 * own (offline) bridge, `install` when no bridge is installed here, otherwise none
 * (still detecting, detection failed, unsupported platform, or a browser).
 */
export type ThisMachineSetup = { kind: 'open'; bridgeId: string } | { kind: 'install' } | null;

export function thisMachineSetupAction(detection: { phase: string; bridgeId: string } | null, offlineIds: ReadonlyArray<string>): ThisMachineSetup {
  if (!detection) return null;
  if (detection.phase === 'absent') return { kind: 'install' };
  if (detection.phase === 'present' && detection.bridgeId && offlineIds.includes(detection.bridgeId)) return { kind: 'open', bridgeId: detection.bridgeId };
  return null;
}

export function openSetupWizard() {
  window.location.hash = buildRouteHash('/setup', '');
}

/** Detects this host's bridge; mounted only in the desktop app. */
function ThisMachineProbe({ manager, children }: { manager: DesktopBridgeManagerApi; children: (detection: { phase: string; bridgeId: string }) => React.ReactNode }) {
  const { phase, bridgeId } = useThisMachineBridge(manager);
  return <>{children({ phase, bridgeId })}</>;
}

/**
 * Renders `children(setup)` with this host's setup action. `manager` defaults to
 * the desktop app's bridge manager (null in a browser -> no action); tests inject one.
 */
export function WithThisMachineSetup({ manager, offlineIds, children }: {
  manager?: DesktopBridgeManagerApi | null;
  offlineIds: ReadonlyArray<string>;
  children: (setup: ThisMachineSetup) => React.ReactNode;
}) {
  const resolved = useMemo(() => (manager === undefined ? desktopBridgeManager() : manager), [manager]);
  if (!resolved) return <>{children(null)}</>;
  return <ThisMachineProbe manager={resolved}>{detection => children(thisMachineSetupAction(detection, offlineIds))}</ThisMachineProbe>;
}

function SetupWizardButton({ setup, size = 'sm' }: { setup: Exclude<ThisMachineSetup, null>; size?: 'sm' | 'md' }) {
  return <Button
    variant="secondary"
    size={size}
    leading={<Icon name="gear" size="sm" />}
    data-debug-id={SETUP_WIZARD_DEBUG_ID}
    data-setup-kind={setup.kind}
    onClick={openSetupWizard}
  >{setup.kind === 'open' ? 'Open setup wizard' : 'Set up this machine'}</Button>;
}

function DownloadLink({ size = 'md', className }: { size?: 'sm' | 'md' | 'lg'; className?: string }) {
  return <ButtonLink
    href={BRIDGE_DOWNLOAD_URL}
    target="_blank"
    rel="noopener"
    variant="secondary"
    size={size}
    className={className}
    leading={<Icon name="download" size="sm" />}
    data-debug-id="no-bridge-download"
  >Download the bridge</ButtonLink>;
}

function OfflinePill() {
  return <StatusPill tone="neutral" data-bridge-status="offline">
    <StatusDot size="sm" tone="neutral" label="Offline" aria-hidden="true" />
    Offline
  </StatusPill>;
}

export interface NoBridgeOnlineProps {
  bridges: ReadonlyArray<any>;
  onCheckAgain: () => void;
  checking?: boolean;
  /** Fade out at fast duration (spec §4 #19) before the launcher swaps in. */
  leaving?: boolean;
  /** Desktop bridge manager; defaults to `desktopBridgeManager()`. */
  desktopManager?: DesktopBridgeManagerApi | null;
  nowMs?: number;
}

/** Spec §3.6: the full-screen state that replaces the launcher. */
export function NoBridgeOnline({ bridges, onCheckAgain, checking = false, leaving = false, desktopManager, nowMs }: NoBridgeOnlineProps) {
  const rows = noBridgeRows(bridges);
  const online = rows.filter(composerBridgeIsOnline).length;
  const offlineIds = rows.filter(bridge => !composerBridgeIsOnline(bridge)).map(bridge => String(bridge.bridge_id || bridge.id || ''));
  const now = nowMs ?? Date.now();
  return <WithThisMachineSetup manager={desktopManager} offlineIds={offlineIds}>{setup => (
    <EmptyState
      variant="page"
      data-debug-id="no-bridge-screen"
      className={leaving ? 'pointer-events-none animate-fade-out' : 'animate-composer-swap'}
      media={<IconWell icon="alert" size="lg" tone="warning" />}
      title={<Text as="h1" role="headline" className="m-0">No bridge is online</Text>}
      description="You can't start a conversation or a shell right now. They run through a bridge on one of your machines, and none of yours is connected. Start one and this page picks it up."
    >
      {rows.length || setup ? <Panel padding="none" data-debug-id="no-bridge-panel" className="w-full text-left">
        <div className="flex items-center justify-between gap-3 px-4 pb-2 pt-3">
          <Text as="h2" role="overline" tone="faint" className="m-0">Your bridges</Text>
          <Text as="span" role="overline" tone="faint" className="m-0" data-debug-id="no-bridge-online-count">{online} of {rows.length} online</Text>
        </div>
        <ul className="m-0 list-none p-0">
          {rows.map(bridge => {
            const id = String(bridge.bridge_id || bridge.id || '');
            const seen = bridgeLastSeen(bridge, now);
            const meta = [bridgeOsLabel(bridge), seen ? `last seen ${seen}` : ''].filter(Boolean).join(' · ');
            const isOnline = composerBridgeIsOnline(bridge);
            return <li key={id} data-debug-id={`no-bridge-row-${id}`} className="flex flex-wrap items-center gap-3 border-t border-subtle px-4 py-2.5">
              <Icon name="device" size="md" className="flex-none text-muted" />
              <span className="flex min-w-0 flex-1 flex-col">
                <Text as="span" role="body-sm" className="m-0 truncate font-medium">{bridgeDisplayName(bridge)}</Text>
                {meta ? <Text as="span" role="body-sm" tone="muted" className="m-0">{meta}</Text> : null}
              </span>
              {setup?.kind === 'open' && setup.bridgeId === id ? <SetupWizardButton setup={setup} /> : null}
              {isOnline ? <StatusPill tone="success"><StatusDot size="sm" tone="success" label="Online" aria-hidden="true" />Online</StatusPill> : <OfflinePill />}
            </li>;
          })}
        </ul>
        {setup?.kind === 'install' ? <div className="flex flex-wrap items-center justify-between gap-3 border-t border-subtle px-4 pb-4 pt-3">
          <Text as="span" role="body-sm" tone="muted" className="m-0">No bridge is installed on this machine.</Text>
          <SetupWizardButton setup={setup} />
        </div> : null}
      </Panel> : null}
      <div className="flex w-full flex-col gap-3 sm:w-auto sm:flex-row sm:flex-wrap sm:justify-center">
        <Button variant="primary" size="lg" width="full" className="sm:w-auto" leading={<Icon name="refresh" size="sm" />} loading={checking} data-debug-id="no-bridge-check-again" onClick={onCheckAgain}>Check again</Button>
        <DownloadLink size="lg" className="w-full sm:w-auto" />
      </div>
      <Text role="body-sm" tone="muted" className="m-0">New machine? Get the bridge at <Link href={BRIDGE_DOWNLOAD_URL} target="_blank" rel="noopener" data-debug-id="no-bridge-download-note">ninjy.ai/download</Link>, install it, and sign in.</Text>
      <p role="status" data-debug-id="no-bridge-waiting" className="m-0 inline-flex items-center gap-2">
        <StatusDot tone="info" label="Waiting" aria-hidden="true" className="animate-breathe" />
        <Text as="span" role="caption" tone="muted" className="m-0">Waiting for a bridge to connect</Text>
      </p>
    </EmptyState>
  )}</WithThisMachineSetup>;
}

export interface NoBridgeBannerProps {
  bridges: ReadonlyArray<any>;
  onCheckAgain: () => void;
  checking?: boolean;
  desktopManager?: DesktopBridgeManagerApi | null;
  nowMs?: number;
}

/** Spec §3.5: the inline banner above the (disabled) composer. */
export function NoBridgeBanner({ bridges, onCheckAgain, checking = false, desktopManager, nowMs }: NoBridgeBannerProps) {
  const rows = noBridgeRows(bridges);
  const offlineIds = rows.filter(bridge => !composerBridgeIsOnline(bridge)).map(bridge => String(bridge.bridge_id || bridge.id || ''));
  const seenLine = mostRecentlySeenLine(bridges, nowMs ?? Date.now());
  return <div data-debug-id="no-bridge-banner" className="animate-composer-swap">
    <Alert tone="warning" title="No machine is online" className="p-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start">
        <div className="flex min-w-0 flex-1 flex-col gap-1">
          <Text as="span" role="body-sm" tone="primary" className="m-0">Conversations and shells run through a bridge on one of your machines. Start one and it shows up here.</Text>
          {seenLine ? <Text as="span" role="caption" tone="muted" className="m-0" data-debug-id="no-bridge-last-seen">{seenLine}</Text> : null}
        </div>
        <WithThisMachineSetup manager={desktopManager} offlineIds={offlineIds}>{setup => (
          <div className="flex flex-none flex-wrap gap-2">
            <Button size="sm" variant="secondary" loading={checking} data-debug-id="no-bridge-check-again" onClick={onCheckAgain}>Check again</Button>
            <DownloadLink size="sm" />
            {setup ? <SetupWizardButton setup={setup} /> : null}
          </div>
        )}</WithThisMachineSetup>
      </div>
    </Alert>
  </div>;
}

export default NoBridgeOnline;
