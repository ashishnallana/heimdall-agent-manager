import { Suspense, lazy, useEffect, useRef, useState } from 'react';
import { Button, Modal, ModalBody, ModalFooter, Spinner, StatusPill } from '@ui';
import { type ProviderSetupResponse, type ProviderTestRunResponse, providerSetupApi } from './providerSetupApi';

// xterm stays out of the entry chunk until the test-run terminal mounts.
const AgentPaneComposerPanel = lazy(() => import('../chat/AgentPaneComposerPanel'));

export interface ProviderTestTarget { profileId?: string; provider: string; providerLabel: string; modelId: string; modelLabel: string; binaryPath: string }
export interface ProviderTestRunModalProps { setup: ProviderSetupResponse; target: ProviderTestTarget; onClose: () => void }

export function ProviderTestRunModal({ setup, target, onClose }: ProviderTestRunModalProps) {
  const [run, setRun] = useState<ProviderTestRunResponse | null>(null);
  const [error, setError] = useState('');
  const startRequestRef = useRef<{ key: string; promise: Promise<ProviderTestRunResponse> } | null>(null);

  useEffect(() => {
    let cancelled = false;
    const key = `${setup.bridge.bridge_id}\u0000${target.provider}\u0000${target.profileId || target.provider}\u0000${target.modelId}`;
    if (!startRequestRef.current || startRequestRef.current.key !== key) {
      startRequestRef.current = {
        key,
        promise: providerSetupApi.startTestRun(setup, target.provider, target.modelId, target.profileId),
      };
    }
    // React Strict Mode deliberately replays effects in development. Reuse the
    // same in-flight request so that replay cannot orphan run #1 and have run #2
    // rejected by the bridge-level concurrency limit.
    void startRequestRef.current.promise.then(
      (response) => { if (!cancelled) setRun(response); },
      (reason) => { if (!cancelled) setError(String(reason?.message || reason)); },
    );
    return () => { cancelled = true; };
  }, [setup.bridge.bridge_id, target.modelId, target.provider, target.profileId]);

  useEffect(() => {
    if (!run || ['stopped', 'failed', 'cancelled', 'expired'].includes(run.state)) return;
    const timer = window.setInterval(() => {
      void providerSetupApi.getTestRun(run.run_id).then(setRun, (reason) => setError(String(reason?.message || reason)));
    }, 750);
    return () => window.clearInterval(timer);
  }, [run?.run_id, run?.state]);

  async function validateAndStop() {
    if (!run || run.state !== 'awaiting_validation') return;
    setRun({ ...run, state: 'stopping' });
    try { setRun(await providerSetupApi.validateTestRun(run.run_id)); }
    catch (reason: any) { setError(String(reason?.message || reason)); }
  }

  async function cancelAndClose() {
    if (run && !['stopped', 'failed', 'cancelled', 'expired'].includes(run.state)) {
      try { await providerSetupApi.cancelTestRun(run.run_id); } catch { /* TTL cleanup remains */ }
    }
    onClose();
  }

  const state = run?.state || 'starting';
  return (
    <Modal open onOpenChange={(next) => { if (!next) void cancelAndClose(); }} title={`Test ${target.providerLabel} · ${target.modelLabel}`} size="lg" data-debug-id="provider-test-run-modal">
      <ModalBody className="space-y-4">
        <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-subtle bg-surface-raised/40 p-3">
          <div><div className="text-sm font-medium text-primary">Ephemeral agent run</div><div className="mt-0.5 text-xs text-muted">{run?.agent_instance_id || 'Allocating instance…'}</div></div>
          {state === 'starting' || state === 'detecting' ? <StatusPill tone="warning"><span className="inline-flex items-center gap-1.5"><Spinner size="sm" /> Detecting…</span></StatusPill>
            : state === 'awaiting_validation' ? <StatusPill tone="success">start-success received</StatusPill>
            : state === 'stopping' ? <StatusPill tone="warning">Stopping…</StatusPill>
            : state === 'stopped' ? <StatusPill tone="neutral">Stopped</StatusPill>
            : <StatusPill tone="danger">{state}</StatusPill>}
        </div>
        <p className="text-sm text-muted" data-debug-id="provider-test-input-help">
          Click the terminal to type, sign in, or configure this profile. Input is available when your plan permits terminal input and the bridge vault is unlocked. Configuration changes belong to this profile’s runtime directory.
        </p>
        {run?.agent_instance_id ? (
          <div data-debug-id="provider-test-run-output" className="h-80 overflow-hidden rounded-xl border border-subtle bg-black">
            <Suspense fallback={null}>
              <AgentPaneComposerPanel agentInstanceId={run.agent_instance_id} isExpanded isActiveTab runtimeStatus={state === 'detecting' || state === 'awaiting_validation' ? 'running' : state} hideHeader className="h-full" />
            </Suspense>
          </div>
        ) : <div className="flex h-80 items-center justify-center rounded-xl border border-subtle bg-black text-sm text-muted"><Spinner size="sm" />&nbsp; Waiting for bridge…</div>}
        {state === 'awaiting_validation' ? <div data-debug-id="provider-test-awaiting-validation" className="rounded-xl border border-success/30 bg-success-soft p-3 text-sm text-primary">The agent called <code className="font-mono text-success">start-success</code>. Inspect the live terminal, then validate the run. It remains alive until you do.</div> : null}
        {state === 'stopped' ? <div data-debug-id="provider-test-stopped" className="rounded-xl border border-subtle bg-surface-raised/40 p-3 text-sm text-muted">Validation was session-only. No result was persisted.</div> : null}
        {error ? <div role="alert" className="rounded-xl border border-danger/30 bg-danger-soft p-3 text-sm text-danger">{error}</div> : null}
      </ModalBody>
      <ModalFooter>
        {state === 'awaiting_validation' ? <Button variant="primary" data-debug-id="provider-test-validate-btn" onClick={() => void validateAndStop()}>Mark as validated</Button>
          : state === 'stopped' || state === 'failed' || state === 'cancelled' || state === 'expired' || error ? <Button variant="primary" data-debug-id="provider-test-done-btn" onClick={() => void cancelAndClose()}>Done</Button>
          : <><Button variant="secondary" data-debug-id="provider-test-cancel-btn" onClick={() => void cancelAndClose()}>Cancel</Button><Button variant="primary" data-debug-id="provider-test-waiting-btn" disabled>{state === 'stopping' ? 'Stopping instance…' : 'Waiting for start-success…'}</Button></>}
      </ModalFooter>
    </Modal>
  );
}

export default ProviderTestRunModal;
