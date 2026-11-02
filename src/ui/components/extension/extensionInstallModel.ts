import type { ProviderExtensionStatus } from './extensionBadgeModel';

export type ExtensionInstallStatus = 'queued' | 'dispatched' | 'accepted' | 'installing' | 'uninstalling' | 'succeeded' | 'failed' | 'cancelled';

/** install covers install and update; uninstall removes the extension. */
export type ExtensionCommandKind = 'install' | 'uninstall';

export interface ProviderExtensionCommand {
  command_id: string;
  bridge_id: string;
  provider: string;
  profile_id?: string;
  /** Absent from older Hubs, which only ran installs. */
  kind?: ExtensionCommandKind;
  status: ExtensionInstallStatus;
  progress_percent: number;
  message: string;
  parent_command_id: string;
}

export function isExtensionInstallTerminal(status: ExtensionInstallStatus): boolean {
  return status === 'succeeded' || status === 'failed' || status === 'cancelled';
}

export function extensionInstallLabel(provider: string, extension: ProviderExtensionStatus | null): string {
  if (!['claude', 'codex', 'antigravity'].includes(provider)) return '';
  if (extension?.state === 'absent') return 'Install Extension';
  if (extension?.state === 'outdated') {
    return extension.min_version ? `Update to v${extension.min_version}` : 'Update Extension';
  }
  return '';
}

/** Uninstall is offered whenever the extension is registered at all. */
export function extensionUninstallable(provider: string, extension: ProviderExtensionStatus | null): boolean {
  return ['claude', 'codex', 'antigravity'].includes(provider)
    && ['present', 'outdated', 'disabled'].includes(String(extension?.state || ''));
}

export function extensionCommandKind(command: ProviderExtensionCommand | null | undefined): ExtensionCommandKind {
  return command?.kind === 'uninstall' ? 'uninstall' : 'install';
}

export function extensionInstallProgress(command: ProviderExtensionCommand, extension: ProviderExtensionStatus | null): string {
  if (extensionCommandKind(command) === 'uninstall') {
    switch (command.status) {
      case 'succeeded': return extension?.state === 'absent' || !extension?.state
        ? 'Extension uninstalled.'
        : 'Uninstall completed. Current extension status needs checking.';
      case 'failed': return command.message || 'Extension uninstall failed. Try again.';
      case 'cancelled': return command.message || 'Extension uninstall cancelled.';
      case 'queued': return 'Extension uninstall queued…';
      case 'dispatched': return 'Waiting for the bridge to start the uninstall…';
      case 'accepted': return 'Bridge accepted the uninstall; waiting for verification…';
      default: return command.message || 'Uninstalling extension…';
    }
  }
  switch (command.status) {
    case 'succeeded': return extension?.state === 'present'
      ? 'Extension installed and verified.'
      : 'Previous installation completed. Current extension status needs checking.';
    case 'failed': return command.message || 'Extension installation failed. Try again.';
    case 'cancelled': return command.message || 'Extension installation cancelled.';
    case 'queued': return 'Extension installation queued…';
    case 'dispatched': return 'Waiting for the bridge to start installation…';
    case 'accepted': return 'Bridge accepted installation; waiting for verification…';
    case 'installing':
    case 'uninstalling': return command.message || 'Installing extension…';
  }
}
