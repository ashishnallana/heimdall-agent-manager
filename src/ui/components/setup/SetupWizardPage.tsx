// /setup — first-run setup for this machine (desktop app). See setupWizardModel.ts
// for the flow. The left rail is fixed; the right pane scrolls on its own.
//
// Security notes: the pairing code is the one THIS app's own `ham-bridge setup`
// printed, handed over in memory (desktopBridgeSession) and looked up exactly as on
// /device/add (lookUpPairing: key_mac checked under the code, hub origin checked
// against this hub's aliases). Approval runs the same signed sequence as /device/add
// (bridgeApproval.ts); the user still reviews and approves.

import { useEffect, useMemo, useRef, useState } from 'react';
import { Alert, Button, Icon, Spinner } from '@ui';
import { hasBridgeIdentityReview } from '../../bridge/useBridgeIdentityState';
import { desktopCapabilities } from '../../bridge/desktopBridge';
import { overrideApprovalPageOpener } from '../../bridge/desktopBridgeSession';

import { useCreateProjectMutation, useListProjectsQuery, useSetProjectBridgePathMutation } from '../../api/endpoints/projects';
import { cookieJsonFetch } from '../../api/cookieFetch';

import { buildRouteHash } from '../../utils/appLocation';
import { deviceVaultUserId } from '../../services/deviceVault';
import { lookUpPairing } from '../devices/DeviceApprovalPage';

import UpgradePrompt from '../billing/UpgradePrompt';
import ProviderSetupSurface from '../providers/ProviderSetupSurface';

import BridgeProfileInventory from '../settings/BridgeProfileInventory';
import { markSetupSeen, setupRail, type SetupStep } from './setupWizardModel';
import { discoverSessionProjects, importSessionProjects, loadProjectBridgeMappings, sessionTimeLabel, newProjectsOnly, type DiscoveredProject, type ImportedSessionProjects, type SessionFs } from './sessionProjects';

import BridgeOperationRail from '../bridge/BridgeOperationRail';
import { StepHeading, MachineSteps, IdentityStep } from '../bridge/LocalBridgeFlow';

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
  const [step, setStep] = useState<SetupStep>(() => hasBridgeIdentityReview() ? 'identity' : 'detect');
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
        <BridgeOperationRail items={rail} label="Setup" debugId="setup-rail" className="hidden w-64 shrink-0 overflow-y-auto border-r border-subtle px-4 py-8 md:block" />

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

export function ProjectsStep({ bridgeId, onDone }: { bridgeId: string; onDone: () => void }) {
  const { data: projectsData, isFetching: projectsLoading, isError: projectsFailed, refetch: refetchProjects } = useListProjectsQuery({ allPages: true });
  const [createProject] = useCreateProjectMutation();
  const [setBridgePath] = useSetProjectBridgePathMutation();
  const [found, setFound] = useState<DiscoveredProject[] | null>(null);
  const [scanError, setScanError] = useState('');
  const [selected, setSelected] = useState<Record<string, boolean>>({});
  const [rowErrors, setRowErrors] = useState<Record<string, string>>({});
  const [importing, setImporting] = useState(false);
  const [scanTruncated, setScanTruncated] = useState(false);
  const [retrying, setRetrying] = useState(false);
  const [scanVersion, setScanVersion] = useState(0);
  const importIds = useRef<ImportedSessionProjects>({});

  const existing = useMemo(() => {
    const raw: any = projectsData;
    return Array.isArray(raw) ? raw : Array.isArray(raw?.projects) ? raw.projects : [];
  }, [projectsData]);

  useEffect(() => {
    if (!bridgeId) return;
    let cancelled = false;
    setFound(null);
    setScanTruncated(false);
    setScanError('');
    setSelected({});
    if (projectsLoading || retrying) return;
    if (projectsFailed) {
      setScanError('Could not check existing projects.');
      setFound([]);
      return;
    }
    void cookieJsonFetch(`/bridges/${encodeURIComponent(bridgeId)}/session-projects`).then(async (metadata) => {
      if (!cancelled) setScanTruncated(Boolean(metadata?.truncated));
      return discoverSessionProjects(metadata, bridgeSessionFs(bridgeId));
    }).then(async (all) => {
      const mappings = await loadProjectBridgeMappings(existing, (projectId) =>
        cookieJsonFetch(`/projects/${encodeURIComponent(projectId)}`), { bridgeId, stat: bridgeSessionFs(bridgeId).stat });
      if (cancelled) return;
      const fresh = newProjectsOnly(all, mappings, bridgeId);
      setFound(fresh);
      setSelected(Object.fromEntries(fresh.map((p) => [p.path, true])));
    }).catch((err) => { if (!cancelled) { setScanError(errText(err)); setFound([]); } });
    return () => { cancelled = true; };
  }, [bridgeId, projectsLoading, projectsFailed, existing, retrying, scanVersion]);

  const retryDiscovery = async () => {
    setFound(null);
    setRetrying(true);
    try {
      await refetchProjects().unwrap();
    } catch {
      // The query error is rendered by the discovery effect after retry settles.
    } finally {
      setScanVersion((version) => version + 1);
      setRetrying(false);
    }
  };

  const chosen = (found || []).filter((p) => selected[p.path]);
  const all = Boolean(found?.length) && chosen.length === found?.length;

  const importChosen = async () => {
    setImporting(true);
    const { imported, errors } = await importSessionProjects(chosen, existing.map((p: any) => String(p.name || '')), importIds.current, {
      create: async (name, path, description) => {
        const created = await createProject({ name, default_path: path, ...(description ? { description } : {}) }).unwrap();
        return String(created?.project_id || created?.projectId || created?.project?.project_id || '');
      },
      attach: async (projectId, path) => { await setBridgePath({ projectId, bridgeId, path }).unwrap(); },
      errorText: errText,
    });
    setImporting(false);
    setRowErrors(errors);
    setFound((rows) => rows?.filter((p) => !imported.has(p.path)) || []);
    if (Object.keys(errors).length === 0) onDone();
    else setSelected(Object.fromEntries(Object.keys(errors).map((path) => [path, true])));
  };

  return (
    <>
      <StepHeading eyebrow="Projects" title="Bring in projects you already work on">
        Found in your Claude Code and Codex session history on this machine. Each folder becomes a project on this bridge; the sessions stay where they are.
      </StepHeading>
      {scanTruncated ? <p role="status" className="text-xs text-faint">Showing the session history found before the scan limit.</p> : null}
      {found === null ? (
        <p data-debug-id="setup-projects-scanning" className="flex items-center gap-2 text-sm text-muted"><Spinner size="sm" /> Looking through past sessions…</p>
      ) : found.length === 0 ? (
        <div data-debug-id="setup-projects-empty" className="flex flex-col gap-3">
          <p className="text-sm text-muted">{scanError ? `Couldn't read session history: ${scanError}` : 'No past Claude Code or Codex sessions with a project folder that isn’t already in Ninjy.'}</p>
          {scanError ? <div><Button variant="primary" data-debug-id="setup-projects-retry-btn" onClick={() => void retryDiscovery()}>Retry discovery</Button></div> : null}
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
                <label data-debug-id={`setup-projects-row-${encodeURIComponent(project.path)}`} className="flex cursor-pointer items-center gap-3">
                  <input
                    type="checkbox"
                    data-debug-id={`setup-projects-check-${encodeURIComponent(project.path)}`}
                    checked={Boolean(selected[project.path])}
                    disabled={importing}
                    onChange={(event) => { const value = event.target.checked; setSelected((s) => ({ ...s, [project.path]: value })); }}
                  />
                  <span className="min-w-0 flex-1">
                    <span className="block text-sm font-semibold text-primary">{project.name}</span>
                    <span className="block truncate font-mono text-xs text-muted" title={project.path}>{project.path}</span>
                    {project.description ? <span className="block text-xs text-muted">{project.description}</span> : null}
                    <span className="block text-xs text-faint">{project.sessions} {project.sessions === 1 ? 'session' : 'sessions'} · {project.source}</span>
                    <span className="block text-xs text-faint">{sessionTimeLabel(project.lastSessionAt)}</span>
                  </span>
                </label>
                {rowErrors[project.path] ? <p role="alert" className="mt-1 pl-7 text-xs text-danger">{rowErrors[project.path]}</p> : null}
              </div>
            ))}
          </section>
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
