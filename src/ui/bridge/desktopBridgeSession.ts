// The desktop app's Bridge operation, kept outside any component (Electron only).
//
// Settings > Bridges starts setup / re-enroll here. When enrollment prints its
// pairing code, the app opens its own /device/add page (REQ-ENR-INAPP-1) and hands
// the code over in memory: it is never put in a URL, so a link cannot carry one
// (DeviceApprovalPage: "Links never carry a code"), and only a code this app's own
// enrollment printed is ever looked up without typing. Because the card unmounts
// while the approval page is open, the wizard state lives here and keeps following
// the operation's events; the card shows it again on return.

import {
  type DesktopBridgeEvent,
  type DesktopBridgeManagerApi,
  type DesktopBridgeOperation,
  type DesktopBridgeOperationOptions,
  type WizardModel,
  initialWizard,
  reduceWizard,
  startWizard,
} from './desktopBridge';

export interface DesktopBridgeSession {
  operation: DesktopBridgeOperation | '';
  lastRun: { kind: DesktopBridgeOperation; options: DesktopBridgeOperationOptions } | null;
  wizard: WizardModel;
  log: string[];
  /** Bumped on every 'complete' / 'error', so the card refreshes its status. */
  finished: number;
  /** The status a 'complete' event carried, if any. */
  finalStatus: any;
}

type Listener = () => void;

const LOG_LINES = 500;

let state: DesktopBridgeSession = { operation: '', lastRun: null, wizard: initialWizard(), log: [], finished: 0, finalStatus: null };
let attached: DesktopBridgeManagerApi | null = null;
const listeners = new Set<Listener>();
let pendingApprovalCode = '';
let openApprovalPage: (() => void) | null = null;
// An open /device/add page takes a newly handed code (a reissued one) at once.
const codeListeners = new Set<Listener>();

function set(next: Partial<DesktopBridgeSession>) {
  state = { ...state, ...next };
  listeners.forEach((listener) => listener());
}

export function desktopBridgeSession(): DesktopBridgeSession { return state; }

export function subscribeDesktopBridgeSession(listener: Listener): () => void {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}

/** The pure event step, exported for tests. */
export function reduceSession(current: DesktopBridgeSession, event: DesktopBridgeEvent): DesktopBridgeSession {
  let log = current.log;
  if (event.type === 'output') log = [...log, event.message];
  if (event.type === 'progress' && event.message) log = [...log, `[${event.step}] ${event.state}: ${event.message}`];
  if (event.type === 'error') log = [...log, `ERROR: ${event.message}`];
  const next = { ...current, log: log.slice(-LOG_LINES), wizard: reduceWizard(current.wizard, event) };
  if (event.type === 'complete' || event.type === 'error') {
    return { ...next, operation: '', finished: current.finished + 1, finalStatus: event.type === 'complete' ? (event as any).status || null : null };
  }
  return next;
}

function onEvent(event: DesktopBridgeEvent) {
  const pairingForThisRun = event.type === 'pairing' && Boolean(event.code) && (state.operation === 'setup' || state.operation === 'reenroll');
  set(reduceSession(state, event));
  if (pairingForThisRun) openApprovalForCode(event.code);
}

/** Open this app's /device/add for a code its own enrollment printed. */
export function openApprovalForCode(code: string): boolean {
  if (!code || !openApprovalPage) return false;
  pendingApprovalCode = code;
  openApprovalPage();
  codeListeners.forEach((listener) => listener());
  return true;
}

/** /device/add listens while mounted; the listener calls takePendingApprovalCode(). */
export function subscribePendingApprovalCode(listener: Listener): () => void {
  codeListeners.add(listener);
  return () => { codeListeners.delete(listener); };
}

/** Follow `manager`'s events for the life of the window (idempotent). */
export function attachDesktopBridgeSession(manager: DesktopBridgeManagerApi) {
  if (attached === manager) return;
  attached = manager;
  manager.onEvent(onEvent);
}

/** How the app opens /device/add for a pairing code (set once by the shell). */
export function setApprovalPageOpener(open: (() => void) | null) { openApprovalPage = open; }

/** The code the app's own enrollment printed, once; '' when there is none. */
export function takePendingApprovalCode(): string {
  const code = pendingApprovalCode;
  pendingApprovalCode = '';
  return code;
}

export async function runDesktopBridgeOperation(manager: DesktopBridgeManagerApi, kind: DesktopBridgeOperation, target: any, options: DesktopBridgeOperationOptions = {}): Promise<string> {
  attachDesktopBridgeSession(manager);
  pendingApprovalCode = '';
  set({ lastRun: { kind, options }, log: [], operation: kind, wizard: startWizard() });
  // inAppApproval: this app opens /device/add itself, so the main process skips
  // the external browser (an older app ignores it and opens both).
  const result = await manager.run(kind, target, { ...options, inAppApproval: true }).catch((err: any) => ({ ok: false, error: String(err?.message || err) }));
  // Progress and the final state arrive as events; a refusal (another
  // operation running, invalid Hub URL) arrives only here.
  if (!result.ok && result.error) {
    set({ operation: '' });
    return result.error;
  }
  return '';
}

/** Tests only. */
export function resetDesktopBridgeSessionForTests() {
  state = { operation: '', lastRun: null, wizard: initialWizard(), log: [], finished: 0, finalStatus: null };
  attached = null;
  listeners.clear();
  pendingApprovalCode = '';
  openApprovalPage = null;
  codeListeners.clear();
}
