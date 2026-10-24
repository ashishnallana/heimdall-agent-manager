import { useEffect, useRef, useState } from 'react';
import { Button, Spinner } from '@ui';
import { apiErrorText } from '../../api/cookieFetch';
import {
  useGetProviderExtensionInstallQuery,
  useInstallProviderExtensionMutation,
  useListBridgeProvidersQuery,
} from '../../api/endpoints/bridgeSupport';
import type { ProviderExtensionStatus } from './extensionBadgeModel';
import {
  type ProviderExtensionCommand,
  extensionInstallLabel,
  extensionInstallProgress,
  isExtensionInstallTerminal,
} from './extensionInstallModel';

interface Props {
  bridgeId: string;
  provider: string;
  extension: ProviderExtensionStatus | null;
  online: boolean;
  disabled?: boolean;
  onComplete: () => void;
  onRetryDiscovery: () => Promise<void>;
}

/** Tracks manual and automatic installs, including commands recovered after navigation. */
export default function ProviderExtensionInstallAction({ bridgeId, provider, extension, online, disabled, onComplete, onRetryDiscovery }: Props) {
  // RTK shares this subscription across every provider card on the bridge.
  const statusQuery = useListBridgeProvidersQuery({ bridgeId }, {
    pollingInterval: 5000,
    skipPollingIfUnfocused: true,
    refetchOnMountOrArgChange: true,
  });
  const latest = (statusQuery.currentData?.extension_commands as ProviderExtensionCommand[] | undefined)
    ?.find((entry) => entry.bridge_id === bridgeId && entry.provider === provider);
  const [submitted, setSubmitted] = useState<ProviderExtensionCommand | null>(null);
  const [requestError, setRequestError] = useState('');
  const [install, installRequest] = useInstallProviderExtensionMutation();
  const inScope = (entry: ProviderExtensionCommand | null | undefined) =>
    entry?.bridge_id === bridgeId && entry.provider === provider ? entry : null;
  const command = inScope(submitted) || latest;
  const [terminalId, setTerminalId] = useState('');
  const commandQuery = useGetProviderExtensionInstallQuery({
    bridgeId, provider, commandId: command?.command_id || '',
  }, {
    skip: !command,
    pollingInterval: command && terminalId !== command.command_id ? 1000 : 0,
    refetchOnMountOrArgChange: true,
    skipPollingIfUnfocused: true,
  });
  const tracked = inScope(commandQuery.currentData) || command;
  const [retrying, setRetrying] = useState(false);
  const active = Boolean(tracked && !isExtensionInstallTerminal(tracked.status));
  const notified = useRef('');
  const label = extensionInstallLabel(provider, extension);

  useEffect(() => {
    if (submitted && latest?.command_id === submitted.command_id) setSubmitted(null);
  }, [submitted, latest]);

  useEffect(() => {
    if (!tracked || !isExtensionInstallTerminal(tracked.status)) return;
    setTerminalId(tracked.command_id);
    if (notified.current === tracked.command_id) return;
    notified.current = tracked.command_id;
    onComplete();
  }, [tracked, onComplete]);

  async function start() {
    setRequestError('');
    try {
      setSubmitted(await install({ bridgeId, provider }).unwrap());
    } catch (error) {
      setRequestError(apiErrorText(error, 'Unable to start extension installation.'));
    }
  }

  async function retryDiscovery() {
    setRetrying(true);
    try {
      await onRetryDiscovery();
    } finally {
      setRetrying(false);
    }
  }

  const canRetryDiscovery = ['claude', 'codex', 'antigravity'].includes(provider) && extension?.state === 'error';
  if (!label && !tracked && !canRetryDiscovery) return null;
  const failed = tracked?.status === 'failed' || tracked?.status === 'cancelled';

  return (
    <div className="space-y-2 px-4 pb-3 sm:pl-[4.75rem]" data-debug-id={`provider-extension-action-${provider}`}>
      {canRetryDiscovery ? (
        <Button
          size="sm"
          variant="secondary"
          data-debug-id={`provider-extension-retry-btn-${provider}`}
          disabled={disabled || !online || active || installRequest.isLoading || retrying}
          onClick={() => void retryDiscovery()}
          leading={retrying ? <Spinner size="sm" /> : undefined}
        >
          {retrying ? 'Checking…' : 'Retry Extension Check'}
        </Button>
      ) : null}
      {label ? (
        <Button
          size="sm"
          variant="secondary"
          data-debug-id={`provider-extension-install-btn-${provider}`}
          disabled={disabled || !online || active || installRequest.isLoading || !statusQuery.currentData}
          onClick={() => void start()}
          leading={active || installRequest.isLoading ? <Spinner size="sm" /> : undefined}
        >
          {active || installRequest.isLoading ? 'Installing…' : label}
        </Button>
      ) : null}
      {!online && (label || canRetryDiscovery) ? <p className="text-xs text-muted">Connect this bridge to check or install extensions.</p> : null}
      {tracked ? (
        <div role={failed ? 'alert' : 'status'} className={failed ? 'text-xs text-danger' : 'text-xs text-muted'}
          data-debug-id={`provider-extension-progress-${provider}`}>
          {extensionInstallProgress(tracked, extension)}
          {active ? (
            <progress className="mt-1 block w-full max-w-xs" max={100}
              value={Math.max(0, Math.min(100, tracked.progress_percent))}
              aria-label="Extension installation progress" />
          ) : null}
        </div>
      ) : null}
      {requestError ? <p role="alert" className="text-xs text-danger">{requestError}</p> : null}
      {statusQuery.isError || commandQuery.isError ? (
        <p role="alert" className="text-xs text-danger">Could not refresh installation status. Retrying…</p>
      ) : null}
    </div>
  );
}
