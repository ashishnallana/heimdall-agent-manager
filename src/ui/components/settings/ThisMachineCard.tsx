import { useCallback, useEffect, useState } from 'react';
import { Button, Icon, Input, Modal, ModalBody, ModalFooter, StatusDot, Text } from '@ui';
import type { Tone } from '@ui';
import {
  type DesktopBridgeConfig,
  type DesktopBridgeEvent,
  type DesktopBridgeManagerApi,
  type DesktopBridgeOperation,
  type DesktopBridgeOperationOptions,
  type DesktopBridgeStatus,
  type WizardModel,
  desktopBridgeStatusLabel,
  initialWizard,
  reduceWizard,
  startWizard,
} from '../../bridge/desktopBridge';

const toneFor: Record<string, Tone> = { success: 'success', warning: 'warning', danger: 'danger', muted: 'neutral' };

const stepIcon: Record<string, string> = {
  pending: '○', running: '◐', recovering: '↻', ok: '✓', skipped: '–', failed: '✕',
};

const operationLabel: Record<DesktopBridgeOperation, string> = {
  setup: 'Setting up this machine',
  update: 'Updating the Bridge',
  reenroll: 'Re-enrolling the Bridge',
  uninstall: 'Uninstalling the Bridge',
};

const operationFailed: Record<DesktopBridgeOperation, string> = {
  setup: 'Setup failed',
  update: 'Update failed',
  reenroll: 'Re-enrollment failed',
  uninstall: 'Uninstall failed',
};

/**
 * REQ-ENR-9/10 (Electron only): "This machine". Not installed → the setup
 * wizard (Download latest → Install → Enroll → Providers → Done) with per-step
 * progress, automatic recovery shown inline, an expandable log, Retry from the
 * failed step once recovery is exhausted, and Cancel (= rollback). Installed →
 * status plus Update / Re-enroll / Uninstall.
 */
export default function ThisMachineCard({ manager, onBridgeId }: { manager: DesktopBridgeManagerApi; onBridgeId?: (bridgeId: string) => void }) {
  const [config, setConfig] = useState<DesktopBridgeConfig | null>(null);
  const [status, setStatus] = useState<DesktopBridgeStatus | null>(null);
  const [operation, setOperation] = useState<DesktopBridgeOperation | ''>('');
  const [wizard, setWizard] = useState<WizardModel>(() => initialWizard());
  const [log, setLog] = useState<string[]>([]);
  const [showLog, setShowLog] = useState(false);
  const [hubDraft, setHubDraft] = useState('');
  const [profile, setProfile] = useState('');
  const [editingHub, setEditingHub] = useState(false);
  const [confirm, setConfirm] = useState<'uninstall' | 'reenroll' | ''>('');
  const [purge, setPurge] = useState(true);
  const [error, setError] = useState('');
  // The last operation started, so Retry repeats exactly that operation.
  const [lastRun, setLastRun] = useState<{ kind: DesktopBridgeOperation; options: DesktopBridgeOperationOptions } | null>(null);

  const target = useCallback(() => ({ hub: config?.hubUrl, profile }), [config?.hubUrl, profile]);

  const refresh = useCallback(async () => {
    try { setStatus(await manager.getStatus(target())); }
    catch (err: any) { setError(String(err?.message || err)); }
  }, [manager, target]);

  useEffect(() => { onBridgeId?.(status?.installed ? String(status.bridge_id || '') : ''); }, [status?.installed, status?.bridge_id, onBridgeId]);

  useEffect(() => {
    void manager.getConfig().then((next) => { setConfig(next); setHubDraft(next.hubUrl); }).catch((err: any) => setError(String(err?.message || err)));
  }, [manager]);

  useEffect(() => {
    if (!config) return;
    void refresh();
    const timer = window.setInterval(() => { if (!operation) void refresh(); }, 15_000);
    return () => window.clearInterval(timer);
  }, [config, refresh, operation]);

  useEffect(() => manager.onEvent((event: DesktopBridgeEvent) => {
    if (event.type === 'output') setLog((lines) => [...lines, event.message].slice(-500));
    if (event.type === 'progress' && event.message) setLog((lines) => [...lines, `[${event.step}] ${event.state}: ${event.message}`].slice(-500));
    if (event.type === 'error') setLog((lines) => [...lines, `ERROR: ${event.message}`].slice(-500));
    setWizard((model) => reduceWizard(model, event));
    if (event.type === 'complete' || event.type === 'error') {
      setOperation('');
      if (event.type === 'complete' && event.status) setStatus(event.status);
      else void refresh();
    }
  }), [manager, refresh]);

  const run = async (kind: DesktopBridgeOperation, options: DesktopBridgeOperationOptions = {}) => {
    setLastRun({ kind, options });
    setError('');
    setLog([]);
    setShowLog(false);
    setOperation(kind);
    setWizard(startWizard());
    const result = await manager.run(kind, target(), options).catch((err: any) => ({ ok: false, error: String(err?.message || err) }));
    // Progress and the final state arrive as events; a refusal (another
    // operation running, invalid Hub URL) arrives only here.
    if (!result.ok && result.error) {
      setError(result.error);
      setOperation('');
    }
  };

  const saveHub = async () => {
    const result = await manager.setHubUrl(hubDraft.trim());
    if (!result.ok) { setError(result.error || 'Invalid Hub URL.'); return; }
    setConfig((current) => (current ? { ...current, hubUrl: result.hubUrl || current.hubUrl } : current));
    setEditingHub(false);
  };

  if (!config) return null;
  if (!config.supported) {
    return (
      <section data-debug-id="settings-this-machine-card" className="mt-4 rounded-xl border border-subtle bg-surface-raised/40 p-4 text-sm text-muted">
        This platform cannot run a Ninjy Bridge.
      </section>
    );
  }

  const label = desktopBridgeStatusLabel(status);
  const installed = Boolean(status?.installed);
  const busy = Boolean(operation) || Boolean(status?.busy);
  const lastKind = lastRun?.kind || 'setup';
  const showWizard = operation === 'setup'
    || (lastKind === 'setup' && (wizard.failedStep || wizard.cancelled))
    || (!installed && lastKind === 'setup' && (wizard.running || wizard.completed));

  return (
    <section data-debug-id="settings-this-machine-card" className="mt-4 rounded-xl border border-subtle bg-surface-raised/40 p-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <Text as="div" role="overline" tone="muted">This machine</Text>
          <div className="mt-1 flex flex-wrap items-center gap-2">
            <StatusDot data-debug-id="settings-this-machine-status" tone={toneFor[label.tone]} label={label.label} />
            <span className="text-sm font-medium text-primary">{label.label}</span>
            {status?.version ? <span data-debug-id="settings-this-machine-version" className="rounded-full border border-subtle px-2 py-0.5 font-mono text-[10px] text-primary">v{String(status.version).replace(/^v/, '')}</span> : null}
          </div>
          <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-caption text-muted">
            {editingHub ? (
              <span className="flex items-center gap-2">
                <Input data-debug-id="settings-this-machine-hub-input" value={hubDraft} onChange={setHubDraft} size="sm" aria-label="Hub URL" />
                <Button size="sm" variant="primary" data-debug-id="settings-this-machine-hub-save" onClick={() => void saveHub()}>Save</Button>
                <Button size="sm" variant="secondary" data-debug-id="settings-this-machine-hub-cancel" onClick={() => { setEditingHub(false); setHubDraft(config.hubUrl); }}>Cancel</Button>
              </span>
            ) : (
              <span>
                Hub: <span data-debug-id="settings-this-machine-hub" className="font-mono text-primary">{config.hubUrl}</span>
                {!busy && !installed ? (
                  <button type="button" data-debug-id="settings-this-machine-hub-edit" className="ml-2 text-accent underline" onClick={() => setEditingHub(true)}>Change</button>
                ) : null}
              </span>
            )}
            {status?.bridge_id ? <span>id: <span className="font-mono text-primary">{status.bridge_id}</span></span> : null}
            {!installed && !busy ? (
              <span className="flex items-center gap-1">
                Profile:
                <Input data-debug-id="settings-this-machine-profile-input" value={profile} onChange={(value) => setProfile(value.toLowerCase())} size="sm" placeholder="default" aria-label="Bridge profile" />
              </span>
            ) : status?.profile ? <span>profile: <span className="font-mono text-primary">{status.profile}</span></span> : null}
          </div>
          {status?.needs_reenrollment ? (
            <p data-debug-id="settings-this-machine-reenroll-hint" className="mt-2 text-xs text-danger">The Hub no longer accepts this Bridge ({status.reenroll_reason || 'revoked'}). Re-enroll it to reconnect.</p>
          ) : null}
        </div>

        <div className="flex flex-wrap gap-1.5 sm:justify-end">
          {!installed ? (
            busy ? null : (
              <Button variant="primary" size="sm" data-debug-id="settings-this-machine-setup-btn" leading={<Icon name="download" size="sm" />} onClick={() => void run('setup')}>
                Set up this machine
              </Button>
            )
          ) : (
            <>
              <Button variant="secondary" size="sm" data-debug-id="settings-this-machine-update-btn" disabled={busy} onClick={() => void run('update')}>Update</Button>
              <Button variant="secondary" size="sm" data-debug-id="settings-this-machine-reenroll-btn" disabled={busy} onClick={() => setConfirm('reenroll')}>Re-enroll</Button>
              <Button variant="danger" size="sm" data-debug-id="settings-this-machine-uninstall-btn" disabled={busy} onClick={() => { setPurge(true); setConfirm('uninstall'); }}>Uninstall</Button>
            </>
          )}
          {busy ? (
            <Button variant="secondary" size="sm" data-debug-id="settings-this-machine-cancel-btn" onClick={() => void manager.cancel()}>Cancel</Button>
          ) : null}
        </div>
      </div>

      {error ? <p role="alert" data-debug-id="settings-this-machine-error" className="mt-3 whitespace-pre-wrap text-xs text-danger">{error}</p> : null}

      {showWizard ? (
        <ol data-debug-id="settings-bridge-wizard" className="mt-4 space-y-2" aria-label="Setup progress">
          <div className="h-1.5 w-full overflow-hidden rounded-full bg-neutral-soft" aria-hidden="true">
            <div data-debug-id="settings-bridge-wizard-progress" className="h-full bg-accent transition-all" style={{ width: `${Math.max(0, Math.min(100, wizard.pct))}%` }} />
          </div>
          {wizard.steps.map((step) => (
            <li key={step.id} data-debug-id={`settings-bridge-wizard-step-${step.id}`} data-state={step.state} className="rounded-lg border border-subtle bg-surface px-3 py-2">
              <div className="flex items-center gap-2 text-sm">
                <span aria-hidden="true" className={`w-4 text-center ${step.state === 'failed' ? 'text-danger' : step.state === 'ok' ? 'text-success' : step.state === 'recovering' ? 'text-warning' : 'text-muted'}`}>{stepIcon[step.state]}</span>
                <span className="font-medium text-primary">{step.label}</span>
                {step.message ? <span className="min-w-0 truncate text-xs text-muted" title={step.message}>{step.message}</span> : null}
              </div>
              {step.recoveries.length ? (
                <ul data-debug-id={`settings-bridge-wizard-recoveries-${step.id}`} className="mt-1 space-y-0.5 pl-6 text-[11px] text-warning">
                  {step.recoveries.map((recovery, index) => <li key={index}>Automatic recovery {index + 1}: {recovery}</li>)}
                </ul>
              ) : null}
              {step.id === 'enroll' && wizard.pairing ? (
                <div data-debug-id="settings-bridge-wizard-pairing" className="mt-2 rounded-lg border border-warning/30 bg-warning-soft p-2 pl-6 text-xs">
                  <p className="text-warning">Approve this machine in the page opened in your browser and enter the code:</p>
                  <div className="mt-1 flex items-center gap-2">
                    <code className="select-all text-sm font-bold tracking-wide text-primary">{wizard.pairing.code}</code>
                    <Button size="sm" variant="secondary" data-debug-id="settings-bridge-wizard-copy-code" onClick={() => { void navigator.clipboard.writeText(wizard.pairing?.code || ''); }}>Copy</Button>
                    <a className="text-accent underline" href={wizard.pairing.url} target="_blank" rel="noreferrer">Open approval page</a>
                  </div>
                </div>
              ) : null}
              {step.state === 'failed' && step.log ? (
                <button type="button" className="mt-1 pl-6 text-[11px] text-accent underline" data-debug-id={`settings-bridge-wizard-open-log-${step.id}`} onClick={() => void manager.openLog(step.log)}>Show log file</button>
              ) : null}
            </li>
          ))}
        </ol>
      ) : operation ? (
        <p data-debug-id="settings-this-machine-operation" className="mt-3 text-xs text-muted">{operationLabel[operation]}… {wizard.steps.find((step) => step.state === 'running' || step.state === 'recovering')?.message || ''}</p>
      ) : null}

      {!operation && (wizard.failedStep || wizard.cancelled) ? (
        <div data-debug-id="settings-bridge-wizard-result" className="mt-3 flex flex-wrap items-center gap-2 text-xs">
          <span className={wizard.cancelled ? 'text-muted' : 'text-danger'}>
            {wizard.cancelled
              ? `Cancelled.${wizard.rolledBack ? ' Changes were rolled back.' : ''}`
              : wizard.otherAccount
                ? 'This machine is enrolled by another Ninjy account. Replacing it revokes that bridge and deletes its credentials here.'
                : lastKind === 'setup'
                  ? `Failed at ${wizard.steps.find((step) => step.id === wizard.failedStep)?.label || 'a step'} after automatic recovery.${wizard.rolledBack ? ' Changes were rolled back.' : ''}`
                  : `${operationFailed[lastKind]}${wizard.error ? `: ${wizard.error}` : '.'}`}
          </span>
          {wizard.otherAccount ? (
            // F1: replacing another account's bridge revokes it and wipes its
            // secrets on this machine, so it needs this explicit confirmation.
            <Button size="sm" variant="danger" data-debug-id="settings-bridge-wizard-replace-account" onClick={() => void run(lastKind === 'reenroll' ? 'reenroll' : 'setup', { ...lastRun?.options, replaceOtherAccount: true, bridgeId: lastRun?.options.bridgeId || status?.bridge_id || '' })}>
              Replace the other account's bridge
            </Button>
          ) : null}
          {wizard.canRetry ? (
            // Retry repeats the operation that failed, with its options.
            // ham-bridge setup is idempotent: a re-run skips the steps that
            // already succeeded (enrollment is kept), so it resumes from the
            // failed step.
            <Button size="sm" variant="primary" data-debug-id="settings-bridge-wizard-retry" onClick={() => void run(lastKind, lastRun?.options)}>Retry</Button>
          ) : null}
        </div>
      ) : null}

      {log.length ? (
        <div className="mt-3">
          <button type="button" data-debug-id="settings-bridge-log-toggle" className="text-xs text-accent underline" aria-expanded={showLog} onClick={() => setShowLog((value) => !value)}>
            {showLog ? 'Hide log' : `Show log (${log.length} lines)`}
          </button>
          {showLog ? (
            <pre data-debug-id="settings-bridge-log" className="mt-2 max-h-64 overflow-auto rounded-lg border border-subtle bg-surface p-2 font-mono text-[11px] text-muted whitespace-pre-wrap">{log.join('\n')}</pre>
          ) : null}
        </div>
      ) : null}

      {confirm ? (
        <Modal
          open
          onOpenChange={(next) => { if (!next) setConfirm(''); }}
          title={confirm === 'uninstall' ? 'Uninstall the Bridge from this machine?' : 'Re-enroll this Bridge?'}
          size="sm"
          data-debug-id={`settings-this-machine-confirm-${confirm}`}
        >
          <ModalBody className="space-y-3 text-sm text-muted">
            {confirm === 'uninstall' ? (
              <>
                <p>The Bridge is revoked on the Hub, its service is removed, and every credential and vault key it holds on this machine is deleted.</p>
                <label className="flex items-center gap-2 text-xs">
                  <input type="checkbox" data-debug-id="settings-this-machine-purge" checked={purge} onChange={(event) => setPurge(event.target.checked)} />
                  Also delete logs and agent data
                </label>
              </>
            ) : (
              <p>The Bridge disconnects until you approve the new pairing request in your browser. Its identity and history are kept.</p>
            )}
          </ModalBody>
          <ModalFooter>
            <Button variant="secondary" size="sm" data-debug-id="settings-this-machine-confirm-cancel" onClick={() => setConfirm('')}>Cancel</Button>
            <Button
              variant={confirm === 'uninstall' ? 'danger' : 'primary'}
              size="sm"
              data-debug-id="settings-this-machine-confirm-ok"
              onClick={() => {
                const kind = confirm;
                setConfirm('');
                void run(kind === 'uninstall' ? 'uninstall' : 'reenroll', kind === 'uninstall' ? { purge } : { bridgeId: status?.bridge_id || '' });
              }}
            >
              {confirm === 'uninstall' ? 'Uninstall' : 'Re-enroll'}
            </Button>
          </ModalFooter>
        </Modal>
      ) : null}
    </section>
  );
}
