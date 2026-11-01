import { useEffect, useState } from 'react';
import { Alert, Button, Input, Modal, ModalBody, ModalFooter, StatusPill } from '@ui';
import type { DesktopBridgeManagerApi } from '../../bridge/desktopBridge';
import { bridgeProfileLabel, desktopBridgeStatusLabel } from '../../bridge/desktopBridge';
import { overrideApprovalPageOpener, runDesktopBridgeOperation } from '../../bridge/desktopBridgeSession';
import { hasBridgeIdentityReview } from '../../bridge/useBridgeIdentityState';
import { useThisMachineBridge } from '../../bridge/useThisMachineBridge';
import BridgeOperationFeedback from '../bridge/BridgeOperationFeedback';
import { IdentityStep, MachineSteps } from '../bridge/LocalBridgeFlow';
import { setupRail } from '../setup/setupWizardModel';
import BridgeOperationRail from '../bridge/BridgeOperationRail';
import type { SetupStep } from '../setup/setupWizardModel';

/** Settings hosts the same detector/install/identity/update as /setup.
 * Completion never marks first-run setup seen or visits Agents/Projects. */
export default function ThisMachineCard({ manager, onBridgeId, onSetupComplete }: {
  manager: DesktopBridgeManagerApi;
  onBridgeId?: (bridgeId: string) => void; onSetupComplete?: () => void;
}) {
  const detection = useThisMachineBridge(manager);
  const { config, status, phase, bridgeId, session, refresh } = detection;
  const [flow, setFlow] = useState(() => session.operation === 'setup' || hasBridgeIdentityReview());
  const [step, setStep] = useState<SetupStep>(() => hasBridgeIdentityReview() ? 'identity' : 'detect');
  const [confirm, setConfirm] = useState<'uninstall' | 'reenroll' | ''>('');
  const [purge, setPurge] = useState(true);
  const [editingHub, setEditingHub] = useState(false);
  const [hubDraft, setHubDraft] = useState('');
  const [error, setError] = useState('');
  const busy = Boolean(session.operation || status?.busy);
  const label = phase === 'loading' ? { label: 'Checking this machine', tone: 'muted' }
    : phase === 'absent' ? { label: 'No bridge linked to this account', tone: 'muted' }
    : phase === 'error' ? { label: 'Status unavailable', tone: 'danger' }
    : desktopBridgeStatusLabel(status);
  useEffect(() => { onBridgeId?.(bridgeId); }, [bridgeId, onBridgeId]);
  useEffect(() => overrideApprovalPageOpener(() => { setFlow(true); setStep('identity'); }), []);
  const setupFlow = phase !== 'present' || step === 'identity' || session.operation === 'setup';
  const finish = () => { setFlow(false); setStep('detect'); onSetupComplete?.(); void refresh(); };
  const run = async (kind: 'update' | 'reenroll' | 'uninstall') => {
    if (phase !== 'present' || !config || !status || busy) return;
    setError('');
    const failure = await runDesktopBridgeOperation(manager, kind,
      { hub: config.hubUrl, profile: String(status.profile || '') },
      kind === 'uninstall' ? { purge } : kind === 'reenroll' ? { bridgeId } : {});
    if (failure) setError(failure);

  };
  return (
    <section data-debug-id="settings-this-machine-card" className="mt-4 min-w-0 rounded-xl border border-subtle bg-surface p-4">
      <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div className="min-w-0 space-y-2">
          <h2 className="font-serif text-xl text-primary">This machine</h2>
          <StatusPill data-debug-id="settings-this-machine-status" tone={label.tone === 'muted' ? 'neutral' : label.tone as 'success' | 'warning' | 'danger'}>{label.label}</StatusPill>
          {phase === 'present' ? <p className="break-words text-xs text-muted">Profile <span data-debug-id="settings-this-machine-profile" className="font-mono text-primary">{bridgeProfileLabel(status?.profile)}</span> · <span className="font-mono">{bridgeId}</span></p> : null}
          {phase === 'present' && status?.version ? <p data-debug-id="settings-this-machine-version" className="font-mono text-xs text-muted">v{String(status.version).replace(/^v/, '')}</p> : null}
          {phase === 'present' && status?.needs_reenrollment ? <p data-debug-id="settings-this-machine-reenroll-hint" className="text-sm text-danger">The Hub no longer accepts this bridge ({status.reenroll_reason || 'revoked'}). Re-enroll it to reconnect.</p> : null}
          {config ? <p data-debug-id="settings-this-machine-hub" className="break-all font-mono text-xs text-muted">{config.hubUrl}</p> : null}
        </div>
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-4 [&>button]:min-w-0 [&>button]:whitespace-normal [&>button]:h-auto [&>button]:min-h-8">
          {phase === 'absent' && !flow ? <Button variant="primary" data-debug-id="settings-this-machine-setup-btn" disabled={busy} onClick={() => { setFlow(true); setStep('detect'); }}>Install bridge on this machine</Button> : null}
          {phase === 'present' ? <>
            <Button variant="secondary" size="sm" data-debug-id="settings-this-machine-update-btn" disabled={busy} onClick={() => void run('update')}>Update</Button>
            <Button variant="secondary" size="sm" data-debug-id="settings-this-machine-reenroll-btn" disabled={busy} onClick={() => setConfirm('reenroll')}>Re-enroll</Button>
            <Button variant="danger" size="sm" data-debug-id="settings-this-machine-uninstall-btn" disabled={busy} onClick={() => setConfirm('uninstall')}>Uninstall</Button>
            <Button variant="secondary" size="sm" data-debug-id="settings-this-machine-manage-btn" onClick={() => { setFlow(true); setStep('detect'); }}>Manage</Button>
          </> : null}
          {phase === 'error' ? <Button variant="secondary" data-debug-id="settings-this-machine-retry" onClick={() => void refresh()}>Check again</Button> : null}
          {phase === 'absent' && !busy && !flow ? <Button variant="ghost" size="sm" data-debug-id="settings-this-machine-hub-edit" onClick={() => { setHubDraft(config?.hubUrl || ''); setEditingHub(true); }}>Change Hub</Button> : null}
        </div>
      </div>
      {detection.error || error ? <div className="mt-3" data-debug-id="settings-this-machine-error"><Alert tone="danger">{error || detection.error}</Alert></div> : null}
      <BridgeOperationFeedback manager={manager} />
      {flow ? <div data-debug-id="settings-local-bridge-flow" className={"mt-6 grid min-w-0 gap-6 border-t border-subtle pt-6 " + (setupFlow ? "lg:grid-cols-[9rem_minmax(0,1fr)]" : "")}>
        {setupFlow ? <BridgeOperationRail className="lg:border-r lg:border-subtle lg:pr-3" items={setupRail(step, phase === 'present').slice(0, 3)} label="Bridge setup" debugId="settings-local-flow-rail" /> : null}
        <div className="flex min-w-0 flex-col gap-6 [overflow-wrap:anywhere]">
        {step === 'identity' ? <IdentityStep onDone={finish} onBack={() => setStep('install')} />
          : <MachineSteps manager={manager} showOperationFeedback={false} step={step} onStep={setStep} onConnected={() => {}} onContinue={finish} />}
        <Button variant="ghost" size="sm" data-debug-id="settings-local-flow-close" onClick={() => setFlow(false)}>Back to Bridges</Button>
        </div>
      </div> : null}
      {editingHub ? <div className="mt-4 flex flex-col gap-2 sm:flex-row">
        <Input data-debug-id="settings-this-machine-hub-input" aria-label="Hub URL" value={hubDraft} onChange={setHubDraft} />
        <Button data-debug-id="settings-this-machine-hub-save" onClick={async () => {
          try {
            const result = await manager.setHubUrl(hubDraft.trim());
            if (!result.ok) throw new Error(result.error || 'Invalid Hub URL.');
            setEditingHub(false); void refresh();
          } catch (err: any) { setError(String(err?.message || err)); }
        }}>Save</Button>
        <Button variant="secondary" data-debug-id="settings-this-machine-hub-cancel" onClick={() => setEditingHub(false)}>Cancel</Button>
      </div> : null}
      {confirm ? <Modal open onOpenChange={(next) => { if (!next) setConfirm(''); }} title={confirm === 'uninstall' ? 'Uninstall the bridge from this machine?' : 'Re-enroll this bridge?'} size="sm">
        <ModalBody className="space-y-3 text-sm text-muted">
          {confirm === 'uninstall' ? <>
            <p>The service and credentials on this machine are removed. The bridge stays offline on the Hub so you can reuse its identity.</p>
            <label className="flex items-center gap-2"><input type="checkbox" data-debug-id="settings-this-machine-purge" checked={purge} onChange={(e) => setPurge(e.target.checked)} />Also delete logs and agent data</label>
          </> : <p>The bridge disconnects until you approve its pairing request. Its identity and history are kept.</p>}
        </ModalBody>
        <ModalFooter>
          <Button variant="secondary" data-debug-id="settings-this-machine-confirm-cancel" onClick={() => setConfirm('')}>Cancel</Button>
          <Button variant={confirm === 'uninstall' ? 'danger' : 'primary'} data-debug-id="settings-this-machine-confirm-ok" onClick={() => { const kind = confirm; setConfirm(''); void run(kind); }}>{confirm === 'uninstall' ? 'Uninstall' : 'Re-enroll'}</Button>
        </ModalFooter>
      </Modal> : null}
    </section>
  );
}
