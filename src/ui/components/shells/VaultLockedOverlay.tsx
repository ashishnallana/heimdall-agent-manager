import { useState } from 'react';
import { Button, Icon, Modal, ModalBody } from '@ui';
import BridgeSettingsPanel from '../settings/BridgeSettingsPanel';
import { VAULT_LOCKED_OVERLAY_MESSAGE, VAULT_LOCKED_UNLOCK_LABEL } from '../../utils/vaultLockedError';

export interface VaultLockedOverlayProps {
  /** The bridge whose vault is locked; Unlock targets exactly this one. */
  bridgeId: string;
  /** The operator completed an unseal of this bridge from the overlay. */
  onUnsealed?: () => void;
}

/**
 * T10 (REQ-T10-3): covers a pane whose bridge vault is locked. Shared by the agent
 * pane and shell panes. The terminal underneath stays mounted, so its scrollback
 * remains visible through the scrim; the overlay itself takes the pointer so the
 * terminal cannot be focused or typed into (the panes also drop input while locked).
 *
 * "Unlock vault" opens Settings -> User Vault scoped to this bridge and starts that
 * row's own unseal (`autoUnseal`): the active key, or the existing master-password
 * prompt scoped to this bridge. There is no new key-entry surface here.
 */
export function VaultLockedOverlay({ bridgeId, onUnsealed }: VaultLockedOverlayProps) {
  const [unlockOpen, setUnlockOpen] = useState(false);

  return (
    <div
      data-debug-id="pane-vault-locked-overlay"
      role="alert"
      aria-live="polite"
      className="absolute inset-0 z-20 flex flex-col items-center justify-center gap-3 bg-surface/85 p-4 text-center backdrop-blur-[1px]"
    >
      <Icon name="lock" size="lg" className="text-warning" />
      <p className="max-w-sm text-xs text-primary">{VAULT_LOCKED_OVERLAY_MESSAGE}</p>
      <Button
        type="button"
        variant="primary"
        size="sm"
        data-debug-id="pane-vault-unlock-btn"
        disabled={!bridgeId}
        onClick={() => setUnlockOpen(true)}
      >
        {VAULT_LOCKED_UNLOCK_LABEL}
      </Button>

      {unlockOpen && bridgeId ? (
        <Modal
          open={unlockOpen}
          onOpenChange={(open) => { if (!open) setUnlockOpen(false); }}
          title="Unlock bridge vault"
          size="lg"
          data-debug-id="pane-vault-unlock-modal"
        >
          <ModalBody>
            <BridgeSettingsPanel
              selectedBridgeId={bridgeId}
              autoUnseal
              onBridgeUnsealed={(unsealedId) => {
                if (unsealedId !== bridgeId) return;
                setUnlockOpen(false);
                onUnsealed?.();
              }}
            />
          </ModalBody>
        </Modal>
      ) : null}
    </div>
  );
}

export default VaultLockedOverlay;
