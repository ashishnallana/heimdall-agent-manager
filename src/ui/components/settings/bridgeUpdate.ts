// REQ-BUPD-3: Helper functions and predicates for Bridge version reporting and update pipeline.

import type { Bridge } from '../../api/endpoints/bridgeSupport.ts';

/**
 * Formats a bridge's current running version and commit hash into a monospace badge string.
 * Example: "v0.1.0 (a57c83d9)"
 */
export function formatBridgeVersion(bridge: Partial<Bridge> | null | undefined): string {
  if (!bridge) return '';
  const version = bridge.version ? `v${bridge.version}` : '';
  const commit = bridge.commit_sha ? bridge.commit_sha.slice(0, 8) : '';
  if (version && commit) return `${version} (${commit})`;
  if (version) return version;
  if (commit) return commit;
  return '';
}

/**
 * Formats a bridge's latest available version and commit hash.
 * Example: "v0.2.0 (796bfb57)" or "latest"
 */
export function formatLatestVersion(bridge: Partial<Bridge> | null | undefined): string {
  if (!bridge) return 'latest';
  const version = bridge.latest_version ? `v${bridge.latest_version}` : 'latest';
  const commit = bridge.latest_commit_sha ? ` (${bridge.latest_commit_sha.slice(0, 8)})` : '';
  return `${version}${commit}`;
}

/**
 * REQ-T13-4: a newer release exists but ships no bundle for this bridge's
 * release target (e.g. termux-arm64). Older hubs omit the field, so only an
 * explicit `false` counts.
 */
export function isUpdateUnavailableForTarget(bridge: Partial<Bridge> | null | undefined): boolean {
  return Boolean(bridge?.update_available) && bridge?.update_artifact_available === false;
}

/**
 * Copy for the update badge: "Update available: v0.3.31" or
 * "v0.3.31 not available for termux-arm64".
 */
export function updateAvailabilityLabel(bridge: Partial<Bridge> | null | undefined): string {
  const latest = formatLatestVersion(bridge);
  if (isUpdateUnavailableForTarget(bridge)) {
    return `${latest} not available for ${bridge?.target || 'this target'}`;
  }
  return `Update available: ${latest}`;
}

/**
 * Checks whether an update is actively in progress on the bridge.
 */
export function isBridgeUpdating(bridge: Partial<Bridge> | null | undefined): boolean {
  if (!bridge?.update_status) return false;
  return ['updating', 'draining', 'preparing', 'downloading', 'downloaded', 'validating', 'verifying', 'verified', 'extracting', 'preflight', 'staged', 'stopping_pty_host', 'pty_host_stopped', 'restarting'].includes(bridge.update_status);
}

export function bridgeUpdateStatusLabel(bridge: Partial<Bridge> | null | undefined): string {
  if (bridge?.update_message) return bridge.update_message;
  const labels: Record<string, string> = {
    updating: 'Starting update…',
    draining: 'Waiting for active tasks…',
    preparing: 'Preparing update…',
    downloading: 'Downloading update tarball…',
    downloaded: 'Download completed.',
    validating: 'Validating update…',
    verifying: 'Verifying checksum…',
    verified: 'Checksum verified.',
    extracting: 'Extracting update…',
    preflight: 'Validating staged binaries…',
    staged: 'Update staged.',
    stopping_pty_host: 'Stopping PTY host and agents…',
    pty_host_stopped: 'PTY host and agents stopped.',
    restarting: 'Restarting bridge…',
  };
  return labels[String(bridge?.update_status || '')] || 'Updating…';
}

/**
 * Checks if the bridge has active tasks that require a graceful drain warning.
 */
export function shouldWarnActiveTasks(bridge: Partial<Bridge> | null | undefined): boolean {
  const count = bridge?.active_instance_count ?? bridge?.instance_count ?? 0;
  return count > 0;
}

/**
 * Returns the count of active agent tasks running on the bridge.
 */
export function getActiveTaskCount(bridge: Partial<Bridge> | null | undefined): number {
  return bridge?.active_instance_count ?? bridge?.instance_count ?? 0;
}
