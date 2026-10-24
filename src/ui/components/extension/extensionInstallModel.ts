import type { ProviderExtensionStatus } from './extensionBadgeModel';

export type ExtensionInstallStatus = 'queued' | 'dispatched' | 'accepted' | 'installing' | 'succeeded' | 'failed' | 'cancelled';

export interface ProviderExtensionCommand {
  command_id: string;
  bridge_id: string;
  provider: string;
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

export function extensionInstallProgress(command: ProviderExtensionCommand, extension: ProviderExtensionStatus | null): string {
  switch (command.status) {
    case 'succeeded': return extension?.state === 'present'
      ? 'Extension installed and verified.'
      : 'Previous installation completed. Current extension status needs checking.';
    case 'failed': return command.message || 'Extension installation failed. Try again.';
    case 'cancelled': return command.message || 'Extension installation cancelled.';
    case 'queued': return 'Extension installation queued…';
    case 'dispatched': return 'Waiting for the bridge to start installation…';
    case 'accepted': return 'Bridge accepted installation; waiting for verification…';
    case 'installing': return command.message || 'Installing extension…';
  }
}
