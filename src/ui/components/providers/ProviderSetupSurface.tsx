import { useEffect, useMemo, useRef, useState } from 'react';
import { Button, Icon, Spinner, StatusPill } from '@ui';
import {
  type BridgeProviderStatus,
  type ProviderSetupResponse,
  providerSetupApi,
} from './providerSetupApi';
import ProviderTestRunModal, { type ProviderTestTarget } from './ProviderTestRunModal';

export interface ProviderSetupSurfaceProps {
  bridgeId?: string;
  mode: 'enrollment' | 'settings';
  onApply?: () => void;
}

function providerStatus(provider: BridgeProviderStatus): { label: string; tone: 'success' | 'warning' | 'neutral' | 'danger' } {
  if (provider.state === 'absent') return { label: 'Not detected', tone: 'neutral' };
  if (provider.enabled) return { label: 'Enabled', tone: 'success' };
  return { label: 'Detected', tone: 'neutral' };
}

export function ProviderSetupSurface({ bridgeId, mode, onApply }: ProviderSetupSurfaceProps) {
  const [payload, setPayload] = useState<ProviderSetupResponse | null>(null);
  const [loadError, setLoadError] = useState('');
  const [busy, setBusy] = useState('');
  const [notice, setNotice] = useState('');
  const [testTarget, setTestTarget] = useState<ProviderTestTarget | null>(null);
  // Provider cards start collapsed; the header shows status and the Enable toggle,
  // and a provider is expanded only to look at or test its models.
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});
  const autoScannedBridge = useRef('');

  useEffect(() => {
    let cancelled = false;
    setLoadError('');
    void providerSetupApi.get(bridgeId || '').then(
      (response) => { if (!cancelled) setPayload(response); },
      (error) => { if (!cancelled) setLoadError(String(error?.message || error)); },
    );
    return () => { cancelled = true; };
  }, [bridgeId]);

  const enabledProviders = useMemo(() => {
    if (!payload) return 0;
    return payload.providers.filter((provider) => provider.enabled).length;
  }, [payload]);

  async function rediscover() {
    if (!payload) return;
    setBusy('discovery');
    setNotice('Asking this bridge to scan for supported provider CLIs…');
    try {
      setPayload(await providerSetupApi.discover(payload));
      setNotice('Provider discovery completed on the bridge.');
    } catch (error: any) {
      setNotice(String(error?.message || error));
    } finally {
      setBusy('');
    }
  }

  // A freshly enrolled bridge has never reported its CLIs, so scan once on
  // arrival instead of making the user click "Scan again" first.
  useEffect(() => {
    if (mode !== 'enrollment' || !payload || busy !== '') return;
    const id = payload.bridge.bridge_id;
    if (autoScannedBridge.current === id) return;
    autoScannedBridge.current = id;
    void rediscover();
  }, [mode, payload, busy]);

  async function setProviderEnabled(provider: BridgeProviderStatus, enabled: boolean) {
    if (!payload) return;
    const key = `provider:${provider.provider}`;
    setBusy(key);
    setNotice('');
    try {
      setPayload(await providerSetupApi.setEnabled(payload, provider.provider, enabled));
      setNotice(`${provider.display_name} ${enabled ? 'enabled' : 'disabled'} on this bridge.`);
    } catch (error: any) {
      setNotice(String(error?.message || error));
    } finally {
      setBusy('');
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

  return (
    <div data-debug-id={`provider-setup-${mode}`} className="w-full">
      <div className="flex flex-col gap-4 border-b border-subtle pb-5 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="text-xl font-semibold text-primary">
              {mode === 'enrollment' ? 'Choose providers for this bridge' : bridge.label}
            </h1>
            <StatusPill tone="success">{mode === 'enrollment' ? 'Bridge connected' : 'Online'}</StatusPill>
          </div>
          <p className="mt-1 text-sm text-muted">
            {bridge.label} · {bridge.machine_hostname} · {bridge.status}
          </p>
          <p className="mt-2 max-w-2xl text-sm leading-6 text-muted">
            Heimdall asks the bridge to detect installed CLIs. Enable only the providers and models you want agents to use, then test those exact combinations.
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
          {busy === 'discovery' ? 'Scanning…' : 'Scan again'}
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
          const summary = available
            ? `${provider.models.length} ${provider.models.length === 1 ? 'model' : 'models'}`
            : 'Not installed';
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

              {!isExpanded ? null : available ? (
                <div id={detailsId} className="border-t border-subtle bg-surface-raised/30 px-4 py-3">
                  <div className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">Models</div>
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
