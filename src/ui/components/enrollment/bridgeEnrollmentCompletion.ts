export function nextAvailableBridgeLabel(
  hostname: string,
  bridges: Array<{ label?: string }> | null | undefined,
): string {
  const base = hostname.trim() || 'bridge';
  const existing = new Set(
    (bridges || [])
      .map((bridge) => String(bridge?.label || '').trim().toLowerCase())
      .filter(Boolean),
  );
  if (!existing.has(base.toLowerCase())) return base;

  let count = 2;
  while (existing.has(`${base}-${count}`.toLowerCase())) count += 1;
  return `${base}-${count}`;
}

/**
 * A successful approval only mints a credential. Completion means the exact
 * bridge that received that credential has authenticated and joined the Hub.
 */
export function approvedBridgeIsOnline(rows: unknown, bridgeId: string): boolean {
  if (!bridgeId || !Array.isArray(rows)) return false;

  return rows.some((row: any) => {
    const id = String(row?.bridge_id || row?.bridgeId || row?.id || '');
    const status = String(row?.status || row?.runtime_status || '')
      .trim()
      .toLowerCase();
    return id === bridgeId && (status === 'online' || status === 'connected');
  });
}

/**
 * How long to wait, after the vault key reached the enrolling process, for the
 * restarted bridge service to report that it unsealed itself from the persisted
 * key (REQ-T2-4).
 */
export const RESTART_CONFIRMATION_TIMEOUT_SECONDS = 45;

/**
 * A restarted bridge reporting locked/disabled is only believed on this many
 * consecutive polls. The hub learns the new process's public key from its hello
 * and its vault state from the heartbeat sent right after, so a single poll can
 * land between the two and read the enroll process's last report.
 */
export const RESTART_SEALED_CONFIRM_POLLS = 2;

export type RestartConfirmationOutcome = 'waiting' | 'confirmed' | 'sealed' | 'timed-out';

export interface RestartConfirmationInput {
  /** Rows of GET /bridges. */
  rows: unknown;
  bridgeId: string;
  /** The operator-confirmed key of the enrolling process the vault key was sent to. */
  enrollmentPublicKey: string;
  /** What GET /bridges/{id}/public-key advertises now ('' when unknown). */
  advertisedPublicKey: string;
  /** Consecutive earlier polls that saw the restarted bridge sealed. */
  sealedPolls: number;
  /** Whether the confirmation deadline has passed. */
  expired: boolean;
}

export interface RestartConfirmationDecision {
  outcome: RestartConfirmationOutcome;
  sealedPolls: number;
  /** The vault_status the bridge row carried on this poll ('' when absent). */
  vaultStatus: string;
}

/**
 * Decides whether the bridge service restarted by `ham-bridge enroll` has come
 * back unsealed.
 *
 * "Delivered" only means the enrolling CLI process decrypted the key; that process
 * then restarts the registered service and exits. A `vault_status` of `unlocked`
 * is therefore believed only from the RESTARTED process, recognised by the public
 * key it advertises: the bridge's ECDH keypair is ephemeral per process, so a key
 * different from the one the operator confirmed means a new process is connected.
 * (The enroll process itself always reports `locked`, which also clears a stale
 * `unlocked` from an earlier run of the same bridge.)
 */
export function enrollmentRestartConfirmation(
  input: RestartConfirmationInput,
): RestartConfirmationDecision {
  const { rows, bridgeId, enrollmentPublicKey, advertisedPublicKey, sealedPolls, expired } = input;
  const row = Array.isArray(rows)
    ? rows.find(
        (candidate: any) =>
          String(candidate?.bridge_id || candidate?.bridgeId || candidate?.id || '') === bridgeId,
      )
    : undefined;
  const vaultStatus = String((row as any)?.vault_status || '')
    .trim()
    .toLowerCase();
  const advertised = advertisedPublicKey.trim().toLowerCase();
  const restarted =
    approvedBridgeIsOnline(rows, bridgeId) &&
    advertised !== '' &&
    advertised !== enrollmentPublicKey.trim().toLowerCase();

  if (restarted && vaultStatus === 'unlocked') {
    return { outcome: 'confirmed', sealedPolls: 0, vaultStatus };
  }
  const nextSealed =
    restarted && (vaultStatus === 'locked' || vaultStatus === 'disabled') ? sealedPolls + 1 : 0;
  if (nextSealed >= RESTART_SEALED_CONFIRM_POLLS) {
    return { outcome: 'sealed', sealedPolls: nextSealed, vaultStatus };
  }
  return { outcome: expired ? 'timed-out' : 'waiting', sealedPolls: nextSealed, vaultStatus };
}

/**
 * Phases of the approval page's delivery state machine after which the
 * enrollment itself is finished, so "Continue to provider selection" must stay
 * offered whatever the vault outcome (REQ-T2-4). A sealed bridge is still an
 * enrolled bridge; the operator can unseal it later from Settings → Bridges.
 */
/** Shown in the unlock prompt when the master password does not decrypt the vault. */
export const WRONG_MASTER_PASSWORD_MESSAGE = 'Incorrect master password. Try again.';

export function enrollmentContinueAvailable(phase: string, passwordTarget?: string): boolean {
  switch (phase) {
    case 'delivered':
    case 'confirming-restart':
    case 'confirmed':
    case 'restart-unconfirmed':
    case 'not-needed':
    // The vault key was not delivered, but the bridge is approved and online.
    case 'failed':
      return true;
    case 'need-password':
    case 'delivering':
      // Re-unsealing the restarted service: the enrollment already completed.
      return passwordTarget === 'restarted';
    default:
      return false;
  }
}

export function navigateEnrollmentHome(): void {
  window.location.hash = '#/home';
}

export function navigateEnrollmentProviderSetup(bridgeId: string): void {
  window.location.hash = `#/device/providers/${encodeURIComponent(bridgeId)}`;
}
