// REQ-DMG-2 / REQ-BTOP-1: the narrow renderer contract for the macOS Bridge
// manager. The preload implements this with IPC; browser builds simply have no
// `bridgeManager` and continue to use Hub bridge records.

export type DesktopBridgeServiceState = 'not-installed' | 'stopped' | 'running' | 'error';

export interface DesktopBridgeStatus {
  supported: boolean;
  packaged: boolean;
  installed: boolean;
  enrolled: boolean;
  serviceState: DesktopBridgeServiceState;
  serviceName: string;
  hubUrl: string;
  installedVersion: string;
  bundledVersion: string;
  busy: boolean;
  error: string;
}
export type DesktopBridgeEnrollmentEvent = {
  type: 'output' | 'pairing' | 'complete' | 'error';
  message?: string;
  code?: string;
  url?: string;
};

export interface DesktopBridgeManagerApi {
  getStatus(): Promise<DesktopBridgeStatus>;
  installBundled(): Promise<{ ok: boolean; status: DesktopBridgeStatus; error?: string }>;
  startEnrollment(): Promise<{ ok: boolean; error?: string }>;
  onEnrollmentEvent(callback: (event: DesktopBridgeEnrollmentEvent) => void): () => void;
  onCheckUpdatesRequested(callback: () => void): () => void;
}

export function desktopBridgeManager(): DesktopBridgeManagerApi | null {
  if (typeof window === 'undefined') return null;
  return ((window as any).odinApi?.bridgeManager || null) as DesktopBridgeManagerApi | null;
}

export type BridgeStatusTone = 'success' | 'warning' | 'danger' | 'muted';

export function desktopBridgeStatusLabel(status: DesktopBridgeStatus | null | undefined): { label: string; tone: BridgeStatusTone } {
  if (!status?.supported) return { label: 'Bridge unavailable', tone: 'muted' };
  if (status.busy) return { label: 'Bridge configuring…', tone: 'warning' };
  if (status.error) return { label: 'Bridge error', tone: 'danger' };
  if (!status.installed) return { label: 'Bridge not installed', tone: 'muted' };
  if (!status.enrolled) return { label: 'Enrollment required', tone: 'warning' };
  if (status.serviceState === 'running') return { label: 'Bridge online', tone: 'success' };
  return { label: 'Bridge offline', tone: 'danger' };
}
