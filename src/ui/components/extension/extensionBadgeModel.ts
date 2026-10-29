// Provider extension badges (REQ-EXT-DET-2). Pure logic, no React and no fetch,
// so every state is unit-testable (tests/ui_extension_badge_test.ts).
//
// Two sources feed these badges:
//   - GET /bridges/{id}/provider-status → providers[].extension, the bridge's probe
//     of the provider's Heimdall extension (null when the catalog has none).
//   - The agent instance JSON → extension{provider,version,capabilities,last_seen_at},
//     filled once the running extension sent its `hello` event.

/** Measured extension states the hub stores ('' = never reported). */
export type ProviderExtensionState = '' | 'present' | 'disabled' | 'outdated' | 'absent' | 'error' | 'unsupported';

export interface ProviderExtensionStatus {
  state: ProviderExtensionState;
  version: string;
  checked_at: string | null;
  plugin_id: string;
  min_version: string;
  install_hint: string;
  capabilities: string[];
}

export type ExtensionBadgeTone = 'success' | 'warning' | 'neutral' | 'danger';

export interface ProviderExtensionBadge {
  /** Stable key for tests and data-debug-id suffixes. */
  kind: 'installed' | 'disabled' | 'update' | 'not-found' | 'error' | 'not-checked';
  label: string;
  tone: ExtensionBadgeTone;
  /** Short helper text under the badge (may be ''). */
  detail: string;
  /** Command the user can copy to install or update the extension ('' = none). */
  installHint: string;
}

const STATES: readonly ProviderExtensionState[] = ['', 'present', 'disabled', 'outdated', 'absent', 'error', 'unsupported'];

function str(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

/** Normalizes providers[].extension; null when the provider ships no extension. */
export function normalizeProviderExtension(raw: any): ProviderExtensionStatus | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const state = STATES.includes(raw.state) ? (raw.state as ProviderExtensionState) : '';
  return {
    state,
    version: str(raw.version),
    checked_at: raw.checked_at ? String(raw.checked_at) : null,
    plugin_id: str(raw.plugin_id),
    min_version: str(raw.min_version),
    install_hint: str(raw.install_hint),
    capabilities: Array.isArray(raw.capabilities) ? raw.capabilities.filter((c: unknown) => typeof c === 'string') : [],
  };
}

/**
 * The provider setup badge, or null when it should be hidden (the provider has
 * no extension, or the catalog reports it unsupported).
 */
export function providerExtensionBadge(ext: ProviderExtensionStatus | null | undefined): ProviderExtensionBadge | null {
  if (!ext || ext.state === 'unsupported') return null;
  // Bridges report a developer command with a literal <repo> placeholder; it
  // cannot work for users, who get the Install / Update button instead.
  const hint = String(ext.install_hint || '').includes('<repo>') ? '' : ext.install_hint;
  switch (ext.state) {
    case 'present':
      return {
        kind: 'installed',
        label: ext.version ? `Extension installed v${ext.version}` : 'Extension installed',
        tone: 'success',
        detail: 'Package installed. Hook review may be required; signals are confirmed separately for each running agent.',
        installHint: '',
      };
    case 'disabled':
      return {
        kind: 'disabled',
        label: 'Extension disabled',
        tone: 'warning',
        detail: ext.plugin_id
          ? `The extension (${ext.plugin_id}) is installed but disabled. Enable it in the provider CLI.`
          : 'The extension is installed but disabled. Enable it in the provider CLI.',
        installHint: '',
      };
    case 'outdated':
      return {
        kind: 'update',
        label: 'Update available',
        tone: 'warning',
        detail: ext.version && ext.min_version
          ? `Installed v${ext.version}; Ninjy needs v${ext.min_version} or newer.`
          : 'The installed extension is older than Ninjy needs.',
        installHint: hint,
      };
    case 'absent':
      return {
        kind: 'not-found',
        label: 'Not found',
        tone: 'neutral',
        detail: 'Install the Ninjy extension for native activity, subagent and permission signals. Without it Ninjy uses screen detection.',
        installHint: hint,
      };
    case 'error':
      return {
        kind: 'error',
        label: 'Extension check failed',
        tone: 'danger',
        detail: 'The bridge could not check for the extension. Re-run discovery to try again.',
        installHint: '',
      };
    default:
      return {
        kind: 'not-checked',
        label: 'Extension not checked',
        tone: 'neutral',
        detail: 'Re-run discovery to check for the Ninjy extension.',
        installHint: '',
      };
  }
}

/** Instance-level extension info (hub agent instance JSON `extension`). */
export interface InstanceExtensionInfo {
  provider: string;
  version: string;
  capabilities: string[];
  last_seen_at: string;
}

export function normalizeInstanceExtension(raw: any): InstanceExtensionInfo | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const info: InstanceExtensionInfo = {
    provider: str(raw.provider),
    version: str(raw.version),
    capabilities: Array.isArray(raw.capabilities) ? raw.capabilities.filter((c: unknown) => typeof c === 'string' && c) : [],
    last_seen_at: str(raw.last_seen_at),
  };
  return info.provider || info.capabilities.length ? info : null;
}

const CAPABILITY_LABELS: Record<string, string> = {
  activity: 'Activity',
  subagents: 'Subagents',
  permissions: 'Permission prompts',
  file_edits: 'File edits',
  session_id: 'Session id',
};

export function capabilityLabel(capability: string): string {
  return CAPABILITY_LABELS[capability] || capability;
}

export interface InstanceSignalBadge {
  kind: 'native' | 'screen';
  label: string;
  tone: ExtensionBadgeTone;
  tooltip: string;
  capabilities: string[];
}

/**
 * The per-instance badge: "Native signals" once the extension reported
 * capabilities, otherwise "Screen detection" (the PTY scraper fallback).
 */
export function instanceSignalBadge(rawInstanceExtension: any): InstanceSignalBadge {
  const info = normalizeInstanceExtension(rawInstanceExtension);
  if (!info || info.capabilities.length === 0) {
    return {
      kind: 'screen',
      label: 'Screen detection',
      tone: 'neutral',
      tooltip: 'Activity is detected from the terminal screen. Install the provider extension for native signals.',
      capabilities: [],
    };
  }
  const lines = info.capabilities.map(capabilityLabel);
  const source = [info.provider, info.version ? `v${info.version}` : ''].filter(Boolean).join(' ');
  return {
    kind: 'native',
    label: 'Native signals',
    tone: 'success',
    tooltip: `${source ? `${source} extension: ` : 'Extension: '}${lines.join(', ')}`,
    capabilities: info.capabilities,
  };
}
