import { useEntitlements } from '../../hooks/useEntitlements';
import { useCallback, useEffect, useLayoutEffect, useMemo, useState } from 'react';
import {
  type Bridge,
  useBridgeProviderStatus,
  useListBridgesQuery,
  useRenameBridgeMutation,
  useRevokeBridgeMutation,
  useUninstallBridgeMutation,
  useUpdateBridgeMutation,
  useUpdateBridgeTelemetryMutation,
} from '../../api/endpoints/bridgeSupport';
import { desktopCapabilities } from '../../bridge/desktopBridge';
import BridgeOperationRail from '../bridge/BridgeOperationRail';
import ThisMachineCard from './ThisMachineCard';
import BridgeAutoUpdateToggle from './BridgeAutoUpdateToggle';
import {
  useFetchTelemetryDefaultEnabledQuery,
  useSaveTelemetryDefaultEnabledMutation,
} from '../../api/endpoints/settings';
import { Button, FormField, Icon, Input, PageShell, Badge, Select, StatusPill, StatusDot, Text, Modal, ModalBody, ModalFooter, Spinner, Toggle } from '@ui';
import type { Tone } from '@ui';
import {
  bridgeReady as checkBridgeReady,
} from './bridgeEnrollment';
import {
  formatBridgeVersion,
  formatLatestVersion,
  isBridgeUpdating,
  bridgeUpdateStatusLabel,
  getActiveTaskCount,
  isUpdateUnavailableForTarget,
  updateAvailabilityLabel,
} from './bridgeUpdate';
import BridgeRecentErrorsCard from './BridgeRecentErrorsCard';
import PendingEnrollmentsCard from './PendingEnrollmentsCard';

// UI-11 / REQ-ENR-8..11: Settings → Bridges, the one place bridges are set up
// and managed (F29). Desktop app: a "This machine" card (setup wizard, or
// Update / Re-enroll / Uninstall) and the other bridges with Update and
// Uninstall (a live bridge uninstalls itself via bridge_uninstall; an offline
// one can only be revoked). Web app: the installed bridges with Update only.
export interface BridgeSettingsHeading { title: string; description: string; breadcrumb: string; focusKey: string }
export default function BridgesPanel({ onHeadingChange }: { onHeadingChange?: (heading: BridgeSettingsHeading) => void } = {}) {
  const desktop = useMemo(() => desktopCapabilities(), []);
  const manager = desktop.bridgeManager;
  const [selectedId, setSelectedId] = useState('');
  const [localBridgeId, setLocalBridgeId] = useState('');
  const [uninstallBridge] = useUninstallBridgeMutation();
  const [uninstallConfirmId, setUninstallConfirmId] = useState('');
  const entitlements = useEntitlements();
  const bridgesQuery = useListBridgesQuery(undefined);
  const [renameBridge] = useRenameBridgeMutation();
  const [updateBridgeTelemetry] = useUpdateBridgeTelemetryMutation();
  const [revokeBridge] = useRevokeBridgeMutation();
  const [updateBridge] = useUpdateBridgeMutation();
  const globalTelemetryQuery = useFetchTelemetryDefaultEnabledQuery();
  const globalTelemetryData = globalTelemetryQuery.data;
  const [saveGlobalTelemetry, globalTelemetrySave] = useSaveTelemetryDefaultEnabledMutation();

  const [renamingId, setRenamingId] = useState('');
  const [renameValue, setRenameValue] = useState('');
  const [actionError, setActionError] = useState('');

  // Update modal state
  const [updateModalBridge, setUpdateModalBridge] = useState<Bridge | null>(null);
  const [updateForce, setUpdateForce] = useState(false);
  const [updateExtensions, setUpdateExtensions] = useState(true);
  const [updateDrainTimeout, setUpdateDrainTimeout] = useState(60);
  const [updateBusy, setUpdateBusy] = useState(false);
  const [updateError, setUpdateError] = useState('');

  const refetchBridges = useCallback(() => { void bridgesQuery.refetch(); }, [bridgesQuery.refetch]);

  const bridges: Bridge[] = (bridgesQuery.data?.bridges || [])
    .filter((b: Bridge) => String(b?.status || b?.runtime_status || '').toLowerCase() !== 'revoked');
  const selectedBridge = bridges.find((b) => String(b.bridge_id || b.bridgeId || b.id || '') === selectedId);
  const nameOf = (b: Bridge) => b.label || b.machine_hostname || b.hostname || String(b.bridge_id || b.id || 'Bridge');

  function bridgeOnline(bridge: Bridge): boolean {
    const status = String(bridge?.status || bridge?.runtime_status || '').toLowerCase();
    return bridge.runtime_connected === true || status === 'online' || status === 'connected';
  }

  async function handleUninstall(bridge: Bridge, bridgeId: string) {
    setActionError('');
    try {
      // An offline bridge cannot run its own uninstall: revoke it instead.
      if (bridgeOnline(bridge)) await uninstallBridge({ bridgeId, purge: true }).unwrap();
      else await revokeBridge({ bridgeId }).unwrap();
      setUninstallConfirmId('');
    } catch (err: any) {
      setActionError(String(err?.error || err?.message || 'Uninstall failed'));
    }
  }

  function statusTone(bridge: Bridge): Tone {
    if (bridge.plan_disabled_at) return 'warning';
    const status = String(bridge?.status || bridge?.runtime_status || '').toLowerCase();
    if (status === 'revoked') return 'danger';
    if (status === 'online' || status === 'connected') return 'success';
    return 'neutral';
  }

  function statusLabel(bridge: Bridge): string {
    if (bridge.plan_disabled_at) return 'Disabled — over plan limit';
    const status = String(bridge?.status || bridge?.runtime_status || '').toLowerCase();
    return status || 'offline';
  }

  // REQ-BRG-1: An enrolled, online bridge is ready regardless of whether provider capabilities are loaded yet.
  function bridgeReady(bridge: Bridge): boolean {
    return checkBridgeReady(bridge);
  }

  async function handleSaveRename(bridgeId: string) {
    const label = renameValue.trim();
    if (!label) return;
    try {
      await renameBridge({ bridgeId, label }).unwrap();
      setRenamingId('');
    } catch (err: any) {
      setActionError(String(err?.message || 'Rename failed'));
    }
  }

  async function handleToggleGlobalTelemetry(enabled: boolean) {
    setActionError('');
    try {
      await saveGlobalTelemetry({ enabled }).unwrap();
    } catch (err: any) {
      setActionError(String(err?.message || 'Failed to update global telemetry setting'));
    }
  }

  async function handleUpdateBridgeTelemetry(bridgeId: string, telemetry: 'inherit' | 'enabled' | 'disabled') {
    try {
      await updateBridgeTelemetry({ bridgeId, telemetry_enabled: telemetry }).unwrap();
    } catch (err: any) {
      setActionError(String(err?.message || 'Failed to update bridge telemetry preference'));
    }
  }

  async function handleConfirmUpdate() {
    if (!updateModalBridge) return;
    const bridgeId = String(updateModalBridge.bridge_id || updateModalBridge.bridgeId || updateModalBridge.id || '');
    setUpdateBusy(true);
    setUpdateError('');
    try {
      await updateBridge({
        bridgeId,
        targetVersion: updateModalBridge.latest_version || 'latest',
        force: updateForce,
        updateExtensions,
        drainTimeoutSeconds: updateDrainTimeout,
      }).unwrap();
      setUpdateModalBridge(null);
    } catch (err: any) {
      setUpdateError(String(err?.data?.error?.message || err?.error || err?.message || 'Failed to trigger bridge update'));
    } finally {
      setUpdateBusy(false);
    }
  }

  const title = selectedBridge ? nameOf(selectedBridge) : 'Bridges';
  const description = selectedBridge ? 'Updates, provider availability and connection settings for this bridge.'
    : 'Manage the machines that run your agents. Open a bridge for updates, provider availability and connection settings.';
  useLayoutEffect(() => { onHeadingChange?.({ title, description, breadcrumb: selectedId ? 'Settings / Bridges' : '', focusKey: selectedId || 'overview' }); },
    [onHeadingChange, title, description, selectedId]);
  const content = (
      <div data-debug-id="settings-bridges-panel" className="min-w-0">
      {selectedId ? <Button variant="ghost" size="sm" data-debug-id="settings-bridges-back" onClick={() => { setSelectedId(''); setRenamingId(''); setUninstallConfirmId(''); }}>Back to Bridges</Button> : null}
      <div className={selectedId && selectedId !== localBridgeId ? 'hidden' : ''}>
      {manager ? <ThisMachineCard manager={manager} onBridgeId={setLocalBridgeId} onSetupComplete={refetchBridges} /> : null}
      </div>
      {desktop.legacyBridgeManager ? (
        <div data-debug-id="settings-bridges-desktop-outdated" className="mt-3 rounded-xl border border-warning/30 bg-warning-soft px-3 py-2 text-sm text-warning">
          This desktop app is too old to set up or manage this machine's Bridge from here. Update the desktop app to the latest version, or run ham-bridge on this machine.
        </div>
      ) : null}
      {bridgesQuery.isError ? <div data-debug-id="settings-bridges-load-error" className="mt-3 rounded-xl border border-danger/30 bg-danger-soft px-3 py-2 text-sm text-danger">Unable to load bridges. Check that you are signed in and the Hub is reachable.</div> : null}
      {actionError ? <div data-debug-id="settings-bridges-error" className="mt-3 rounded-xl border border-danger/30 bg-danger-soft px-3 py-2 text-sm text-danger">{actionError}</div> : null}

      {/* Approved bridges whose vault key has not been delivered yet (REQ-EA-6) */}
      {!selectedId ? <PendingEnrollmentsCard /> : null}

      {/* Bridge list */}
      <div data-debug-id="settings-bridges-list" className="mt-6">
        {!selectedId ? <>
        <Text as="div" role="overline" tone="muted" className="mb-2">{'Your bridges'} ({bridges.length})</Text>
        <p data-debug-id="settings-bridges-usage" className="mb-2 text-xs text-muted">{bridges.filter((b) => !b.plan_disabled_at).length} of {entitlements.max_bridges < 0 ? 'unlimited' : entitlements.max_bridges} bridges enabled</p>
        </> : null}
        {bridgesQuery.isFetching && bridges.length === 0 ? <div className="text-sm text-muted">Loading bridges…</div> : null}
        {bridges.length === 0 && !bridgesQuery.isFetching ? (
          <div data-debug-id="settings-bridges-empty" className="rounded-xl border border-dashed border-subtle bg-surface-raised/30 p-4 text-center text-sm text-muted">No active bridges.</div>
        ) : (
          <div className={!selectedId ? "grid grid-cols-1 gap-3" : "space-y-4"}>
            {!selectedId ? bridges.map((bridge) => {
              const id = String(bridge.bridge_id || bridge.bridgeId || bridge.id || '');
              const online = bridgeOnline(bridge);
              return <button key={id} type="button" data-debug-id={`settings-bridge-card-${id}`} onClick={() => setSelectedId(id)}
                className="min-w-0 space-y-4 rounded-xl border border-subtle bg-surface p-4 text-left transition-colors hover:bg-surface-raised focus-visible:outline-none focus-visible:shadow-focus">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="min-w-0 break-words"><Text as="h2" role="heading">{nameOf(bridge)}</Text><Text role="code" tone="muted" className="break-all">{bridge.machine_hostname || bridge.hostname || id}</Text></div>
                  <StatusPill tone={statusTone(bridge)}>{statusLabel(bridge)}</StatusPill>
                </div>
                <div className="flex flex-wrap gap-x-4 gap-y-2 text-sm text-muted">
                  <span>{bridge.machine_os || bridge.os || 'Unknown OS'} · {bridge.machine_arch || bridge.arch || 'Unknown architecture'}</span>
                  <span>{getActiveTaskCount(bridge)} active agents</span><span className="font-mono">{formatBridgeVersion(bridge) || 'Unknown version'}</span>
                </div>
                <div className="flex flex-wrap gap-2">
                  {localBridgeId === id ? <Badge data-debug-id="settings-bridge-local-badge">This machine</Badge> : null}
                  {isBridgeUpdating(bridge) ? <StatusPill tone="info">{bridgeUpdateStatusLabel(bridge)}</StatusPill>
                    : bridge.update_available ? <Badge>{updateAvailabilityLabel(bridge)}</Badge> : null}
                  <Badge>Vault: {online ? '' : 'last reported: '}{bridge.vault_status || 'unknown'}</Badge>
                </div>
                <div className="flex flex-wrap justify-between gap-2 border-t border-subtle pt-3 text-xs text-muted">
                  <span>{online ? 'Connected' : 'Last reported state'}{bridge.last_seen_at ? ` · Last seen ${new Date(bridge.last_seen_at).toLocaleString()}` : ''}</span>
                  <span className="font-medium text-accent">Manage bridge</span>
                </div>
              </button>;
            }) : null}
            {bridges.filter((bridge) => String(bridge.bridge_id || bridge.bridgeId || bridge.id || '') === selectedId).map((bridge: Bridge) => {
              const id = String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
              const isRenaming = renamingId === id;
              const isUninstalling = uninstallConfirmId === id;
              const online = bridgeOnline(bridge);
              const isReady = bridgeReady(bridge);
              const status = statusLabel(bridge);
              const isUpdating = isBridgeUpdating(bridge);
              const hasVersion = Boolean(bridge?.version || bridge?.commit_sha);
              const versionLabel = formatBridgeVersion(bridge);
              const latestLabel = formatLatestVersion(bridge);
              const updateUnavailable = isUpdateUnavailableForTarget(bridge);

              return (
                <div key={id} data-debug-id={`settings-bridge-row-${id}`} className="min-w-0 rounded-xl border border-subtle bg-surface p-4">
                  <div className="flex min-w-0 flex-col gap-4">
                    <div className="min-w-0 flex-1">
                      <div className="flex flex-wrap items-center gap-1.5 sm:gap-2">
                        <StatusDot data-debug-id={`settings-bridge-status-${id}`} tone={statusTone(bridge)} label={statusLabel(bridge)} />
                        {isRenaming ? (
                          <Input data-debug-id={`settings-bridge-rename-input-${id}`} value={renameValue} onChange={setRenameValue} size="sm" className="min-w-0 flex-1" autoFocus />
                        ) : (
                          <span className="truncate text-sm font-medium text-primary">{bridge?.label || bridge?.machine_hostname || bridge?.hostname || id}</span>
                        )}
                        <span data-debug-id={`settings-bridge-ready-${id}`} className={`rounded-full border px-2 py-0.5 text-[10px] whitespace-nowrap ${isReady ? 'border-success/30 bg-success-soft text-success' : status === 'revoked' ? 'border-danger/30 bg-danger-soft text-danger' : 'border-warning/30 bg-warning-soft text-warning'}`}>{isReady ? 'ready' : status}</span>

                        {bridge.plan_disabled_at ? (
                          <a href="#/settings/account" data-debug-id={`settings-bridge-plan-upgrade-${id}`} className="text-xs font-medium text-accent underline">Upgrade</a>
                        ) : null}

                        {/* Monospace version badge: e.g. v0.1.0 (a57c83d9) */}
                        {hasVersion ? (
                          <span
                            data-debug-id={`settings-bridge-version-${id}`}
                            className="inline-flex items-center rounded-full border border-subtle bg-surface-raised/60 px-2 py-0.5 font-mono text-[10px] text-primary whitespace-nowrap"
                            title={bridge?.build_timestamp ? `Built: ${bridge.build_timestamp}` : undefined}
                          >
                            {versionLabel}
                          </span>
                        ) : null}

                        {/* Prominent Update Available badge; muted when the release has no bundle for this target (REQ-T13-4) */}
                        {updateUnavailable ? (
                          <span
                            data-debug-id={`settings-bridge-update-unavailable-${id}`}
                            className="inline-flex items-center gap-1 rounded-full border border-subtle bg-surface-raised/40 px-2 py-0.5 text-[10px] text-muted whitespace-nowrap"
                            title={`The latest release (${latestLabel}) ships no bundle for ${bridge?.target || 'this target'}; this bridge stays on its current version.`}
                          >
                            <span>{updateAvailabilityLabel(bridge)}</span>
                          </span>
                        ) : bridge?.update_available ? (
                          <span
                            data-debug-id={`settings-bridge-update-available-${id}`}
                            className="inline-flex items-center gap-1 rounded-full border border-accent/40 bg-accent-soft px-2 py-0.5 text-[10px] font-medium text-accent whitespace-nowrap"
                          >
                            <Icon name="sparkle" size="sm" />
                            <span>Update available: {latestLabel}</span>
                          </span>
                        ) : null}

                        {bridge?.latest_version && bridge?.latest_source ? (
                          <Text as="span" role="caption" tone="muted">Catalog: {latestLabel} ({bridge.latest_source})</Text>
                        ) : null}
                        <BridgeAutoUpdateToggle bridgeId={id} online={online} />
                        {bridge?.update_warning ? (
                          <span role="status"><Text as="span" role="caption" tone="warning">{bridge.update_warning}</Text></span>
                        ) : null}
                        {bridge?.update_fallback_reason ? (
                          <Text as="span" role="caption" tone="muted">Release lookup: {bridge.update_fallback_reason}</Text>
                        ) : null}

                        {/* Real-time progress state if update is in progress (downloading, validating, restarting) */}
                        {isUpdating ? (
                          <span
                            data-debug-id={`settings-bridge-update-progress-${id}`}
                            className="inline-flex items-center gap-1.5 rounded-full border border-accent/40 bg-accent-soft px-2 py-0.5 text-[10px] font-medium text-accent animate-pulse whitespace-nowrap"
                          >
                            <Spinner size="sm" />
                            <span>{bridgeUpdateStatusLabel(bridge)}{typeof bridge.update_progress === 'number' && bridge.update_progress > 0 ? ` (${bridge.update_progress}%)` : ''}</span>
                          </span>
                        ) : bridge?.update_status === 'failed' ? (
                          <span
                            data-debug-id={`settings-bridge-update-failed-${id}`}
                            className="inline-flex items-center gap-1 rounded-full border border-danger/40 bg-danger-soft px-2 py-0.5 text-[10px] text-danger whitespace-nowrap"
                            title={bridge?.update_error || 'Update failed'}
                          >
                            <Icon name="alert" size="sm" />
                            <span>Update failed{bridge?.update_error ? `: ${bridge.update_error}` : ''}</span>
                          </span>
                        ) : null}

                        <BridgeNoProvidersBadge bridge={bridge} id={id} /><a data-debug-id={`settings-bridge-profiles-${id}`} className="text-xs text-accent underline" href={`#/settings/providers/${encodeURIComponent(id)}`}>Provider profiles</a>
                      </div>
                      <div className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-caption text-muted">
                        <span>status: <span data-debug-id={`settings-bridge-status-label-${id}`} className="text-primary">{statusLabel(bridge)}</span></span>
                        <span>host: <span className="text-primary">{bridge?.machine_hostname || bridge?.hostname || '—'}</span></span>
                        <span>os: <span className="text-primary">{bridge?.machine_os || bridge?.os || '—'}</span></span>
                        <span>arch: <span className="text-primary">{bridge?.machine_arch || bridge?.arch || '—'}</span></span>
                        <span>target: <span data-debug-id={`settings-bridge-target-${id}`} className="font-mono text-primary">{bridge?.target || '—'}</span></span>
                        <span>instances: <span className="text-primary">{bridge?.active_instance_count ?? bridge?.instance_count ?? bridge?.instances?.length ?? 0}</span></span>
                        <span>last seen: <span className="text-primary">{bridge?.last_seen_at ? new Date(bridge.last_seen_at).toLocaleString() : '—'}</span></span>
                      </div>
                      <div className="mt-2.5 flex flex-wrap items-center gap-2 text-xs">
                        <span className="text-muted font-medium">Telemetry:</span>
                        <div
                          data-debug-id={`settings-bridge-telemetry-toggle-${id}`}
                          className="inline-flex max-w-full flex-wrap gap-1 rounded-lg border border-subtle bg-surface p-0.5"
                          role="group"
                          aria-label={`Bridge ${id} Telemetry`}
                        >
                          <button
                            type="button"
                            data-debug-id={`settings-bridge-telemetry-inherit-${id}`}
                            className={`rounded px-2 py-0.5 text-xs transition-colors ${
                              (bridge?.telemetry_enabled || 'inherit') === 'inherit'
                                ? 'bg-surface-raised text-primary font-medium shadow-sm'
                                : 'text-muted hover:text-primary'
                            }`}
                            onClick={() => void handleUpdateBridgeTelemetry(id, 'inherit')}
                          >
                            Inherit Global ({(globalTelemetryData?.enabled ?? true) ? 'Enabled' : 'Disabled'})
                          </button>
                          <button
                            type="button"
                            data-debug-id={`settings-bridge-telemetry-enabled-${id}`}
                            className={`rounded px-2 py-0.5 text-xs transition-colors ${
                              bridge?.telemetry_enabled === 'enabled'
                                ? 'bg-success text-success-contrast font-medium shadow-sm'
                                : 'text-muted hover:text-primary'
                            }`}
                            onClick={() => void handleUpdateBridgeTelemetry(id, 'enabled')}
                          >
                            Enabled
                          </button>
                          <button
                            type="button"
                            data-debug-id={`settings-bridge-telemetry-disabled-${id}`}
                            className={`rounded px-2 py-0.5 text-xs transition-colors ${
                              bridge?.telemetry_enabled === 'disabled'
                                ? 'bg-danger text-danger-contrast font-medium shadow-sm'
                                : 'text-muted hover:text-primary'
                            }`}
                            onClick={() => void handleUpdateBridgeTelemetry(id, 'disabled')}
                          >
                            Disabled
                          </button>
                        </div>
                      </div>
                    </div>
                    <div className="flex flex-wrap items-center gap-1.5 sm:shrink-0 sm:justify-end">
                      {isRenaming ? (
                        <>
                          <Button variant="primary" size="sm" data-debug-id={`settings-bridge-rename-save-${id}`} onClick={() => void handleSaveRename(id)}>Save</Button>
                          <Button variant="secondary" size="sm" data-debug-id={`settings-bridge-rename-cancel-${id}`} onClick={() => setRenamingId('')}>Cancel</Button>
                        </>
                      ) : isUninstalling ? (
                        <>
                          <Button variant="danger" size="sm" data-debug-id={`settings-bridge-uninstall-confirm-${id}`} onClick={() => void handleUninstall(bridge, id)}>
                            {online ? 'Uninstall and wipe secrets' : 'Revoke offline bridge'}
                          </Button>
                          <Button variant="secondary" size="sm" data-debug-id={`settings-bridge-uninstall-cancel-${id}`} onClick={() => setUninstallConfirmId('')}>Cancel</Button>
                        </>
                      ) : (
                        <>
                          {id !== localBridgeId ? <Button
                            variant={bridge?.update_available && !updateUnavailable ? 'primary' : 'secondary'}
                            size="sm"
                            data-debug-id={`settings-bridge-update-btn-${id}`}
                            title={updateUnavailable ? updateAvailabilityLabel(bridge) : undefined}
                            disabled={!isReady || isUpdating}
                            onClick={() => {
                              setUpdateModalBridge(bridge);
                              setUpdateForce(false);
                              setUpdateExtensions(true);
                              setUpdateDrainTimeout(60);
                              setUpdateError('');
                            }}
                          >
                            Update
                          </Button> : null}
                          <Button variant="secondary" size="sm" data-debug-id={`settings-bridge-rename-btn-${id}`} onClick={() => { setRenamingId(id); setRenameValue(bridge?.label || ''); }}>Rename</Button>
                          {manager && id !== localBridgeId ? (
                            <Button
                              variant="danger"
                              size="sm"
                              data-debug-id={`settings-bridge-uninstall-btn-${id}`}
                              title={online ? 'Uninstall the bridge on that machine and wipe its secrets' : 'The bridge is offline: revoke it on the Hub'}
                              onClick={() => setUninstallConfirmId(id)}
                            >
                              {online ? 'Uninstall' : 'Revoke'}
                            </Button>
                          ) : null}
                        </>
                      )}
                    </div>
                    <section className="space-y-3 border-t border-subtle pt-4" aria-label="Bridge defaults">
                      <Text as="h2" role="heading">Configuration</Text>
                      <div className="grid gap-4 sm:grid-cols-2">
                        <FormField label="Default provider"><Select value="" onChange={() => {}} disabled aria-label="Default provider"><option value="">Not configured</option></Select></FormField>
                        <FormField label="Default model"><Select value="" onChange={() => {}} disabled aria-label="Default model"><option value="">Not configured</option></Select></FormField>
                      </div>
                      <Text role="body-sm" tone="muted">Bridge-wide defaults cannot be saved yet. Configure provider profiles and their runtime settings from Providers.</Text>
                    </section>
                    <BridgeRecentErrorsCard bridgeId={id} />
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>


      {!selectedId ? <section id="global-configuration" data-debug-id="settings-bridges-global-telemetry" className="mt-6 space-y-4 rounded-xl border border-subtle bg-surface p-4" aria-labelledby="global-configuration-title">
        <Text as="h2" role="heading" id="global-configuration-title">Global Configuration</Text>
        <div className="flex items-center justify-between gap-4">
          <div className="min-w-0">
            <label htmlFor="settings-global-telemetry" className="text-sm font-medium text-primary">Enable telemetry</label>
            <p id="settings-global-telemetry-help" className="mt-1 text-xs text-muted">Applies to bridges using the global default. Individual bridge overrides remain in effect.</p>
          </div>
          <Toggle id="settings-global-telemetry" aria-label="Enable telemetry" aria-describedby="settings-global-telemetry-help" data-debug-id="settings-global-telemetry-toggle"
            disabled={!globalTelemetryData || globalTelemetryQuery.isError || globalTelemetrySave.isLoading}
            checked={globalTelemetryData?.enabled ?? false} onChange={(checked) => void handleToggleGlobalTelemetry(checked)} />
        </div>
        {globalTelemetryQuery.isError ? <p role="alert" className="text-sm text-danger">Unable to load global telemetry settings.</p> : null}
      </section> : null}

      {/* Update Bridge Modal */}
      {updateModalBridge ? (
        <Modal
          open
          onOpenChange={(next) => { if (!next && !updateBusy) setUpdateModalBridge(null); }}
          title={`Update: ${updateModalBridge?.label || updateModalBridge?.machine_hostname || updateModalBridge?.hostname || updateModalBridge?.bridge_id || 'Bridge'}`}
          size="md"
          data-debug-id="settings-bridge-update-modal"
        >
          <ModalBody className="space-y-4">
            <BridgeOperationRail label="Bridge update" debugId="settings-remote-update-rail" items={[
              { id: 'review', label: 'Review', state: updateBusy ? 'done' : 'current' },
              { id: 'update', label: 'Update', state: updateBusy ? 'current' : 'todo' },
              { id: 'result', label: 'Result', state: 'todo' },
            ]} />
            <div className="flex flex-col gap-2 rounded-xl border border-subtle bg-surface-raised/40 p-3 text-xs">
              <div className="flex items-center justify-between">
                <span className="text-muted">Current Version:</span>
                <span className="font-mono text-primary" data-debug-id="settings-bridge-modal-current-version">
                  {updateModalBridge.version ? `v${updateModalBridge.version}` : 'unknown'}
                  {updateModalBridge.commit_sha ? ` (${updateModalBridge.commit_sha.slice(0, 8)})` : ''}
                </span>
              </div>
              <div className="flex items-center justify-between">
                <span className="text-muted">Target Version:</span>
                <span className="font-mono text-accent font-semibold" data-debug-id="settings-bridge-modal-target-version">
                  {updateModalBridge.latest_version ? `v${updateModalBridge.latest_version}` : 'latest'}
                  {updateModalBridge.latest_commit_sha ? ` (${updateModalBridge.latest_commit_sha.slice(0, 8)})` : ''}
                </span>
              </div>
            </div>

            {(updateModalBridge.active_instance_count ?? updateModalBridge.instance_count ?? 0) > 0 ? (
              <div data-debug-id="settings-bridge-update-warning" className="rounded-xl border border-warning/30 bg-warning-soft p-3 text-xs text-warning">
                <div className="flex items-center gap-1.5 font-semibold text-warning">
                  <Icon name="alert" size="sm" />
                  <span>Active Agent Tasks Running</span>
                </div>
                <p className="mt-1 text-primary">
                  {(updateModalBridge.active_instance_count ?? updateModalBridge.instance_count ?? 0)} agent task{((updateModalBridge.active_instance_count ?? updateModalBridge.instance_count ?? 0) === 1 ? ' is' : 's are')} currently running on this machine. Updating now will wait up to {updateDrainTimeout}s for tasks to complete, or force an immediate restart.
                </p>
                <div className="mt-3 space-y-2 text-primary">
                  <label className="flex items-center gap-2 cursor-pointer">
                    <input
                      type="radio"
                      name="update_strategy"
                      checked={!updateForce}
                      onChange={() => setUpdateForce(false)}
                      data-debug-id="settings-bridge-update-drain-option"
                      className="text-accent"
                    />
                    <span>Wait for tasks to complete (graceful drain, 60s timeout)</span>
                  </label>
                  <label className="flex items-center gap-2 cursor-pointer">
                    <input
                      type="radio"
                      name="update_strategy"
                      checked={updateForce}
                      onChange={() => setUpdateForce(true)}
                      data-debug-id="settings-bridge-update-force-option"
                      className="text-accent"
                    />
                    <span>Force immediate update (terminate active tasks now)</span>
                  </label>
                </div>
              </div>
            ) : (
              <div className="text-xs text-muted">
                This will stage the latest update bundle on the remote bridge, verify its cryptographic checksum and binary compatibility, and perform an in-situ restart with automated health-checked rollback.
              </div>
            )}

            <label className="flex items-start gap-2 text-sm text-primary">
              <input
                type="checkbox"
                data-debug-id="settings-bridge-update-extensions"
                checked={updateExtensions}
                disabled={updateBusy}
                onChange={(event) => setUpdateExtensions(event.target.checked)}
              />
              <span>
                Also update extensions
                <span className="block text-xs text-muted">Update installed, enabled provider extensions after the bridge reconnects.</span>
              </span>
            </label>

            {updateError ? (
              <div data-debug-id="settings-bridge-update-error" className="rounded-xl border border-danger/30 bg-danger-soft p-2.5 text-xs text-danger">
                {updateError}
              </div>
            ) : null}
          </ModalBody>
          <ModalFooter>
            <Button
              variant="secondary"
              data-debug-id="settings-bridge-update-cancel"
              onClick={() => setUpdateModalBridge(null)}
              disabled={updateBusy}
            >
              Cancel
            </Button>
            <Button
              variant="primary"
              loading={updateBusy}
              data-debug-id="settings-bridge-update-confirm"
              onClick={() => void handleConfirmUpdate()}
            >
              {updateForce ? 'Force' : 'Update'}
            </Button>
          </ModalFooter>
        </Modal>
      ) : null}

      </div>
  );
  return onHeadingChange ? content : <PageShell title={title} description={description}>{content}</PageShell>;
}

// Provider status is per bridge (GET /bridges/{id}/provider-status), fetched for the
// rows this panel shows. The badge reads the cached provider status for each bridge.
function BridgeNoProvidersBadge({ bridge, id }: { bridge: Bridge; id: string }) {
  const { capabilities, loaded } = useBridgeProviderStatus(bridge);
  if (!loaded || capabilities.length > 0) return null;
  return (
    <a
      href={`#/settings/providers/${encodeURIComponent(id)}`}
      data-debug-id={`settings-bridge-no-providers-${id}`}
      className="inline-flex items-center gap-1 rounded-full border border-subtle bg-surface-raised/40 px-2 py-0.5 text-[10px] text-muted hover:border-accent hover:text-accent transition-colors whitespace-nowrap"
    >
      no providers configured
    </a>
  );
}
