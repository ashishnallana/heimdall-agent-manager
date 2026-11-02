import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Alert, Button, Icon, Input, Radio, Select, Spinner, StatusPill } from '@ui';
import type { Tone } from '@ui';
import { type DesktopBridgeManagerApi, bridgeProfileError, bridgeProfileLabel, desktopBridgeStatusLabel, desktopCapabilities, desktopSetupPlan } from '../../bridge/desktopBridge';
import { runDesktopBridgeOperation, subscribePendingApprovalCode, takePendingApprovalCode } from '../../bridge/desktopBridgeSession';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { fetchPendingBridgeEnrollments } from '../../api/endpoints/bridges';
import { type BridgeCodeInfo } from '../../api/endpoints/vaultDevices';

import { useEntitlements } from '../../hooks/useEntitlements';
import { atPlanLimit } from '../../utils/accountEntitlements';
import { sanitizeForDisplay } from '../../utils/deviceApprovalSafety';
import { buildRouteHash } from '../../utils/appLocation';
import { deviceVaultUserId } from '../../services/deviceVault';
import { BridgeReconnectWait, lookUpPairing } from '../devices/DeviceApprovalPage';
import { approveBridgeEnrollment } from '../devices/bridgeApproval';
import { cancelSetupEnrollment } from '../setup/setupEnrollment';
import { reusableBridgesOf, reusableBridgeStatusText, REUSE_WARNING } from '../devices/bridgeReuseChoice';
import UpgradePrompt from '../billing/UpgradePrompt';
import { formatBridgeVersion, formatLatestVersion } from '../settings/bridgeUpdate';
import BridgeProfileInventory from '../settings/BridgeProfileInventory';
import { EMPTY_IDENTITY_CHOICE, bridgeHasUpdate, identityPlan, installRowStatus, installRows, setupProfileChoices, sunsetCandidates, sunsetFailureNote, type IdentityChoice, type SetupStep } from '../setup/setupWizardModel';

import BridgeOperationFeedback from './BridgeOperationFeedback';
import { useBridgeIdentityState, useBridgeIdentityRef, finishBridgeIdentityReview } from '../../bridge/useBridgeIdentityState';
import { useThisMachineBridge } from '../../bridge/useThisMachineBridge';

const statusTone: Record<string, Tone> = { success: 'success', warning: 'warning', danger: 'danger', muted: 'neutral' };
function errText(err: unknown): string {
  const e = err as any;
  return String(e?.data?.error || e?.error || e?.message || err);
}

export function StepHeading({ eyebrow, title, children }: { eyebrow: string; title: string; children?: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-2">
      <p className="text-[11px] font-semibold uppercase tracking-wider text-faint">{eyebrow}</p>
      <h2 data-debug-id="setup-step-title" className="font-serif text-2xl text-primary">{title}</h2>
      {children ? <p className="text-sm text-muted">{children}</p> : null}
    </div>
  );
}

export function MachineSteps({ manager, step, onStep, onConnected, onContinue, showOperationFeedback = true }: {
  manager: DesktopBridgeManagerApi;
  step: SetupStep;
  onStep: (step: SetupStep) => void;
  onConnected: (bridgeId: string) => void;
  onContinue?: () => void;
  showOperationFeedback?: boolean;
}) {
  const detection = useThisMachineBridge(manager);
  const { config, status, profiles, accountBridgeIds, bridges, session, error, setError, refresh } = detection;
  const [confirmUninstall, setConfirmUninstall] = useState(false);
  const [profile, setProfile] = useState('');
  const [customProfile, setCustomProfile] = useState(false);
  const profileChoices = setupProfileChoices(profiles);
  const profileError = bridgeProfileError(profile) || (profiles.some((p) => (p.profile || '') === profile && p.enrolled)
    ? 'This profile is already enrolled. Choose a separate profile for your account.' : '');
  useEffect(() => {
    setProfile(setupProfileChoices(profiles)[0]);
    setCustomProfile(false);
  }, [profileChoices.join('|')]);
  useEffect(() => {
    if (session.operation && session.operation !== 'setup') return;
    if (session.lastRun?.kind === 'setup' && (session.operation === 'setup' || session.wizard.failedStep || session.wizard.cancelled)) { onStep('install'); return; }
    if (detection.phase === 'present' && status) {
      onConnected(String(status.bridge_id));
      onStep('machine');
    } else if (detection.phase === 'absent') onStep('install');
    else onStep('detect');
  }, [detection.phase, status, session.operation, session.wizard.failedStep, session.wizard.cancelled]);
  const checks = detection.phase === 'present' || detection.phase === 'absent' ? 3 : 1;
  const otherAccounts = detection.otherAccounts;
  const run = async (kind: 'setup' | 'update' | 'uninstall') => {
    if (!config || (detection.phase !== 'present' && detection.phase !== 'absent')) return;
    setError('');
    if (kind === 'setup') {
      if (profileError) { setError(profileError); return; }
      const plan = desktopSetupPlan(null, config.hubUrl, profile);
      const failure = await runDesktopBridgeOperation(manager, 'setup', plan.target, plan.options);
      if (failure) setError(failure);
      return;
    }
    const target = { hub: config.hubUrl, profile: String(status?.profile || '') };
    const failure = await runDesktopBridgeOperation(manager, kind, target, kind === 'uninstall' ? { purge: false } : {});
    if (failure) setError(failure);
  };

  const resumingSetup = session.lastRun?.kind === 'setup' && (session.operation === 'setup' || session.wizard.failedStep || session.wizard.cancelled);
  if (!resumingSetup && (step === 'detect' || (detection.phase !== 'present' && detection.phase !== 'absent' && !session.operation))) {
    const items = ['Looking for a bridge on this machine', 'Checking its service', 'Matching it to your account'];
    return (
      <>
        <StepHeading eyebrow="This machine" title="Checking this machine">
          Looking for a Ninjy bridge already running here, so you don't set it up twice.
        </StepHeading>
        <ul data-debug-id="setup-detect-checks" className="rounded-xl border border-subtle bg-surface px-4">
          {items.map((label, index) => (
            <li key={label} className="flex items-center gap-3 border-b border-subtle py-3 text-sm last:border-b-0">
              {index === 0 && (detection.phase === 'error' || detection.phase === 'unsupported')
                ? <Icon name="alert" size="md" className="text-danger" />
                : index < checks - 1 || (checks === 3 && index === 2)
                ? <Icon name="check" size="md" className="text-success" />
                : index === checks - 1 ? <Spinner size="sm" /> : <span className="grid h-4 w-4 place-items-center"><span className="h-1.5 w-1.5 rounded-full bg-neutral-soft" /></span>}
              <span className={index < checks ? 'text-primary' : 'text-muted'}>{label}</span>
            </li>
          ))}
        </ul>
        {error ? (
          <div data-debug-id="setup-detect-error" className="flex flex-col gap-3">
            <Alert tone="danger">{error}</Alert>
            <div><Button variant="secondary" data-debug-id="setup-detect-retry-btn" onClick={() => { setError(''); void refresh(); }}>Check again</Button></div>
          </div>
        ) : null}
      </>
    );
  }

  if (step === 'machine') {
    const row = bridges.find((b: any) => String(b.bridge_id || b.id || '') === String(status?.bridge_id || ''));
    const label = desktopBridgeStatusLabel(status);
    const busy = Boolean(session.operation || status?.busy);
    const updating = session.operation === 'update';
    const hasUpdate = bridgeHasUpdate(row) && !updating;
    const version = formatBridgeVersion(row) || (status?.version ? `v${String(status.version).replace(/^v/, '')}` : '');
    return (
      <>
        <StepHeading eyebrow="This machine" title="This machine is already connected">
          We found a bridge here that belongs to your account. Nothing to install.
        </StepHeading>
        <section data-debug-id="setup-machine-card" className="overflow-hidden rounded-xl border border-subtle bg-surface">
          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-subtle p-4">
            <div className="min-w-0">
              <p className="truncate text-sm font-semibold text-primary">{row?.machine_hostname || row?.label || status?.profile || 'This machine'}</p>
              <p className="text-xs text-muted">
                Bridge identity <span className="font-mono text-primary">{row?.label || status?.bridge_id}</span>
                {status?.hub ? <> · <span className="font-mono">{status.hub}</span></> : null}
              </p>
            </div>
            <StatusPill data-debug-id="setup-machine-status" tone={statusTone[label.tone]}>{label.label}</StatusPill>
          </div>
          <dl className="grid grid-cols-[8rem_minmax(0,1fr)] text-sm">
            <dt className="border-b border-subtle px-4 py-3 text-muted">Profile</dt>
            <dd data-debug-id="setup-machine-profile" className="border-b border-subtle px-4 py-3 font-mono text-primary">{bridgeProfileLabel(status?.profile)}</dd>
            <dt className="border-b border-subtle px-4 py-3 text-muted">Version</dt>
            <dd className="flex flex-wrap items-center gap-2 border-b border-subtle px-4 py-3">
              <span data-debug-id="setup-machine-version" className="font-mono text-primary">{version || 'Unknown'}</span>
              {hasUpdate
                ? <StatusPill tone="warning" data-debug-id="setup-machine-update-available">Update available: {formatLatestVersion(row)}</StatusPill>
                : updating ? null : <StatusPill tone="neutral">Up to date</StatusPill>}
            </dd>
            <dt className="px-4 py-3 text-muted">Service</dt>
            <dd className="px-4 py-3 text-primary">
              <span className="font-mono text-xs text-muted">{status?.service || '—'}</span>
            </dd>
          </dl>
          {showOperationFeedback && session.lastRun?.kind === 'update' ? <div className="border-t border-subtle p-4"><BridgeOperationFeedback manager={manager} /></div> : null}
        </section>

        <BridgeProfileInventory profiles={profiles} accountBridgeIds={accountBridgeIds || []} debugId="setup-detected-profiles" />

        {status && status.state !== 'connected' && !busy ? (
          <Alert tone="warning" title={label.label}>
            {status.needs_reenrollment
              ? `The hub no longer accepts this bridge (${status.reenroll_reason || 'revoked'}). Re-enroll it from Settings › Bridges.`
              : 'The bridge is installed but not connected right now. You can continue; it reconnects on its own once its service is running.'}
          </Alert>
        ) : null}

        {confirmUninstall ? (
          <div data-debug-id="setup-uninstall-confirm" className="flex flex-col gap-3 rounded-xl bg-danger-soft p-4">
            <p className="text-sm font-semibold text-danger">Uninstall the bridge from this machine?</p>
            <p className="text-sm text-primary">This stops its service and removes its credentials here. Logs and agent data stay on this machine, and the bridge stays on your account as offline, so setting up again can reuse it.</p>
            <div className="flex flex-wrap gap-2">
              <Button variant="danger" data-debug-id="setup-uninstall-confirm-btn" onClick={() => { setConfirmUninstall(false); void run('uninstall'); }}>Uninstall</Button>
              <Button variant="ghost" data-debug-id="setup-uninstall-cancel-btn" onClick={() => setConfirmUninstall(false)}>Keep it</Button>
            </div>
          </div>
        ) : null}
        {session.operation === 'uninstall' ? <p data-debug-id="setup-uninstall-progress" className="flex items-center gap-2 text-sm text-muted"><Spinner size="sm" /> Uninstalling…</p> : null}
        {error ? <Alert tone="danger">{error}</Alert> : null}

        <div className="flex flex-wrap items-center gap-2">
          {hasUpdate ? (
            <>
              <Button variant="primary" data-debug-id="setup-machine-update-btn" disabled={busy} onClick={() => void run('update')}>Update to {formatLatestVersion(row)}</Button>
              <Button variant="secondary" data-debug-id="setup-machine-continue-btn" disabled={busy} onClick={() => onContinue ? onContinue() : onStep('agents')}>Continue without updating</Button>
            </>
          ) : (
            <Button variant="primary" data-debug-id="setup-machine-continue-btn" disabled={busy} onClick={() => onContinue ? onContinue() : onStep('agents')}>Continue</Button>
          )}
          <span className="flex-1" />
          <Button variant="ghost" data-debug-id="setup-machine-uninstall-btn" disabled={busy} onClick={() => setConfirmUninstall(true)}>Uninstall</Button>
        </div>
      </>
    );
  }

  // Install + pair.
  const { wizard, operation, log, lastRun } = session;
  const setupRun = lastRun?.kind === 'setup';
  const running = operation === 'setup';
  const failed = setupRun && !running && (Boolean(wizard.failedStep) || wizard.cancelled);
  const started = setupRun && (running || wizard.completed || failed);
  const rows = installRows(wizard);
  return (
    <>
      <StepHeading
        eyebrow="Install & enroll"
        title={!started ? 'Set up this machine' : failed ? 'Install didn’t finish' : wizard.pairing ? 'Installed, waiting for you' : running ? 'Setting up this machine' : 'Installed'}
      >
        {!started
          ? profiles.length ? 'No Bridge linked to your account was found here. Choose a separate profile to connect this computer.' : 'No Bridge profiles are installed for this Hub on this computer. Choose a profile, then install and connect the Bridge to your account.'
          : failed ? 'One step failed. The log below shows where.' : 'Running ham-bridge setup. Keep this window open.'}
      </StepHeading>

      <p data-debug-id="setup-selected-profile" className="text-xs text-muted">Profile: <span className="font-mono text-primary">{bridgeProfileLabel(started ? lastRun?.target?.profile : profile)}</span></p>

      {!started ? (
        <>
          <BridgeProfileInventory profiles={profiles} accountBridgeIds={accountBridgeIds || []} debugId="setup-detected-profiles" />
          <section className="space-y-3 rounded-xl border border-subtle bg-surface p-4">
            <label htmlFor="setup-profile-select" className="block text-sm font-medium text-primary">Bridge profile</label>
            <p id="setup-profile-help" className="text-xs leading-relaxed text-muted">Each profile runs a separate Bridge with its own credentials. Use a different profile for each Ninjy account on this computer.</p>
            <Select id="setup-profile-select" data-debug-id="setup-profile-select" aria-label="Bridge profile" aria-describedby="setup-profile-help" value={customProfile ? '__new__' : profile}
              onChange={(value) => { setCustomProfile(value === '__new__'); setProfile(value === '__new__' ? '' : value); }}>
              {profileChoices.map((name) => <option key={name} value={name}>{bridgeProfileLabel(name)}</option>)}
              <option value="__new__">Create a named profile…</option>
            </Select>
            {customProfile ? <div className="space-y-2">
              <label htmlFor="setup-profile-name" className="block text-xs font-medium text-muted">Profile name</label>
              <Input id="setup-profile-name" data-debug-id="setup-profile-name-input" value={profile} onChange={setProfile} placeholder="personal" invalid={Boolean(profileError) || !profile} aria-describedby="setup-profile-help" />
            </div> : null}
            {profileError ? <p role="alert" data-debug-id="setup-profile-error" className="text-xs text-danger">{profileError}</p> : null}
          </section>
          <section className="rounded-xl border border-subtle bg-surface">
            <dl className="grid grid-cols-[8rem_minmax(0,1fr)] text-sm">
              <dt className="border-b border-subtle px-4 py-3 text-muted">Bridge</dt>
              <dd className="border-b border-subtle px-4 py-3 text-primary">Latest release{config?.bundledVersion ? <span className="text-muted"> · v{config.bundledVersion} bundled as a fallback</span> : null}</dd>
              <dt className="border-b border-subtle px-4 py-3 text-muted">Runs as</dt>
              <dd className="border-b border-subtle px-4 py-3 text-primary">A background service for your user, no admin needed</dd>
              <dt className="px-4 py-3 text-muted">Hub</dt>
              <dd className="min-w-0 px-4 py-3"><span data-debug-id="setup-install-hub" className="break-all font-mono text-primary">{config?.hubUrl}</span></dd>
            </dl>
          </section>
          {otherAccounts > 0 ? (
            <p data-debug-id="setup-install-other-accounts" className="text-xs text-muted">
              {otherAccounts === 1 ? 'Another Ninjy account has a bridge' : `${otherAccounts} other Ninjy accounts have bridges`} on this machine. Setup installs a separate bridge for your account; theirs keeps running untouched.
            </p>
          ) : null}
          <div className="flex flex-wrap items-center gap-3">
            <Button variant="primary" size="lg" data-debug-id="setup-install-btn" leading={<Icon name="download" size="sm" />} disabled={!config || detection.phase !== 'absent' || Boolean(session.operation) || Boolean(profileError) || (customProfile && !profile)} onClick={() => void run('setup')}>Install and enroll</Button>
            <span className="text-xs text-faint">About a minute. You'll see every step as it runs.</span>
          </div>
        </>
      ) : (
        <section data-debug-id="setup-install-progress" className="overflow-hidden rounded-xl border border-subtle bg-surface">
          <div className="h-1 bg-neutral-soft" aria-hidden="true">
            <div className={`h-1 transition-all ${failed ? 'bg-danger' : wizard.completed ? 'bg-success' : 'bg-info'}`} style={{ width: `${Math.max(0, Math.min(100, wizard.completed ? 100 : wizard.pct))}%` }} />
          </div>
          <ol className="grid grid-cols-1 border-b border-subtle sm:grid-cols-3" aria-label="Setup progress">
            {rows.map((row) => (
              <li key={row.id} data-debug-id={`setup-install-row-${row.id}`} data-state={row.state} className="flex items-start gap-2 px-4 py-3">
                <span className="mt-0.5">
                  {row.state === 'ok' || row.state === 'skipped' ? <Icon name="check" size="md" className="text-success" />
                    : row.state === 'failed' ? <Icon name="close" size="md" className="text-danger" />
                    : row.state === 'running' || row.state === 'recovering' ? <Spinner size="sm" />
                    : <span className="grid h-4 w-4 place-items-center"><span className="h-1.5 w-1.5 rounded-full bg-neutral-soft" /></span>}
                </span>
                <span className="min-w-0">
                  <span className={`block text-sm font-medium ${row.state === 'pending' ? 'text-muted' : 'text-primary'}`}>{row.label}</span>
                  <span className="block truncate text-xs text-faint" title={row.message}>{row.message || installRowStatus(row.state)}</span>
                </span>
              </li>
            ))}
          </ol>
          <div className="p-4">
            <LogView lines={log} debugId="setup-install-log" live={running} />
          </div>
        </section>
      )}

      {failed ? (
        <div data-debug-id="setup-install-failed" className="flex flex-col gap-3">
          <Alert tone={wizard.cancelled ? 'neutral' : 'danger'} title={wizard.cancelled ? 'Cancelled' : `Install stopped at ${rows.find((r) => r.state === 'failed')?.label || 'a step'}`}>
            {wizard.cancelled
              ? `Setup was cancelled.${wizard.rolledBack ? ' Changes were rolled back.' : ''}`
              : wizard.otherAccount
                ? 'This machine is enrolled by another Ninjy account. Open Settings › Bridges to install a separate bridge for your account or replace theirs.'
                : `${wizard.error || 'Setup failed after automatic recovery.'}${wizard.rolledBack ? ' Changes were rolled back.' : ''}`}
          </Alert>
          <div className="flex flex-wrap gap-2">
            {wizard.otherAccount ? (
              <Button variant="primary" data-debug-id="setup-install-bridges-btn" onClick={() => { window.location.hash = buildRouteHash('/settings/bridges', ''); }}>Open bridge settings</Button>
            ) : (
              <Button variant="primary" data-debug-id="setup-install-retry-btn" onClick={() => void runDesktopBridgeOperation(manager, 'setup', lastRun?.target || { hub: config?.hubUrl, profile }, lastRun?.options || {}).then((f) => f && setError(f))}>Retry</Button>
            )}
            <Button variant="secondary" data-debug-id="setup-install-copy-log-btn" onClick={() => { void navigator.clipboard?.writeText(log.join('\n')); }}>Copy log</Button>
            {wizard.steps.find((s) => s.log)?.log ? (
              <Button variant="ghost" data-debug-id="setup-install-open-log-btn" onClick={() => void manager.openLog(String(wizard.steps.find((s) => s.log)?.log || ''))}>Open log file</Button>
            ) : null}
          </div>
        </div>
      ) : null}

      {error ? <Alert tone="danger">{error}</Alert> : null}

      {running ? (
        <div className="flex flex-wrap items-center gap-2">
          {wizard.pairing ? <>
            <Button variant="primary" data-debug-id="setup-install-identity-btn" onClick={() => onStep('identity')}>Choose bridge identity</Button>
            <Button variant="secondary" data-debug-id="setup-install-copy-code" onClick={() => void navigator.clipboard?.writeText(wizard.pairing?.code || '')}>Copy pairing code</Button>
          </> : null}
          <Button variant="ghost" data-debug-id="setup-install-cancel-btn" onClick={() => void manager.cancel()}>Cancel</Button>
        </div>
      ) : setupRun && wizard.completed ? (
        <div><Button variant="primary" data-debug-id="setup-install-continue-btn" onClick={() => void refresh()}>Continue</Button></div>
      ) : null}
    </>
  );
}

function LogView({ lines, debugId, live = false }: { lines: string[]; debugId: string; live?: boolean }) {
  const ref = useRef<HTMLPreElement | null>(null);
  useEffect(() => {
    const el = ref.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [lines.length]);
  return (
    <pre
      ref={ref}
      data-debug-id={debugId}
      aria-live="polite"
      className="h-56 overflow-auto whitespace-pre-wrap break-words rounded-lg border border-subtle bg-canvas p-3 font-mono text-[11px] leading-5 text-muted"
    >
      {lines.length ? lines.join('\n') : 'Starting…'}
      {live ? <span className="animate-pulse text-faint">{'\n'}▍</span> : null}
    </pre>
  );
}

// ---------------------------------------------------------------------------
// Identity: reuse one of your bridges, or register new (and sunset one when full).
// ---------------------------------------------------------------------------

type Review = Awaited<ReturnType<typeof lookUpPairing>>;

export function IdentityStep({ onDone, onBack }: { onDone: (bridgeId: string, note: string) => void; onBack: () => void }) {
  const entitlements = useEntitlements();
  const { data: bridgesData, refetch: refetchBridges } = useListBridgesQuery();
  const bridges = useMemo(() => (Array.isArray(bridgesData?.bridges) ? bridgesData.bridges : []), [bridgesData]);
  const [code, setCode] = useBridgeIdentityState('code', '');
  const [review, setReview] = useBridgeIdentityState<Review | null>('review', null);
  const [lookupError, setLookupError] = useBridgeIdentityState('lookupError', '');
  const [choice, setChoice] = useBridgeIdentityState<IdentityChoice>('choice', EMPTY_IDENTITY_CHOICE);
  const [newLabel, setNewLabel] = useBridgeIdentityState('newLabel', '');
  const [pendingCount, setPendingCount] = useBridgeIdentityState('pendingCount', 0);
  const [waitingBridgeId, setWaitingBridgeId] = useBridgeIdentityState('waitingBridgeId', '');
  const [cancelError, setCancelError] = useBridgeIdentityState('cancelError', '');
  const [cancelling, setCancelling] = useBridgeIdentityState('cancelling', false);
  const pendingAttempt = useBridgeIdentityRef('pendingAttempt', '');
  const enrollmentWait = useBridgeIdentityRef<AbortController | null>('enrollmentWait', null);
  const seeded = useBridgeIdentityRef('seeded', false);
  const lookupStarted = useBridgeIdentityRef('lookupStarted', '');
  const [phase, setPhase] = useBridgeIdentityState<{ kind: 'choose' } | { kind: 'working'; message: string } | { kind: 'reconnecting'; bridgeId: string; label: string; approved: string } | { kind: 'failed'; message: string }>('phase', { kind: 'choose' });

  // The pairing code this app's own setup printed, taken once.
  useEffect(() => {
    const take = () => { const handed = takePendingApprovalCode(); if (handed) setCode(handed); };
    take();
    return subscribePendingApprovalCode(take);
  }, [setCode]);

  useEffect(() => {
    if (!code || lookupStarted.current === code) return;
    lookupStarted.current = code;
    setReview(null);
    setChoice(EMPTY_IDENTITY_CHOICE);
    setPhase({ kind: 'choose' });
    setCancelError('');
    pendingAttempt.current = '';
    seeded.current = false;
    setLookupError('');
    void lookUpPairing(code, deviceVaultUserId()).then((found) => {
      if (lookupStarted.current !== code) return;
      if (found.browser) { setLookupError('That pairing code belongs to a browser, not this machine’s bridge.'); return; }
      setReview(found);
      setNewLabel(found.label);
    }).catch((err) => { if (lookupStarted.current === code) setLookupError(errText(err)); });
  }, [code]);

  useEffect(() => {
    if (!review) return;
    void fetchPendingBridgeEnrollments().then((rows) => setPendingCount(rows.filter((row) => !row.replacing).length)).catch(() => {});
  }, [review]);

  const info = review?.info as BridgeCodeInfo | undefined;
  const reusable = useMemo(() => reusableBridgesOf(info), [info]);
  const candidates = useMemo(() => sunsetCandidates(bridges), [bridges]);
  const atCapacity = atPlanLimit(entitlements.max_bridges, candidates.length + pendingCount);

  // Preselect only when the machine's own hint names one of your bridges; otherwise
  // a new bridge when there is room. Reuse signs another machine out, so it is never
  // picked for the user without that hint.
  useEffect(() => {
    if (!info || seeded.current) return;
    seeded.current = true;
    const hint = typeof info.previous_bridge_id === 'string' ? info.previous_bridge_id : '';
    if (hint && reusable.some((b) => b.bridge_id === hint)) setChoice({ mode: 'reuse', reuseId: hint, sunsetId: '' });
    else if (!atCapacity) setChoice({ mode: 'new', reuseId: '', sunsetId: '' });
  }, [info, reusable, atCapacity]);

  const plan = identityPlan(choice, reusable, candidates, atCapacity);
  const busy = phase.kind === 'working' || phase.kind === 'reconnecting';

  const approve = useCallback(async () => {
    if (!review || !info || !plan.ok) return;
    const label = newLabel.trim() || review.label;
    const sunset = plan.sunset;
    // The sunset is not a separate step: the hub retires that bridge in the same
    // transaction that approves this one (sunset_bridge_id), and gives it back on any
    // rollback of the still-pending enrollment. It is final only once this machine
    // finishes enrolling.
    const wait = new AbortController();
    enrollmentWait.current = wait;
    try {
      const outcome = await approveBridgeEnrollment({
        info,
        keys: review.keys,
        target: plan.reuse,
        newLabel: label,
        sunset: sunset ? { bridge_id: sunset.bridge_id, label: sunset.label } : null,
        onProgress: (message) => setPhase({ kind: 'working', message }),
        waitSignal: wait.signal,
        onWaiting: (id) => {
          if (id) pendingAttempt.current = id;
          setWaitingBridgeId(id);
        },
      });
      // The picker's copy of the sunset bridge is stale now.
      if (sunset) void refetchBridges();
      setPhase({ kind: 'reconnecting', bridgeId: outcome.bridgeId, label: outcome.label, approved: outcome.approved });
    } catch (err) {
      // What happened to the sunset bridge is read back from the hub, not guessed from
      // how far this client got; the same refetch keeps a retry from offering a
      // bridge that is already retired.
      let prefix = '';
      if (sunset) {
        const refreshed = await refetchBridges().unwrap()
          .then((data: any) => (Array.isArray(data?.bridges) ? data.bridges : null))
          .catch(() => null);
        prefix = sunsetFailureNote(sunset, refreshed);
      }
      setPhase({ kind: 'failed', message: prefix + errText(err) });
    }
  }, [review, info, plan, newLabel, refetchBridges]);

  const deny = useCallback(async () => {
    setCancelling(true);
    setCancelError('');
    try {
      // After approval the pairing grant is consumed. Cancel the pending
      // enrollment itself so a retry does not collide with its old identity.
      const manager = desktopCapabilities().bridgeManager;
      if (!await cancelSetupEnrollment({
        bridgeId: pendingAttempt.current,
        pairLookup: review?.keys.lookup,
        wait: enrollmentWait.current,
        cancelLocal: () => manager ? manager.cancel() : Promise.resolve({ ok: true }),
      })) return;
      pendingAttempt.current = '';
      finishBridgeIdentityReview();
      onBack();
    } catch (err) {
      setCancelError(errText(err));
    } finally {
      setCancelling(false);
    }
  }, [review, onBack]);

  if (phase.kind === 'reconnecting') {
    return (
      <>
        <StepHeading eyebrow="Bridge identity" title="Finishing enrollment" />
        <p data-debug-id="setup-identity-outcome" className="text-sm text-primary">{phase.approved}</p>
        <BridgeReconnectWait
          bridgeId={phase.bridgeId}
          label={phase.label}
          onReady={() => { finishBridgeIdentityReview(); onDone(phase.bridgeId, phase.approved); }}
          onSkip={() => { finishBridgeIdentityReview(); onDone(phase.bridgeId, phase.approved); }}
          skipLabel="Continue anyway"
        />
      </>
    );
  }

  return (
    <>
      <StepHeading eyebrow="Bridge identity" title="Which bridge is this machine?">
        {atCapacity
          ? `Your plan's bridges are all in use. Hand one of them to this machine, or register it as a new bridge and sunset one.`
          : 'Register this machine as a new bridge, or hand it one of your existing bridge identities.'}
      </StepHeading>

      {!review ? (
        lookupError ? (
          <div data-debug-id="setup-identity-lookup-error" className="flex flex-col gap-3">
            <Alert tone="danger">{lookupError}</Alert>
            <div><Button variant="secondary" data-debug-id="setup-identity-back-btn" onClick={onBack}>Back to install</Button></div>
          </div>
        ) : (
          <p data-debug-id="setup-identity-waiting" className="flex items-center gap-2 text-sm text-muted"><Spinner size="sm" /> {code ? 'Checking the pairing request…' : 'Waiting for the pairing code from setup…'}</p>
        )
      ) : (
        <>
          {review.foreignOrigin ? (
            <Alert tone="warning" title="Different hub address">
              This bridge paired with <code className="font-mono">{review.hubOrigin}</code>, which differs from this page but is a configured alias of this hub.
            </Alert>
          ) : null}

          {reusable.length ? (
            <fieldset data-debug-id="setup-identity-reuse" className="flex flex-col gap-2">
              <legend className="mb-1 text-xs font-medium text-muted">Reuse an existing identity</legend>
              {reusable.map((b) => {
                const on = choice.mode === 'reuse' && choice.reuseId === b.bridge_id;
                return (
                  <label
                    key={b.bridge_id}
                    data-debug-id={`setup-identity-reuse-${b.bridge_id}`}
                    className={`flex cursor-pointer items-center gap-3 rounded-xl border p-4 ${on ? 'border-accent bg-surface-raised' : 'border-subtle bg-surface'}`}
                  >
                    <Radio
                      name="setup-identity"
                      checked={on}
                      disabled={busy}
                      data-debug-id={`setup-identity-reuse-radio-${b.bridge_id}`}
                      onChange={() => setChoice({ mode: 'reuse', reuseId: b.bridge_id, sunsetId: '' })}
                      aria-label={`Reuse ${b.label || b.bridge_id}`}
                    />
                    <span className="min-w-0 flex-1">
                      <span className="block text-sm font-semibold text-primary">{sanitizeForDisplay(b.label || b.bridge_id).text}</span>
                      <span className="block text-xs text-muted">
                        {b.machine_hostname ? <>Last on <span className="font-mono">{sanitizeForDisplay(b.machine_hostname).text}</span> · </> : null}
                        {reusableBridgeStatusText(b)}
                        {b.bridge_id === info?.previous_bridge_id ? ' · this machine says it was this bridge' : ''}
                      </span>
                    </span>
                  </label>
                );
              })}
            </fieldset>
          ) : null}

          <div className={`overflow-hidden rounded-xl border ${choice.mode === 'new' ? 'border-accent bg-surface-raised' : 'border-subtle bg-surface'}`}>
            <label data-debug-id="setup-identity-new" className="flex cursor-pointer items-center gap-3 p-4">
              <Radio
                name="setup-identity"
                checked={choice.mode === 'new'}
                disabled={busy}
                data-debug-id="setup-identity-new-radio"
                onChange={() => setChoice((c) => ({ mode: 'new', reuseId: '', sunsetId: c.sunsetId }))}
                aria-label="Register as a new bridge"
              />
              <span className="min-w-0 flex-1">
                <span className="block text-sm font-semibold text-primary">Register as a new bridge</span>
                <span className="block text-xs text-muted">{atCapacity ? 'Your plan is full, so you’ll sunset one bridge to make room' : 'Keeps your other bridges as they are'}</span>
              </span>
            </label>
            {choice.mode === 'new' ? (
              <div className="flex flex-col gap-4 border-t border-subtle p-4">
                <div className="flex flex-col gap-1">
                  <label htmlFor="setup-identity-name" className="text-xs font-medium text-muted">Name</label>
                  <Input id="setup-identity-name" data-debug-id="setup-identity-name-input" value={newLabel} onChange={setNewLabel} disabled={busy} className="max-w-sm" />
                </div>
                {atCapacity ? (
                  <fieldset data-debug-id="setup-identity-sunset" className="flex flex-col gap-1">
                    <legend className="mb-1 text-xs font-medium text-muted">Bridge to sunset</legend>
                    {candidates.map((b) => (
                      <Radio
                        key={b.bridge_id}
                        name="setup-identity-sunset"
                        checked={choice.sunsetId === b.bridge_id}
                        disabled={busy}
                        data-debug-id={`setup-identity-sunset-${b.bridge_id}`}
                        onChange={() => setChoice((c) => ({ ...c, sunsetId: b.bridge_id }))}
                        label={(
                          <span className="text-sm">
                            <span className="text-primary">{sanitizeForDisplay(b.label).text}</span>
                            {b.machine_hostname ? <span className="text-muted"> · {sanitizeForDisplay(b.machine_hostname).text}</span> : null}
                            <span className={b.status === 'online' ? 'text-success' : 'text-muted'}> · {b.status || 'offline'}</span>
                          </span>
                        )}
                      />
                    ))}
                    <span className="mt-1 text-xs text-faint">Want to keep them all? <UpgradeLink /></span>
                  </fieldset>
                ) : null}
              </div>
            ) : null}
          </div>

          {/* Alert does not forward data-* props, so the debug IDs sit on a wrapper. */}
          {plan.reuse ? <div data-debug-id="setup-identity-reuse-warning"><Alert tone="warning">{REUSE_WARNING}</Alert></div> : null}
          {plan.sunset ? (
            <div data-debug-id="setup-identity-sunset-warning">
              <Alert tone="warning" title={`${sanitizeForDisplay(plan.sunset.label).text} will be revoked`}>
                It is paused in the same step that approves this machine, never before. If the approval is refused or this machine does not finish enrolling, its credentials are restored unless its plan slot is used meanwhile. It reconnects on its next retry after restoration; an unfinished enrollment expires after 5 minutes. Once this machine is enrolled, retirement is permanent and the old machine is signed out for good. Your agents and projects stay on your account; to use that machine again, set it up as a bridge again.
              </Alert>
            </div>
          ) : null}

          <details className="text-xs text-muted">
            <summary className="cursor-pointer">Pairing details</summary>
            <dl className="mt-2 grid grid-cols-[8rem_minmax(0,1fr)] gap-y-1">
              <dt>Claims to be</dt><dd className="text-primary">{review.label}</dd>
              <dt>Fingerprint</dt><dd data-debug-id="setup-identity-fingerprint" className="font-mono tracking-wider text-primary">{review.fingerprint}</dd>
              <dt>Hub address</dt><dd className="font-mono text-primary">{review.hubOrigin}</dd>
            </dl>
          </details>

          {phase.kind === 'working' ? <p data-debug-id="setup-identity-progress" className="flex items-center gap-2 text-sm text-muted"><Spinner size="sm" /> {phase.message}</p> : null}
          {phase.kind === 'failed' ? <div data-debug-id="setup-identity-error"><Alert tone="danger">{phase.message}</Alert></div> : null}
          {cancelError ? <div data-debug-id="setup-identity-cancel-error" role="alert"><Alert tone="danger">{cancelError}</Alert></div> : null}
          {atCapacity && !reusable.length && !candidates.length ? <UpgradePrompt details={{ limit: 'max_bridges' }} debugId="setup-identity-plan-cap" /> : null}

          <div className="flex flex-wrap gap-2">
            <Button variant="primary" data-debug-id="setup-identity-approve-btn" loading={phase.kind === 'working'} disabled={!plan.ok || busy || cancelling || Boolean(pendingAttempt.current)} onClick={() => void approve()}>{plan.action}</Button>
            <Button variant="ghost" data-debug-id="setup-identity-deny-btn" disabled={cancelling || (busy && !waitingBridgeId)} onClick={() => void deny()}>{cancelling ? 'Cancelling…' : phase.kind === 'failed' && pendingAttempt.current ? 'Retry setup' : 'Cancel setup'}</Button>
          </div>
        </>
      )}
    </>
  );
}

function UpgradeLink() {
  return <a data-debug-id="setup-identity-upgrade-link" href={buildRouteHash('/settings/account', '')} className="font-medium text-accent underline">Upgrade your plan</a>;
}
