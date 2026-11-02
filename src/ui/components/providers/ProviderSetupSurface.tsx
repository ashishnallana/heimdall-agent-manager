import { useDispatch } from 'react-redux';
import { heimdallApi } from '../../api/heimdallApi';
import { modelCatalogSummary } from './modelCatalogStatus';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Button, Icon, Spinner, StatusPill } from '@ui';
import {
  type BridgeProviderStatus,
  type ProviderSetupResponse,
  providerSetupApi,
} from './providerSetupApi';
import ProviderTestRunModal, { type ProviderTestTarget } from './ProviderTestRunModal';
import { ProviderExtensionBadge, ProviderExtensionPill } from '../extension/ExtensionBadges';
import ProviderExtensionInstallAction from '../extension/ProviderExtensionInstallAction';
import {
  DISCOVERY_RETRY_MS,
  DISCOVERY_RETRY_TIMEOUT_MS,
  bridgeStatusPill,
  checkedProviderCount,
  defaultProviderSelection,
  enableButtonLabel,
  isRetriableDiscoveryError,
  modelCountLabel,
  notFoundSummary,
  presentProviders,
  providerEnableChanges,
  providerStatus,
} from './providerSummaryModel';

export interface ProviderSetupSurfaceProps {
  bridgeId?: string;
  mode: 'enrollment' | 'settings';
  /**
   * 'full' (default): one card per provider whose Enable toggle saves at once.
   * 'compact' (enrollment only, REQ-ENR-3/4): one short row per detected provider with
   * a checkbox defaulted from what was found; the primary button saves the changes.
   */
  variant?: 'full' | 'compact';
  onApply?: () => void;
  /**
   * Compact only: list each provider that was not found as its own row with an
   * Install button. Installing provider CLIs from Ninjy is not supported yet, so the
   * button is shown disabled (the first-run setup wizard).
   */
  missingAsRows?: boolean;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export function ProviderSetupSurface({ bridgeId, mode, variant = 'full', onApply, missingAsRows = false }: ProviderSetupSurfaceProps) {
  const dispatch = useDispatch();
  const activeBridge = useRef(bridgeId);
  activeBridge.current = bridgeId;
  const invalidate = () => dispatch(heimdallApi.util.invalidateTags([{ type: 'BridgeProviders', id: bridgeId }]));
  const [payload, setPayload] = useState<ProviderSetupResponse | null>(null);
  const [loadError, setLoadError] = useState('');
  const [busy, setBusy] = useState('');
  const [notice, setNotice] = useState('');
  const [testTarget, setTestTarget] = useState<ProviderTestTarget | null>(null);
  // Provider cards start collapsed; the header shows status and the Enable toggle,
  // and a provider is expanded only to look at or test its models.
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});
  const autoScannedBridge = useRef('');
  const mounted = useRef(true);
  // Compact variant: the desired enable state per present provider, seeded from the
  // discovery result, and the error of each PUT that failed.
  const [selection, setSelection] = useState<Record<string, boolean> | null>(null);
  const [rowErrors, setRowErrors] = useState<Record<string, string>>({});
  const [discoveryFailed, setDiscoveryFailed] = useState(false);
  const [modelRefreshFailed, setModelRefreshFailed] = useState(false);

  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);

  useEffect(() => {
    let cancelled = false;
    setLoadError('');
    setPayload(null);
    setSelection(null);
    setExpanded({});
    setBusy('');
    setNotice('');
    setDiscoveryFailed(false);
    setModelRefreshFailed(false);
    if (!bridgeId) {
      setLoadError('No bridge was named, so there are no providers to set up.');
      return;
    }
    void providerSetupApi.get(bridgeId).then(
      (response) => { if (!cancelled) setPayload(response); },
      (error) => { if (!cancelled) setLoadError(String(error?.message || error)); },
    );
    return () => { cancelled = true; };
  }, [bridgeId]);

  const refreshAfterExtensionInstall = useCallback(() => {
    if (!bridgeId) return;
    void providerSetupApi.get(bridgeId).then(
      (response) => { if (mounted.current && activeBridge.current === bridgeId) setPayload(response); },
      () => { if (mounted.current && activeBridge.current === bridgeId) setNotice('Could not refresh provider details after installation. Scan again to retry.'); },
    );
  }, [bridgeId]);

  const enabledProviders = useMemo(() => {
    if (!payload) return 0;
    return payload.providers.filter((provider) => provider.enabled).length;
  }, [payload]);

  // Enrollment mode retries while the hub still answers bridge_offline: a freshly
  // enrolled bridge may not have its runtime socket up yet (REQ-ENR-3).
  async function rediscover(fetchModels = true) {
    if (!payload || payload.bridge.bridge_id !== bridgeId) return;
    const requestedBridge = payload.bridge.bridge_id;
    const current = () => mounted.current && activeBridge.current === requestedBridge;
    setBusy('discovery');
    setDiscoveryFailed(false);
    setNotice('Asking this bridge to scan for supported provider CLIs…');
    const deadline = Date.now() + (mode === 'enrollment' ? DISCOVERY_RETRY_TIMEOUT_MS : 0);
    try {
      for (;;) {
        try {
          const next = await providerSetupApi.discover(payload);
          if (!current()) return;
          setPayload(next);
          setSelection(defaultProviderSelection(next.providers));
          setRowErrors({});
          if (fetchModels) {
            setNotice('Fetching models for enabled providers…');
            // Model probes are never part of the binary-detection retry loop.
            try {
              const refreshed = await providerSetupApi.refreshModels(next);
              if (!current()) return;
              setPayload(refreshed);
              setNotice('Provider and model refresh completed.');
            } catch (error: any) {
              if (!current()) return;
              setNotice(String(error?.message || error));
            }
          } else setNotice(variant === 'compact' ? '' : 'Provider discovery completed on the bridge.');
          invalidate();
          return;
        } catch (error: any) {
          if (!current()) return;
          if (isRetriableDiscoveryError(error) && Date.now() + DISCOVERY_RETRY_MS < deadline) {
            setNotice('Waiting for the bridge to come online before scanning…');
            await sleep(DISCOVERY_RETRY_MS);
            if (!current()) return;
            continue;
          }
          setDiscoveryFailed(true);
          setNotice(String(error?.message || error));
          return;
        }
      }
    } finally {
      if (current()) setBusy('');
    }
  }

  // Compact variant (REQ-ENR-4): send only the changed enable states, each on its own,
  // so one failing PUT shows on its row without stopping the others.
  async function applySelection() {
    if (!payload || !selection) return;
    setBusy('apply');
    setModelRefreshFailed(false);
    setNotice('');
    const changes = providerEnableChanges(payload.providers, selection);
    const results = await Promise.allSettled(
      changes.map((change) => providerSetupApi.setEnabled(payload, change.provider, change.enabled)),
    );
    if (!mounted.current || activeBridge.current !== payload.bridge.bridge_id) return;
    const errors: Record<string, string> = {};
    const saved = new Map<string, boolean>();
    results.forEach((result, index) => {
      const change = changes[index];
      if (result.status === 'fulfilled') saved.set(change.provider, change.enabled);
      else errors[change.provider] = String((result.reason as Error)?.message || result.reason);
    });
    const updated = {
      ...payload,
      providers: payload.providers.map((entry) => saved.has(entry.provider) ? { ...entry, enabled: Boolean(saved.get(entry.provider)) } : entry),
    };
    setPayload(updated);
    setRowErrors(errors);
    setBusy('');
    invalidate();
    if (Object.keys(errors).length === 0) {
      // The button explicitly includes model refresh; ordinary Enable toggles do not.
      if (checkedProviderCount(updated.providers, selection) > 0) {
        setBusy('apply');
        try {
          const refreshed = await providerSetupApi.refreshModels(updated);
          if (!mounted.current || activeBridge.current !== updated.bridge.bridge_id) return;
          setPayload(refreshed);
        } catch (error: any) {
          if (!mounted.current || activeBridge.current !== updated.bridge.bridge_id) return;
          setModelRefreshFailed(true);
          setNotice(String(error?.message || error));
          setBusy('');
          invalidate();
          return;
        }
        setBusy('');
      }
      invalidate();
      onApply?.();
    }
    else setNotice('Some providers could not be updated. Try again, or continue and fix them later in Settings → Providers.');
  }

  // A freshly enrolled bridge has never reported its CLIs, so scan once on
  // arrival instead of making the user click "Scan again" first.
  useEffect(() => {
    if ((mode !== 'enrollment' && variant !== 'compact') || !payload || busy !== '') return;
    const id = payload.bridge.bridge_id;
    if (autoScannedBridge.current === id) return;
    autoScannedBridge.current = id;
    void rediscover(false);
  }, [mode, variant, payload, busy]);

  async function setProviderEnabled(provider: BridgeProviderStatus, enabled: boolean) {
    if (!payload) return;
    const key = `provider:${provider.provider}`;
    setBusy(key);
    setNotice('');
    try {
      const updated = await providerSetupApi.setEnabled(payload, provider.provider, enabled);
      if (!mounted.current || activeBridge.current !== updated.bridge.bridge_id) return;
      setPayload(updated);
      invalidate();
      setNotice(`${provider.display_name} ${enabled ? 'enabled' : 'disabled'} on this bridge.${enabled ? ' Use Refresh to fetch its model list.' : ''}`);
    } catch (error: any) {
      if (mounted.current && activeBridge.current === payload.bridge.bridge_id) setNotice(String(error?.message || error));
    } finally {
      if (mounted.current && activeBridge.current === payload.bridge.bridge_id) setBusy('');
    }
  }

  if (!payload && !loadError) {
    return (
      <div data-debug-id="provider-setup-loading" className="flex min-h-64 items-center justify-center gap-3 text-sm text-muted">
        <Spinner size="sm" /> Loading provider catalog…
      </div>
    );
  }

  if (!payload) {
    return <div role="alert" data-debug-id="provider-setup-load-error" className="rounded-xl border border-danger/30 bg-danger-soft p-4 text-sm text-danger">{loadError}</div>;
  }

  const { bridge, providers, discovery } = payload;
  const bridgePill = bridgeStatusPill(bridge.status);

  if (variant === 'compact') {
    const present = presentProviders(providers);
    const notFound = notFoundSummary(providers);
    const scanning = busy === 'discovery' || (discovery.state !== 'complete' && !discoveryFailed);
    const checked = selection ? checkedProviderCount(providers, selection) : 0;
    const hasRowErrors = Object.keys(rowErrors).length > 0;
    return (
      <div data-debug-id="provider-summary" className="w-full">
        <div className="flex flex-wrap items-center gap-2">
          <h2 className="text-base font-semibold text-primary">
            {scanning ? `Detecting providers on ${bridge.label}…` : `These providers will be enabled on ${bridge.label}`}
          </h2>
          <StatusPill tone={bridgePill.tone}>{bridgePill.label}</StatusPill>
        </div>

        {notice ? (
          <p role="status" data-debug-id="provider-summary-notice" className="mt-2 text-sm text-muted">{notice}</p>
        ) : null}

        {scanning ? (
          <div data-debug-id="provider-summary-scanning" className="mt-3 flex items-center gap-2 text-sm text-muted">
            <Spinner size="sm" /> Scanning for installed provider CLIs…
          </div>
        ) : discoveryFailed ? (
          <div className="mt-3">
            <Button variant="secondary" data-debug-id="provider-setup-discover-btn" onClick={() => void rediscover(false)} leading={<Icon name="refresh" size={16} />}>
              Scan again
            </Button>
          </div>
        ) : (
          <>
            <ul data-debug-id="provider-summary-list" className="mt-3 divide-y divide-subtle rounded-xl border border-subtle">
              {present.length === 0 ? (
                <li className="px-3 py-2 text-sm text-muted">No supported provider CLI was found on this bridge.</li>
              ) : present.map((provider) => (
                <li key={provider.provider} data-debug-id={`provider-summary-row-${provider.provider}`} className="px-3 py-2">
                  <label className="flex cursor-pointer items-center gap-3">
                    <input
                      data-debug-id={`provider-summary-enable-${provider.provider}`}
                      type="checkbox"
                      checked={Boolean(selection?.[provider.provider])}
                      disabled={busy !== ''}
                      onChange={(event) => {
                        const value = event.target.checked;
                        setSelection((prev) => ({ ...(prev || {}), [provider.provider]: value }));
                      }}
                    />
                    <img src={provider.icon_url} alt="" className="h-6 w-6 shrink-0 rounded-md" />
                    <span className="min-w-0 flex-1 truncate text-sm font-medium text-primary">{provider.display_name}</span>
                    <ProviderExtensionPill providerName={provider.provider} extension={provider.extension} />
                    <span data-debug-id={`provider-summary-models-${provider.provider}`} className="shrink-0 text-xs text-muted">{modelCountLabel(provider.models.length)}</span>
                  </label>
                  {rowErrors[provider.provider] ? (
                    <p role="alert" data-debug-id={`provider-summary-error-${provider.provider}`} className="mt-1 pl-7 text-xs text-danger">{rowErrors[provider.provider]}</p>
                  ) : null}
                </li>
              ))}
            </ul>
            {missingAsRows && notFound ? (
              <div data-debug-id="provider-summary-missing" className="mt-2">
                <ul className="divide-y divide-subtle rounded-xl border border-subtle">
                  {providers.filter((provider) => provider.state !== 'present').map((provider) => (
                    <li key={provider.provider} data-debug-id={`provider-summary-missing-${provider.provider}`} className="flex items-center gap-3 px-3 py-2">
                      <img src={provider.icon_url} alt="" className="h-6 w-6 shrink-0 rounded-md opacity-60" />
                      <span className="min-w-0 flex-1 truncate text-sm text-muted">{provider.display_name || provider.provider}</span>
                      <StatusPill tone="neutral">Not found</StatusPill>
                      <Button size="sm" variant="secondary" disabled title="Installing agents from Ninjy is coming soon" data-debug-id={`provider-summary-install-btn-${provider.provider}`}>Install</Button>
                    </li>
                  ))}
                </ul>
                <p className="mt-1 text-xs text-faint">Installing agents from Ninjy is coming soon. Install one yourself, then scan again.</p>
              </div>
            ) : notFound ? (
              <details data-debug-id="provider-summary-not-found" className="mt-2 text-xs text-faint">
                <summary className="cursor-pointer">{notFound}</summary>
                <p className="mt-1">Install a provider CLI in the bridge service PATH, then scan again from Settings → Providers.</p>
              </details>
            ) : null}
            <div className="mt-4 flex flex-wrap justify-end gap-2">
              {hasRowErrors || modelRefreshFailed ? (
                <Button variant="ghost" data-debug-id="provider-summary-continue-btn" disabled={busy !== ''} onClick={onApply}>Continue anyway</Button>
              ) : null}
              <Button variant="primary" data-debug-id="provider-setup-apply-btn" loading={busy === 'apply'} disabled={busy !== '' || !selection} onClick={() => void applySelection()}>
                {enableButtonLabel(checked)}{checked > 0 ? ' and refresh models' : ''}
              </Button>
            </div>
          </>
        )}
      </div>
    );
  }

  return (
    <div data-debug-id={`provider-setup-${mode}`} className="w-full">
      <div className="flex flex-col gap-4 border-b border-subtle pb-5 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="text-xl font-semibold text-primary">
              {mode === 'enrollment' ? 'Choose providers for this bridge' : bridge.label}
            </h1>
            <StatusPill tone={bridgePill.tone}>{bridgePill.label}</StatusPill>
          </div>
          <p className="mt-1 text-sm text-muted">
            {bridge.label} · {bridge.machine_hostname} · {bridge.status}
          </p>
          <p className="mt-2 max-w-2xl text-sm leading-6 text-muted">
            Ninjy asks the bridge to detect installed CLIs. Enable only the providers and models you want agents to use, then test those exact combinations.
          </p>
        </div>
        <Button
          variant="secondary"
          className="whitespace-nowrap"
          data-debug-id="provider-setup-discover-btn"
          disabled={busy !== ''}
          onClick={() => void rediscover()}
          leading={busy === 'discovery' ? <Spinner size="sm" /> : <Icon name="refresh" size={16} />}
        >
          {busy === 'discovery' ? 'Refreshing…' : 'Refresh providers and models'}
        </Button>
      </div>

      <div className="mt-4 flex flex-wrap items-center gap-2 text-xs text-muted">
        <StatusPill tone={discovery.state === 'complete' ? 'success' : 'neutral'}>{discovery.state}</StatusPill>
        <span>{providers.filter((provider) => provider.state === 'present').length} of {providers.length} providers detected</span>
        <span>·</span>
        <span>{enabledProviders} providers enabled</span>
      </div>

      {notice ? (
        <div role="status" data-debug-id="provider-setup-notice" className="mt-4 rounded-xl border border-info/30 bg-info-soft px-4 py-3 text-sm text-info">
          {notice}
        </div>
      ) : null}

      <div className="mt-5 space-y-3" data-debug-id="provider-setup-list">
        {providers.map((provider) => {
          const status = providerStatus(provider);
          const available = provider.state === 'present';
          const providerBusy = busy === `provider:${provider.provider}`;
          const isExpanded = Boolean(expanded[provider.provider]);
          const detailsId = `provider-setup-details-${provider.provider}`;
          const summary = available ? modelCountLabel(provider.models.length) : 'Not installed';
          return (
            <section key={provider.provider} data-debug-id={`provider-setup-card-${provider.provider}`} className={`overflow-hidden rounded-2xl border bg-surface ${provider.enabled ? 'border-accent/50 shadow-sm' : 'border-subtle'}`}>
              <div className="flex flex-col gap-4 p-4 sm:flex-row sm:items-center sm:justify-between">
                <button
                  type="button"
                  data-debug-id={`provider-setup-toggle-${provider.provider}`}
                  aria-expanded={isExpanded}
                  aria-controls={detailsId}
                  onClick={() => setExpanded((prev) => ({ ...prev, [provider.provider]: !isExpanded }))}
                  className="flex min-w-0 flex-1 items-center gap-3 text-left"
                >
                  <Icon name={isExpanded ? 'chevron-down' : 'chevron-right'} size={16} className="shrink-0 text-muted" />
                  <img src={provider.icon_url} alt="" className="h-11 w-11 shrink-0 rounded-xl" />
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <h2 className="font-semibold text-primary">{provider.display_name}</h2>
                      <StatusPill tone={status.tone}>{status.label}</StatusPill>
                      {available ? <ProviderExtensionPill providerName={provider.provider} extension={provider.extension} /> : null}
                    </div>
                    <p className="mt-1 truncate text-xs text-muted">
                      {available ? `${provider.binary_path} · ${provider.version_text}` : 'No supported executable found in the bridge service PATH'}
                    </p>
                    <p data-debug-id={`provider-setup-summary-${provider.provider}`} className="mt-0.5 text-xs text-faint">{summary}</p>
                  </div>
                </button>

                <div className="flex shrink-0 items-center gap-2">
                  <label data-debug-id={`provider-setup-enable-label-${provider.provider}`} className={`flex min-h-10 items-center gap-2 rounded-xl border px-3 text-sm font-medium ${available ? 'cursor-pointer border-subtle text-primary' : 'cursor-not-allowed border-subtle text-faint'}`}>
                    <input
                      data-debug-id={`provider-setup-enable-${provider.provider}`}
                      type="checkbox"
                      checked={provider.enabled}
                      disabled={!available || providerBusy || busy !== '' && !providerBusy}
                      onChange={(event) => void setProviderEnabled(provider, event.target.checked)}
                    />
                    {providerBusy ? 'Saving…' : 'Enable'}
                  </label>
                </div>
              </div>
              {available ? (
                <ProviderExtensionBadge providerName={provider.provider} extension={provider.extension} className="-mt-2 px-4 pb-3 sm:pl-[4.75rem]" />
              ) : null}

              {/* The Hub sends provider_extension_install to the bridge; setup and
                  update install extensions too, but older bridges and failed
                  installs need this (removed in 6eac97a5, restored). */}
              {available ? (
                <ProviderExtensionInstallAction
                  key={`${bridge.bridge_id}:${provider.provider}`}
                  bridgeId={bridge.bridge_id}
                  provider={provider.provider}
                  extension={provider.extension}
                  online={bridge.status === 'online'}
                  disabled={busy !== ''}
                  onComplete={refreshAfterExtensionInstall}
                  onRetryDiscovery={() => rediscover(false)}
                />
              ) : null}

              {!isExpanded ? null : available ? (
                <div id={detailsId} className="border-t border-subtle bg-surface-raised/30 px-4 py-3">
                  <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">Models</div>
                  <p data-debug-id={`provider-model-catalog-status-${provider.provider}`} className="mb-3 text-xs text-muted">{modelCatalogSummary(provider)}</p>
                  {provider.models.length === 0 ? <p className="text-sm text-muted">No models were returned. Refresh after checking your provider account.</p> : null}
                  <div className="space-y-2">
                    {provider.models.map((model) => {
                      const canTest = provider.enabled && busy === '';
                      return (
                        <div key={model.model_id} data-debug-id={`provider-model-row-${provider.provider}-${model.model_id}`} className="flex flex-col gap-3 rounded-xl border border-subtle bg-surface px-3 py-3 sm:flex-row sm:items-center sm:justify-between">
                          <div className="flex min-w-0 items-start gap-3">
                            <span className="min-w-0">
                              <span className="block text-sm font-medium text-primary">{model.label}</span>
                              <span className="block text-xs text-muted">{model.model_id}</span>
                            </span>
                          </div>
                          <div className="flex shrink-0 items-center gap-2 pl-7 sm:pl-0">
                            <Button
                              size="sm"
                              variant="secondary"
                              data-debug-id={`provider-model-test-${provider.provider}-${model.model_id}`}
                              disabled={!canTest}
                              onClick={() => setTestTarget({
                                provider: provider.provider,
                                providerLabel: provider.display_name,
                                modelId: model.model_id,
                                modelLabel: model.label,
                                binaryPath: provider.binary_path,
                              })}
                            >
                              Test
                            </Button>
                          </div>
                        </div>
                      );
                    })}
                  </div>
                </div>
              ) : (
                <div id={detailsId} className="border-t border-subtle bg-surface-raised/30 px-4 py-3 text-sm text-muted">
                  Install this provider CLI in the bridge service PATH, then scan again.
                </div>
              )}
            </section>
          );
        })}
      </div>

      {mode === 'enrollment' ? (
        <div className="mt-6 flex items-center justify-end border-t border-subtle pt-5">
          <Button variant="primary" data-debug-id="provider-setup-apply-btn" disabled={busy !== ''} onClick={onApply}>Apply</Button>
        </div>
      ) : null}

      {testTarget ? (
        <ProviderTestRunModal setup={payload} target={testTarget} onClose={() => setTestTarget(null)} />
      ) : null}
    </div>
  );
}

export default ProviderSetupSurface;
