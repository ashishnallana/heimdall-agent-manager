import { Icon } from '@ui';
import { VAULT_LOCKED_OVERLAY_MESSAGE } from '../../utils/vaultLockedError';

export interface VaultLockedOverlayProps {
  /** The bridge that holds no vault key. */
  bridgeId: string;
  /** Kept for callers; the overlay itself offers no unlock (passwordless vault). */
  onUnsealed?: () => void;
}

/**
 * Covers a pane whose bridge holds no vault key (T10). Shared by the agent pane and
 * shell panes. The terminal underneath stays mounted, so its scrollback remains
 * visible through the scrim; the overlay takes the pointer so the terminal cannot be
 * focused or typed into (the panes also drop input while locked).
 *
 * Text only: there is no password and no unlock. Approved devices deliver the key to
 * bridges automatically (and from Settings → Devices); the pane resumes when the
 * bridge reports unsealed.
 */
export function VaultLockedOverlay({ bridgeId }: VaultLockedOverlayProps) {
  return (
    <div
      data-debug-id="pane-vault-locked-overlay"
      data-bridge-id={bridgeId}
      role="alert"
      aria-live="polite"
      className="absolute inset-0 z-20 flex flex-col items-center justify-center gap-3 bg-surface/85 p-4 text-center backdrop-blur-[1px]"
    >
      <Icon name="lock" size="lg" className="text-warning" />
      <p className="max-w-sm text-xs text-primary">{VAULT_LOCKED_OVERLAY_MESSAGE}</p>
    </div>
  );
}

export default VaultLockedOverlay;
