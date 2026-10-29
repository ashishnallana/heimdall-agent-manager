// REQ-ENR-9/10, F24: the renderer contract for the desktop app's Bridge manager
// (src/ui/electron/bridgeManager.cts via preload.cts). The main process drives
// `ham-bridge setup|update|enroll|uninstall|status|list --json-progress`; the
// renderer sees structured status and progress only. Browser builds have no
// `bridgeManager` and show the Hub's bridge records with Update only (ENR-8).

/** ham-bridge `status --json` state word, plus the app's own unsupported/unknown. */
export type DesktopBridgeState =
  | 'not_installed' | 'not_enrolled' | 'needs_reenrollment' | 'stopped' | 'disconnected' | 'connected'
  | 'unsupported' | 'unknown';

export interface DesktopBridgeStatus {
  supported: boolean;
  busy: boolean;
  operation: string;
  installed: boolean;
  state: DesktopBridgeState;
  hub?: string;
  profile?: string;
  service?: string;
  enrolled?: boolean;
  running?: boolean;
  connected?: boolean;
  version?: string;
  bridge_id?: string;
  needs_reenrollment?: boolean;
  reenroll_reason?: string;
  bundledVersion?: string;
  error: string;
}

export interface DesktopBridgeConfig {
  ok: boolean;
  supported: boolean;
  platform: string;
  hubUrl: string;
  defaultHubUrl: string;
  bundledVersion: string;
  error?: string;
}

export interface DesktopBridgeTarget { hub?: string; profile?: string; service?: string }

export type DesktopBridgeOperation = 'setup' | 'update' | 'reenroll' | 'uninstall';

export interface DesktopBridgeOperationOptions { bridgeId?: string; purge?: boolean; replaceOtherAccount?: boolean }

/** One line of `--json-progress` (plus the app's own `download` step). */
export interface DesktopBridgeProgress {
  type: 'progress';
  step: string;
  state: 'start' | 'progress' | 'ok' | 'skipped' | 'retry' | 'failed' | 'rollback' | 'warning' | 'done';
  pct?: number;
  message?: string;
  log?: string;
  attempt?: number;
  failure?: string;
}

export type DesktopBridgeEvent =
  | DesktopBridgeProgress
  | { type: 'output'; message: string }
  | { type: 'pairing'; url: string; code: string; issue?: number }
  | { type: 'complete'; status?: DesktopBridgeStatus }
  | { type: 'error'; message: string; step?: string; cancelled?: boolean; timedOut?: boolean; rolledBack?: boolean };

export interface DesktopBridgeManagerApi {
  getConfig(): Promise<DesktopBridgeConfig>;
  setHubUrl(hubUrl: string): Promise<{ ok: boolean; hubUrl?: string; error?: string }>;
  getStatus(target?: DesktopBridgeTarget): Promise<DesktopBridgeStatus>;
  list(): Promise<{ ok: boolean; profiles?: DesktopBridgeStatus[]; error?: string }>;
  run(kind: DesktopBridgeOperation, target?: DesktopBridgeTarget, options?: DesktopBridgeOperationOptions): Promise<{ ok: boolean; error?: string }>;
  cancel(): Promise<{ ok: boolean }>;
  openLog(logPath: string): Promise<{ ok: boolean; error?: string }>;
  onEvent(callback: (event: DesktopBridgeEvent) => void): () => void;
}

const BRIDGE_MANAGER_METHODS = ['getConfig', 'setHubUrl', 'getStatus', 'list', 'run', 'cancel', 'openLog', 'onEvent'] as const;

/**
 * F24: the one desktop-capability check. Everything that behaves differently
 * in the desktop app asks this helper instead of probing `window.odinApi`.
 */
export interface DesktopCapabilities {
  /** Running inside the Heimdall desktop app (the preload API is present). */
  desktop: boolean;
  bridgeManager: DesktopBridgeManagerApi | null;
  /**
   * The desktop app's preload exposes an older bridgeManager (<= v0.5.21:
   * getStatus/installBundled/startEnrollment) than this UI speaks. The Hub
   * serves the UI, so a newer UI routinely meets an older installed app; such
   * an app gets bridgeManager null plus this flag, never a half-matching API.
   */
  legacyBridgeManager: boolean;
  notifications: { supported: boolean; show: (plan: { title: string; body: string; tag: string; route: string }) => Promise<boolean> } | null;
  openExternal: ((url: string) => Promise<{ ok: boolean; error?: string }>) | null;
  daemonUrl: string;
  /** Read-only window chrome state (see hooks/useWindowChrome.ts), or null. */
  windowChrome: unknown;
}

export function desktopCapabilities(): DesktopCapabilities {
  let api: any = null;
  try { api = typeof window === 'undefined' ? null : (window as any).odinApi || null; } catch (_err) { api = null; }
  const manager = api?.bridgeManager || null;
  const current = Boolean(manager) && BRIDGE_MANAGER_METHODS.every((name) => typeof manager[name] === 'function');
  return {
    desktop: Boolean(api),
    bridgeManager: current ? manager as DesktopBridgeManagerApi : null,
    legacyBridgeManager: Boolean(manager) && !current,
    notifications: api?.notifications || null,
    openExternal: typeof api?.openExternal === 'function' ? api.openExternal : null,
    daemonUrl: String(api?.daemonUrl || ''),
    windowChrome: api?.windowChrome && typeof api.windowChrome === 'object' ? api.windowChrome : null,
  };
}

export function desktopBridgeManager(): DesktopBridgeManagerApi | null {
  return desktopCapabilities().bridgeManager;
}

export type BridgeStatusTone = 'success' | 'warning' | 'danger' | 'muted';

export function desktopBridgeStatusLabel(status: DesktopBridgeStatus | null | undefined): { label: string; tone: BridgeStatusTone } {
  if (!status?.supported) return { label: 'Not available on this platform', tone: 'muted' };
  if (status.busy) return { label: 'Working…', tone: 'warning' };
  switch (status.state) {
    case 'connected': return { label: 'Connected', tone: 'success' };
    case 'disconnected': return { label: 'Running, not connected', tone: 'warning' };
    case 'stopped': return { label: 'Stopped', tone: 'danger' };
    case 'not_enrolled': return { label: 'Installed, not enrolled', tone: 'warning' };
    case 'needs_reenrollment': return { label: 'Needs re-enrollment', tone: 'danger' };
    case 'not_installed': return { label: 'Not installed', tone: 'muted' };
    default: return { label: status.error ? 'Status unavailable' : 'Unknown', tone: status.error ? 'danger' : 'muted' };
  }
}

// ---------------------------------------------------------------------------
// Setup wizard model (pure, unit-tested): Download → Install → Enroll →
// Providers → Done, folded from the operation's progress events.
// ---------------------------------------------------------------------------

export type WizardStepId = 'download' | 'install' | 'enroll' | 'providers' | 'done';
export type WizardStepState = 'pending' | 'running' | 'recovering' | 'ok' | 'skipped' | 'failed';

export interface WizardStep {
  id: WizardStepId;
  label: string;
  state: WizardStepState;
  message: string;
  /** Automatic recovery attempts ham-bridge made for this step (ENR-12). */
  recoveries: string[];
  log: string;
}

export interface WizardModel {
  steps: WizardStep[];
  pct: number;
  running: boolean;
  failedStep: WizardStepId | '';
  /** Manual Retry is offered only once automatic recovery is exhausted. */
  canRetry: boolean;
  pairing: { url: string; code: string } | null;
  error: string;
  cancelled: boolean;
  rolledBack: boolean;
  completed: boolean;
  /** F1: enrollment stopped because another account enrolled this machine. */
  otherAccount: boolean;
}

export const WIZARD_STEPS: { id: WizardStepId; label: string }[] = [
  { id: 'download', label: 'Download latest' },
  { id: 'install', label: 'Install' },
  { id: 'enroll', label: 'Enroll' },
  { id: 'providers', label: 'Providers' },
  { id: 'done', label: 'Done' },
];

/**
 * Maps a ham-bridge setup step onto the wizard step that shows it. ham-bridge
 * runs …ports, service, enroll, extensions, start, verify; start and verify
 * belong to the last row so the rows finish in order.
 */
export function wizardStepFor(step: string): WizardStepId | '' {
  switch (step) {
    case 'download': return 'download';
    case 'lock': case 'stage': case 'binaries': case 'config': case 'ports': case 'service': return 'install';
    case 'enroll': return 'enroll';
    case 'extensions': return 'providers';
    case 'start': case 'verify': case 'setup': return 'done';
    default: return '';
  }
}

export function initialWizard(): WizardModel {
  return {
    steps: WIZARD_STEPS.map((step) => ({ ...step, state: 'pending', message: '', recoveries: [], log: '' })),
    pct: 0, running: false, failedStep: '', canRetry: false, pairing: null, error: '', cancelled: false, rolledBack: false, completed: false, otherAccount: false,
  };
}

export function startWizard(): WizardModel {
  return { ...initialWizard(), running: true };
}

function updateStep(model: WizardModel, id: WizardStepId, patch: (step: WizardStep) => WizardStep): WizardModel {
  return { ...model, steps: model.steps.map((step) => (step.id === id ? patch(step) : step)) };
}

function markBefore(model: WizardModel, id: WizardStepId): WizardModel {
  const index = WIZARD_STEPS.findIndex((step) => step.id === id);
  return {
    ...model,
    steps: model.steps.map((step, i) => (i < index && (step.state === 'pending' || step.state === 'running' || step.state === 'recovering') ? { ...step, state: 'ok' } : step)),
  };
}

// `ham-bridge enroll` refuses, headless, to replace a bridge another Heimdall
// account enrolled until the user confirms (--replace-other-account).
export const OTHER_ACCOUNT_PATTERN = /enrolled as \S+ by another Heimdall account/;

// The ham-bridge step whose `ok` finishes a row made of several sub-steps.
const lastSubStep: Partial<Record<WizardStepId, string>> = { install: 'service', done: 'verify' };

/** Folds one operation event into the wizard model. */
export function reduceWizard(model: WizardModel, event: DesktopBridgeEvent): WizardModel {
  if (event.type === 'pairing') return { ...model, pairing: { url: event.url, code: event.code } };
  if (event.type === 'output') return OTHER_ACCOUNT_PATTERN.test(event.message) ? { ...model, otherAccount: true } : model;
  if (event.type === 'complete') {
    const done = model.steps.map((step) => ({ ...step, state: step.state === 'skipped' || step.state === 'failed' ? step.state : 'ok' as WizardStepState }));
    return { ...model, steps: done, pct: 100, running: false, completed: true, pairing: null };
  }
  if (event.type === 'error') {
    const running = model.steps.find((step) => step.state === 'running' || step.state === 'recovering');
    const failedId = (running?.id || wizardStepFor(event.step || '') || model.failedStep || 'install') as WizardStepId;
    const failed = updateStep(model, failedId, (step) => ({ ...step, state: 'failed', message: event.message || step.message }));
    return {
      ...failed,
      running: false,
      failedStep: failedId,
      // ham-bridge has already remediated and retried known failures before it
      // gives up, so a failure that reaches the UI has exhausted automatic
      // recovery; a cancel is not a failure to retry from.
      canRetry: !event.cancelled,
      error: event.message,
      cancelled: Boolean(event.cancelled),
      rolledBack: model.rolledBack || Boolean(event.rolledBack),
      pairing: null,
    };
  }
  const id = wizardStepFor(event.step);
  if (!id) return model;
  let next = markBefore({ ...model, pct: typeof event.pct === 'number' ? event.pct : model.pct }, id);
  const message = String(event.message || '');
  switch (event.state) {
    case 'start':
    case 'progress':
      next = updateStep(next, id, (step) => ({ ...step, state: step.state === 'recovering' ? 'recovering' : 'running', message: message || step.message }));
      break;
    case 'retry':
      next = updateStep(next, id, (step) => ({ ...step, state: 'recovering', message, recoveries: [...step.recoveries, message || `Retrying (${event.failure || 'recovering'})…`] }));
      break;
    case 'ok':
      // A sub-step finishing finishes its row only when it is the row's last.
      next = updateStep(next, id, (step) => ({ ...step, state: event.step === lastSubStep[id] || !lastSubStep[id] ? 'ok' : 'running', message: message || step.message }));
      break;
    case 'skipped':
      next = updateStep(next, id, (step) => ({ ...step, state: !lastSubStep[id] ? 'skipped' : event.step === lastSubStep[id] && step.state === 'running' ? 'ok' : step.state, message: message || step.message }));
      break;
    case 'warning':
      next = updateStep(next, id, (step) => ({ ...step, message }));
      break;
    case 'failed':
      next = { ...updateStep(next, id, (step) => ({ ...step, state: 'failed', message, log: event.log || step.log })), failedStep: id };
      break;
    case 'rollback':
      next = { ...next, rolledBack: true };
      break;
    case 'done':
      next = updateStep(next, 'done', (step) => ({ ...step, state: 'ok', message }));
      break;
  }
  if (event.log) next = updateStep(next, id, (step) => ({ ...step, log: event.log || step.log }));
  return next;
}
