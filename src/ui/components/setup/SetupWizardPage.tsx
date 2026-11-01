// /setup — first-run setup for this machine (desktop app). See setupWizardModel.ts
// for the flow. The left rail is fixed; the right pane scrolls on its own.
//
// Security notes: the pairing code is the one THIS app's own `ham-bridge setup`
// printed, handed over in memory (desktopBridgeSession) and looked up exactly as on
// /device/add (lookUpPairing: key_mac checked under the code, hub origin checked
// against this hub's aliases). Approval runs the same signed sequence as /device/add
// (bridgeApproval.ts); the user still reviews and approves.

import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { Alert, Button, Icon, Input, Radio, Select, Spinner, StatusPill } from '@ui';
import type { Tone } from '@ui';
import {
  type DesktopBridgeConfig,
  type DesktopBridgeManagerApi,
  type DesktopBridgeStatus,
  accountBridgeProfile,
  bridgeProfileError,
  bridgeProfileLabel,
  desktopBridgeStatusLabel,
  desktopCapabilities,
  desktopSetupPlan,
  otherAccountProfiles,
  installedHubProfiles,
} from '../../bridge/desktopBridge';
import {
  attachDesktopBridgeSession,
  desktopBridgeSession,
  overrideApprovalPageOpener,
  runDesktopBridgeOperation,
  subscribeDesktopBridgeSession,
  subscribePendingApprovalCode,
  takePendingApprovalCode,
} from '../../bridge/desktopBridgeSession';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { fetchPendingBridgeEnrollments } from '../../api/endpoints/bridges';
import { type BridgeCodeInfo } from '../../api/endpoints/vaultDevices';
import { useCreateProjectMutation, useListProjectsQuery, useSetProjectBridgePathMutation } from '../../api/endpoints/projects';
import { cookieJsonFetch } from '../../api/cookieFetch';
import { useEntitlements } from '../../hooks/useEntitlements';
import { atPlanLimit } from '../../utils/accountEntitlements';
import { sanitizeForDisplay } from '../../utils/deviceApprovalSafety';
import { buildRouteHash } from '../../utils/appLocation';
import { deviceVaultUserId } from '../../services/deviceVault';
import { BridgeReconnectWait, lookUpPairing } from '../devices/DeviceApprovalPage';
import { approveBridgeEnrollment } from '../devices/bridgeApproval';
import { cancelSetupEnrollment } from './setupEnrollment';
import { reusableBridgesOf, reusableBridgeStatusText, REUSE_WARNING } from '../devices/bridgeReuseChoice';
import UpgradePrompt from '../billing/UpgradePrompt';
import ProviderSetupSurface from '../providers/ProviderSetupSurface';
import { formatBridgeVersion, formatLatestVersion } from '../settings/bridgeUpdate';
import BridgeProfileInventory from '../settings/BridgeProfileInventory';
import {
  EMPTY_IDENTITY_CHOICE,
  bridgeHasUpdate,
  identityPlan,
  installRowStatus,
  installRows,
  markSetupSeen,
  setupRail,
  setupProfileChoices,
  sunsetCandidates,
  sunsetFailureNote,
  type IdentityChoice,
  type SetupStep,
} from './setupWizardModel';
import { discoverClaudeProjects, newProjectsOnly, type DiscoveredProject, type SessionFs } from './sessionProjects';

const statusTone: Record<string, Tone> = { success: 'success', warning: 'warning', danger: 'danger', muted: 'neutral' };

function errText(err: unknown): string {
  const anyErr = err as any;
  return String(anyErr?.data?.error || anyErr?.error || anyErr?.message || err);
}

function finishSetup(userId: string, route = '/conversations/new') {
  markSetupSeen(userId);
  window.location.hash = buildRouteHash(route, '');
}

// ---------------------------------------------------------------------------

export default function SetupWizardPage({ userId: userIdProp = '' }: { userId?: string }) {
  // The same id the shell checks before sending a first-run user here.
  const userId = userIdProp || deviceVaultUserId();
  const caps = desktopCapabilities();
  const manager = caps.bridgeManager;
  const [step, setStep] = useState<SetupStep>('detect');
  const [alreadyConnected, setAlreadyConnected] = useState(false);
  const [bridgeId, setBridgeId] = useState('');
  const [approvedNote, setApprovedNote] = useState('');
  const rail = setupRail(step, alreadyConnected);
  const railIndex = rail.findIndex((item) => item.state === 'current');

  // The app's own enrollment hands its pairing code to this page, not /device/add.
  useEffect(() => overrideApprovalPageOpener(() => setStep('identity')), []);

  return (
    <div data-debug-id="setup-wizard-page" className="flex h-full min-h-0 flex-col bg-canvas text-primary">
      <header className="flex shrink-0 items-center justify-between gap-4 border-b border-subtle px-6 py-3">
        <div className="flex items-center gap-3">
          <span className="text-sm font-semibold text-primary">Ninjy</span>
          <span className="text-xs text-muted">Set up this machine</span>
        </div>
        <Button size="sm" variant="ghost" data-debug-id="setup-skip-btn" onClick={() => finishSetup(userId, '/home')}>Skip setup</Button>
      </header>

      <div className="flex min-h-0 flex-1">
        <nav aria-label="Setup steps" data-debug-id="setup-rail" className="hidden w-64 shrink-0 overflow-y-auto border-r border-subtle px-4 py-8 md:block">
          <p className="mb-3 px-2 text-[11px] font-semibold uppercase tracking-wider text-faint">Setup · {railIndex + 1} of {rail.length}</p>
          <ol className="flex flex-col gap-0.5">
            {rail.map((item, index) => (
              <li
                key={item.id}
                data-debug-id={`setup-rail-${item.id}`}
                data-state={item.state}
                aria-current={item.state === 'current' ? 'step' : undefined}
                className={`flex items-start gap-3 rounded-lg px-2 py-2 ${item.state === 'current' ? 'bg-surface-raised' : ''}`}
              >
                <span
                  aria-hidden="true"
                  className={`mt-0.5 grid h-5 w-5 shrink-0 place-items-center rounded-full text-[11px] font-medium ${
                    item.state === 'done' ? 'bg-success-soft text-success' : item.state === 'current' ? 'bg-accent text-accent-fg' : 'border border-subtle text-faint'
                  }`}
                >
                  {item.state === 'done' ? <Icon name="check" size="sm" /> : index + 1}
                </span>
                <span className="min-w-0">
                  <span className={`block text-sm font-medium ${item.state === 'todo' ? 'text-muted' : 'text-primary'}`}>{item.label}</span>
                  <span className="block text-xs text-faint">{item.hint}</span>
                </span>
              </li>
            ))}
          </ol>
        </nav>

        {/* The right pane scrolls independently of the rail. */}
        <main data-debug-id="setup-pane" className="min-h-0 min-w-0 flex-1 overflow-y-auto">
          <div className="mx-auto flex w-full max-w-2xl flex-col gap-6 px-6 py-10">
            <p className="text-xs text-faint md:hidden">Step {railIndex + 1} of {rail.length} · {rail[railIndex]?.label}</p>
            {!manager ? (
              <NotDesktop legacy={caps.legacyBridgeManager} userId={userId} />
            ) : step === 'detect' || step === 'machine' || step === 'install' ? (
              <MachineSteps
                manager={manager}
                step={step}
                onStep={setStep}
                onConnected={(id) => { setAlreadyConnected(true); setBridgeId(id); }}
              />
            ) : step === 'identity' ? (
              <IdentityStep
                onDone={(id, note) => { setBridgeId(id); setApprovedNote(note); setStep('agents'); }}
                onBack={() => setStep('install')}
              />
            ) : step === 'agents' ? (
              <AgentsStep bridgeId={bridgeId} note={approvedNote} onNext={() => setStep('projects')} />
            ) : (
              <ProjectsStep bridgeId={bridgeId} onDone={() => finishSetup(userId)} />
            )}
          </div>
        </main>
      </div>
    </div>
  );
}

function StepHeading({ eyebrow, title, children }: { eyebrow: string; title: string; children?: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-2">
      <p className="text-[11px] font-semibold uppercase tracking-wider text-faint">{eyebrow}</p>
      <h1 data-debug-id="setup-step-title" className="font-serif text-3xl text-primary">{title}</h1>
      {children ? <p className="text-sm text-muted">{children}</p> : null}
    </div>
  );
}

function NotDesktop({ legacy, userId }: { legacy: boolean; userId: string }) {
  return (
    <>
      <StepHeading eyebrow="This machine" title="Set up a machine from the desktop app">
        {legacy
          ? 'This version of the Ninjy desktop app is too old to install a bridge from here. Update the app, then open setup again.'
          : 'Installing a bridge runs on the machine itself, from the Ninjy desktop app. You can also enroll a machine from the command line under Settings › Bridges.'}
      </StepHeading>
      <div className="flex flex-wrap gap-2">
        <Button variant="primary" data-debug-id="setup-not-desktop-bridges-btn" onClick={() => finishSetup(userId, '/settings/bridges')}>Open bridge settings</Button>
        <Button variant="ghost" data-debug-id="setup-not-desktop-continue-btn" onClick={() => finishSetup(userId)}>Continue to Ninjy</Button>
      </div>
    </>
  );
}

// ---------------------------------------------------------------------------
// Detect → connected (update / uninstall) or install + pair.
// ---------------------------------------------------------------------------

function MachineSteps({ manager, step, onStep, onConnected }: {
  manager: DesktopBridgeManagerApi;
  step: SetupStep;
  onStep: (step: SetupStep) => void;
  onConnected: (bridgeId: string) => void;
}) {
  const { data: bridgesData, refetch: refetchBridges, isLoading: bridgesLoading } = useListBridgesQuery();
  const bridges = useMemo(() => (Array.isArray(bridgesData?.bridges) ? bridgesData.bridges : []), [bridgesData]);
  const accountBridgeIds = useMemo(() => bridges.map((b: any) => String(b.bridge_id || b.id || '')).filter(Boolean), [bridges]);
  const session = useSyncExternalStore(subscribeDesktopBridgeSession, desktopBridgeSession);
  const [config, setConfig] = useState<DesktopBridgeConfig | null>(null);
  const [status, setStatus] = useState<DesktopBridgeStatus | null>(null);
  const [otherAccounts, setOtherAccounts] = useState(0);
  const [checks, setChecks] = useState(0);
  const [error, setError] = useState('');
  const [confirmUninstall, setConfirmUninstall] = useState(false);
  const [detectRun, setDetectRun] = useState(0);
  const [adoptedId, setAdoptedId] = useState('');
  const [profiles, setProfiles] = useState<DesktopBridgeStatus[]>([]);
  const [profile, setProfile] = useState('');
  const [customProfile, setCustomProfile] = useState(false);
  const profileChoices = setupProfileChoices(profiles);
  const profileError = bridgeProfileError(profile) || (profiles.some((p) => (p.profile || '') === profile && p.enrolled)
    ? 'This profile is already enrolled. Choose a separate profile for your account.' : '');

  useEffect(() => { attachDesktopBridgeSession(manager); }, [manager]);
  useEffect(() => {
    void manager.getConfig().then(setConfig).catch((err) => setError(errText(err)));
  }, [manager]);

  // Detect: is the signed-in account's bridge installed on this machine?
  useEffect(() => {
    if (!config || bridgesLoading) return;
    if (!config.supported) { setError('This platform cannot run a Ninjy bridge.'); return; }
    if (desktopBridgeSession().operation === 'setup') { onStep('install'); return; }
    let cancelled = false;
    setChecks(1);
    void (async () => {
      try {
        const listed = await manager.list();
        if (!listed.ok) throw new Error(listed.error || 'Unable to list the bridges on this machine.');
        if (cancelled) return;
        setChecks(2);
        const ids = adoptedId ? [...accountBridgeIds, adoptedId] : accountBridgeIds;
        const own = accountBridgeProfile(listed.profiles, config.hubUrl, ids);
        const detected = installedHubProfiles(listed.profiles, config.hubUrl);
        setProfiles(detected);
        setProfile(setupProfileChoices(detected)[0]);
        setCustomProfile(false);
        setOtherAccounts(otherAccountProfiles(listed.profiles, config.hubUrl, ids).length);
        const next = own ? await manager.getStatus({ hub: config.hubUrl, profile: String(own.profile || '') }) : null;
        if (cancelled) return;
        setChecks(3);
        setStatus(next);
        if (next?.installed) {
          onConnected(String(next.bridge_id || own?.bridge_id || ''));
          onStep('machine');
        } else {
          onStep('install');
        }
      } catch (err) {
        if (!cancelled) setError(errText(err));
      }
    })();
    return () => { cancelled = true; };
    // Re-detect only on an explicit request (after uninstall / setup), not on every bridge-list patch.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [config, bridgesLoading, detectRun]);

  // A finished update / uninstall / setup re-detects; a finished setup adopts its bridge id.
  const finishedSeen = useRef(session.finished);
  useEffect(() => {
    if (session.finished === finishedSeen.current) return;
    finishedSeen.current = session.finished;
    const final = session.finalStatus as DesktopBridgeStatus | null;
    if (session.lastRun?.kind === 'setup' && final?.bridge_id) setAdoptedId(String(final.bridge_id));
    void refetchBridges();
    if (session.lastRun?.kind === 'update' && final) { setStatus(final); return; }
    if (session.lastRun?.kind === 'uninstall' && !session.wizard.failedStep) { setStatus(null); setDetectRun((n) => n + 1); }
  }, [session.finished, session.finalStatus, session.lastRun, session.wizard.failedStep, refetchBridges]);

  const run = async (kind: 'setup' | 'update' | 'uninstall') => {
    if (!config) return;
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

  if (step === 'detect') {
    const items = ['Looking for a bridge on this machine', 'Checking its service', 'Matching it to your account'];
    return (
      <>
        <StepHeading eyebrow="This machine" title="Checking this machine">
          Looking for a Ninjy bridge already running here, so you don't set it up twice.
        </StepHeading>
        <ul data-debug-id="setup-detect-checks" className="rounded-xl border border-subtle bg-surface px-4">
          {items.map((label, index) => (
            <li key={label} className="flex items-center gap-3 border-b border-subtle py-3 text-sm last:border-b-0">
              {index < checks - 1 || (checks === 3 && index === 2)
                ? <Icon name="check" size="md" className="text-success" />
                : index === checks - 1 ? <Spinner size="sm" /> : <span className="grid h-4 w-4 place-items-center"><span className="h-1.5 w-1.5 rounded-full bg-neutral-soft" /></span>}
              <span className={index < checks ? 'text-primary' : 'text-muted'}>{label}</span>
            </li>
          ))}
        </ul>
        {error ? (
          <div data-debug-id="setup-detect-error" className="flex flex-col gap-3">
            <Alert tone="danger">{error}</Alert>
            <div><Button variant="secondary" data-debug-id="setup-detect-retry-btn" onClick={() => { setError(''); setDetectRun((n) => n + 1); }}>Check again</Button></div>
          </div>
        ) : null}
      </>
    );
  }

  if (step === 'machine') {
    const row = bridges.find((b: any) => String(b.bridge_id || b.id || '') === String(status?.bridge_id || ''));
    const label = desktopBridgeStatusLabel(status);
    const busy = Boolean(session.operation);
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
          {session.lastRun?.kind === 'update' && (updating || session.log.length) ? (
            <div className="border-t border-subtle p-4">
              <p className="mb-2 flex items-center gap-2 text-sm font-medium">
                {updating ? <><Spinner size="sm" /> Updating the bridge…</> : session.wizard.failedStep ? <span className="text-danger">Update failed{session.wizard.error ? `: ${session.wizard.error}` : ''}</span> : <><Icon name="check" size="md" className="text-success" /> Updated</>}
              </p>
              <LogView lines={session.log} debugId="setup-update-log" />
            </div>
          ) : null}
        </section>

        <BridgeProfileInventory profiles={profiles} accountBridgeIds={accountBridgeIds} debugId="setup-detected-profiles" />

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
              <Button variant="secondary" data-debug-id="setup-machine-continue-btn" disabled={busy} onClick={() => onStep('agents')}>Continue without updating</Button>
            </>
          ) : (
            <Button variant="primary" data-debug-id="setup-machine-continue-btn" disabled={busy} onClick={() => onStep('agents')}>Continue</Button>
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
          <BridgeProfileInventory profiles={profiles} accountBridgeIds={accountBridgeIds} debugId="setup-detected-profiles" />
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
              <dd className="px-4 py-3"><span data-debug-id="setup-install-hub" className="font-mono text-primary">{config?.hubUrl}</span></dd>
            </dl>
          </section>
          {otherAccounts > 0 ? (
            <p data-debug-id="setup-install-other-accounts" className="text-xs text-muted">
              {otherAccounts === 1 ? 'Another Ninjy account has a bridge' : `${otherAccounts} other Ninjy accounts have bridges`} on this machine. Setup installs a separate bridge for your account; theirs keeps running untouched.
            </p>
          ) : null}
          <div className="flex flex-wrap items-center gap-3">
            <Button variant="primary" size="lg" data-debug-id="setup-install-btn" leading={<Icon name="download" size="sm" />} disabled={!config || Boolean(profileError) || (customProfile && !profile)} onClick={() => void run('setup')}>Install and enroll</Button>
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
          {wizard.pairing ? <Button variant="primary" data-debug-id="setup-install-identity-btn" onClick={() => onStep('identity')}>Choose bridge identity</Button> : null}
          <Button variant="ghost" data-debug-id="setup-install-cancel-btn" onClick={() => void manager.cancel()}>Cancel</Button>
        </div>
      ) : setupRun && wizard.completed ? (
        <div><Button variant="primary" data-debug-id="setup-install-continue-btn" onClick={() => setDetectRun((n) => n + 1)}>Continue</Button></div>
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

function IdentityStep({ onDone, onBack }: { onDone: (bridgeId: string, note: string) => void; onBack: () => void }) {
  const entitlements = useEntitlements();
  const { data: bridgesData, refetch: refetchBridges } = useListBridgesQuery();
  const bridges = useMemo(() => (Array.isArray(bridgesData?.bridges) ? bridgesData.bridges : []), [bridgesData]);
  const [code, setCode] = useState('');
  const [review, setReview] = useState<Review | null>(null);
  const [lookupError, setLookupError] = useState('');
  const [choice, setChoice] = useState<IdentityChoice>(EMPTY_IDENTITY_CHOICE);
  const [newLabel, setNewLabel] = useState('');
  const [pendingCount, setPendingCount] = useState(0);
  const [waitingBridgeId, setWaitingBridgeId] = useState('');
  const [cancelError, setCancelError] = useState('');
  const [cancelling, setCancelling] = useState(false);
  const pendingAttempt = useRef('');
  const enrollmentWait = useRef<AbortController | null>(null);
  const seeded = useRef(false);
  const [phase, setPhase] = useState<{ kind: 'choose' } | { kind: 'working'; message: string } | { kind: 'reconnecting'; bridgeId: string; label: string; approved: string } | { kind: 'failed'; message: string }>({ kind: 'choose' });

  // The pairing code this app's own setup printed, taken once.
  useEffect(() => {
    const take = () => { const handed = takePendingApprovalCode(); if (handed) setCode(handed); };
    take();
    return subscribePendingApprovalCode(take);
  }, []);

  useEffect(() => {
    if (!code) return;
    let cancelled = false;
    setReview(null);
    setChoice(EMPTY_IDENTITY_CHOICE);
    setPhase({ kind: 'choose' });
    setCancelError('');
    pendingAttempt.current = '';
    seeded.current = false;
    setLookupError('');
    void lookUpPairing(code, deviceVaultUserId()).then((found) => {
      if (cancelled) return;
      if (found.browser) { setLookupError('That pairing code belongs to a browser, not this machine’s bridge.'); return; }
      setReview(found);
      setNewLabel(found.label);
    }).catch((err) => { if (!cancelled) setLookupError(errText(err)); });
    return () => { cancelled = true; };
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
          onReady={() => onDone(phase.bridgeId, phase.approved)}
          onSkip={() => onDone(phase.bridgeId, phase.approved)}
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

// ---------------------------------------------------------------------------
// Agents and projects.
// ---------------------------------------------------------------------------

function AgentsStep({ bridgeId, note, onNext }: { bridgeId: string; note: string; onNext: () => void }) {
  return (
    <>
      <StepHeading eyebrow="Agents" title="Agents on this machine">
        We look for agent CLIs on this machine. Turn on the ones Ninjy should launch.
      </StepHeading>
      {note ? <p data-debug-id="setup-agents-note" className="text-xs text-muted">{note}</p> : null}
      {bridgeId ? (
        <ProviderSetupSurface bridgeId={bridgeId} mode="enrollment" variant="compact" missingAsRows onApply={onNext} />
      ) : (
        <div className="flex flex-col gap-3">
          <Alert tone="warning">This machine's bridge id is not known yet. You can enable agents later in Settings › Providers.</Alert>
          <div><Button variant="primary" data-debug-id="setup-agents-continue-btn" onClick={onNext}>Continue</Button></div>
        </div>
      )}
    </>
  );
}

const bridgeSessionFs = (bridgeId: string): SessionFs => ({
  list: (path) => cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/fs?path=${encodeURIComponent(path)}`),
  stat: (path) => cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/fs/stat?path=${encodeURIComponent(path)}`),
});

function ProjectsStep({ bridgeId, onDone }: { bridgeId: string; onDone: () => void }) {
  const { data: projectsData, isLoading: projectsLoading } = useListProjectsQuery();
  const [createProject] = useCreateProjectMutation();
  const [setBridgePath] = useSetProjectBridgePathMutation();
  const [found, setFound] = useState<DiscoveredProject[] | null>(null);
  const [scanError, setScanError] = useState('');
  const [selected, setSelected] = useState<Record<string, boolean>>({});
  const [rowErrors, setRowErrors] = useState<Record<string, string>>({});
  const [importing, setImporting] = useState(false);

  const existing = useMemo(() => {
    const raw: any = projectsData;
    return Array.isArray(raw) ? raw : Array.isArray(raw?.projects) ? raw.projects : [];
  }, [projectsData]);

  useEffect(() => {
    if (!bridgeId || projectsLoading) return;
    let cancelled = false;
    void discoverClaudeProjects(bridgeSessionFs(bridgeId)).then((all) => {
      if (cancelled) return;
      const fresh = newProjectsOnly(all, existing, bridgeId);
      setFound(fresh);
      setSelected(Object.fromEntries(fresh.map((p) => [p.path, true])));
    }).catch((err) => { if (!cancelled) { setScanError(errText(err)); setFound([]); } });
    return () => { cancelled = true; };
  }, [bridgeId, projectsLoading, existing]);

  const chosen = (found || []).filter((p) => selected[p.path]);
  const all = Boolean(found?.length) && chosen.length === found?.length;

  const importChosen = async () => {
    setImporting(true);
    const errors: Record<string, string> = {};
    for (const project of chosen) {
      try {
        const created = await createProject({ name: project.name }).unwrap();
        const projectId = String(created?.project_id || created?.projectId || created?.project?.project_id || '');
        if (!projectId) throw new Error('The hub did not return the new project id.');
        await setBridgePath({ projectId, bridgeId, path: project.path }).unwrap();
      } catch (err) {
        errors[project.path] = errText(err);
      }
    }
    setImporting(false);
    setRowErrors(errors);
    if (Object.keys(errors).length === 0) onDone();
    else setSelected(Object.fromEntries(Object.keys(errors).map((path) => [path, true])));
  };

  return (
    <>
      <StepHeading eyebrow="Projects" title="Bring in projects you already work on">
        Found in your Claude Code session history on this machine. Each folder becomes a project on this bridge; the sessions stay where they are.
      </StepHeading>
      {found === null ? (
        <p data-debug-id="setup-projects-scanning" className="flex items-center gap-2 text-sm text-muted"><Spinner size="sm" /> Looking through past sessions…</p>
      ) : found.length === 0 ? (
        <div data-debug-id="setup-projects-empty" className="flex flex-col gap-3">
          <p className="text-sm text-muted">{scanError ? `Couldn't read session history: ${scanError}` : 'No past Claude Code sessions with a project folder that isn’t already in Ninjy.'}</p>
          <div><Button variant="primary" data-debug-id="setup-projects-continue-btn" onClick={onDone}>Continue</Button></div>
        </div>
      ) : (
        <>
          <section data-debug-id="setup-projects-list" className="rounded-xl border border-subtle bg-surface">
            <label className="flex items-center gap-3 border-b border-subtle px-4 py-3">
              <input
                type="checkbox"
                data-debug-id="setup-projects-select-all"
                checked={all}
                disabled={importing}
                onChange={() => setSelected(Object.fromEntries((found || []).map((p) => [p.path, !all])))}
              />
              <span className="flex-1 text-xs font-medium text-muted">{chosen.length} of {found.length} selected</span>
            </label>
            {found.map((project) => (
              <div key={project.path} className="border-b border-subtle px-4 py-3 last:border-b-0">
                <label data-debug-id={`setup-projects-row-${project.name}`} className="flex cursor-pointer items-center gap-3">
                  <input
                    type="checkbox"
                    data-debug-id={`setup-projects-check-${project.name}`}
                    checked={Boolean(selected[project.path])}
                    disabled={importing}
                    onChange={(event) => { const value = event.target.checked; setSelected((s) => ({ ...s, [project.path]: value })); }}
                  />
                  <span className="min-w-0 flex-1">
                    <span className="block text-sm font-semibold text-primary">{project.name}</span>
                    <span className="block truncate font-mono text-xs text-muted" title={project.path}>{project.path}</span>
                    <span className="block text-xs text-faint">{project.sessions} {project.sessions === 1 ? 'session' : 'sessions'} · {project.source}</span>
                  </span>
                </label>
                {rowErrors[project.path] ? <p role="alert" className="mt-1 pl-7 text-xs text-danger">{rowErrors[project.path]}</p> : null}
              </div>
            ))}
          </section>
          <p className="text-xs text-faint">Codex session history isn't read yet; add those folders from Projects later.</p>
          <div className="flex flex-wrap gap-2">
            <Button variant="primary" data-debug-id="setup-projects-import-btn" loading={importing} disabled={chosen.length === 0 || importing} onClick={() => void importChosen()}>
              Import {chosen.length} {chosen.length === 1 ? 'project' : 'projects'}
            </Button>
            <Button variant="ghost" data-debug-id="setup-projects-skip-btn" disabled={importing} onClick={onDone}>Skip for now</Button>
          </div>
        </>
      )}
    </>
  );
}
