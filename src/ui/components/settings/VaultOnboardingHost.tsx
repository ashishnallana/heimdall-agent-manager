import React from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  selectIsSearchReauthentication,
  selectIsUnlockModalOpen,
  setActiveBridgeVaultKeyMaterial,
  setUnlockModalOpen,
  verifyActiveVaultKeyMaterial,
} from '../../store/vaultSlice';
import { isVaultSupported } from '../../utils/vaultCrypto';
import VaultOnboardingModal from './VaultOnboardingModal';

export interface VaultOnboardingHostProps {
  onboardingOpen: boolean;
  onOnboardingOpenChange: (open: boolean) => void;
  bridgeReauthenticationOpen: boolean;
  onBridgeReauthenticationOpenChange: (open: boolean) => void;
  onBridgeReauthenticate: (rawVaultKeyHex: string) => Promise<void>;
}

/**
 * Owns the Redux-requested Vault ceremony without mirroring that request into
 * local state. The request (and its purpose) are cleared only by a real close.
 */
export function VaultOnboardingHost({
  onboardingOpen,
  onOnboardingOpenChange,
  bridgeReauthenticationOpen,
  onBridgeReauthenticationOpenChange,
  onBridgeReauthenticate,
}: VaultOnboardingHostProps) {
  const dispatch = useDispatch();
  const isUnlockModalOpen = useSelector(selectIsUnlockModalOpen);
  const isSearchReauthentication = useSelector(selectIsSearchReauthentication);
  const supportsVault = isVaultSupported();
  const requestedOpen = isUnlockModalOpen && supportsVault;
  const open = onboardingOpen || requestedOpen || bridgeReauthenticationOpen;

  React.useEffect(() => {
    if (isUnlockModalOpen && !supportsVault) dispatch(setUnlockModalOpen(false));
  }, [dispatch, isUnlockModalOpen, supportsVault]);

  const handleOpenChange = (next: boolean) => {
    if (bridgeReauthenticationOpen) {
      onBridgeReauthenticationOpenChange(next);
      return;
    }
    onOnboardingOpenChange(next);
    if (!next && isUnlockModalOpen) dispatch(setUnlockModalOpen(false));
  };

  return (
    <VaultOnboardingModal
      open={open}
      mode={bridgeReauthenticationOpen ? 'bridge-reauthentication' : requestedOpen && isSearchReauthentication ? 'search-reauthentication' : 'vault-unlock'}
      onOpenChange={handleOpenChange}
      onBridgeReauthenticate={onBridgeReauthenticate}
      onSearchReauthenticate={async (rawVaultKeyHex) => {
        if (!await verifyActiveVaultKeyMaterial(rawVaultKeyHex)) {
          throw new Error('Vault key no longer matches this session. Lock and unlock the Vault again.');
        }
        await setActiveBridgeVaultKeyMaterial(rawVaultKeyHex);
      }}
    />
  );
}
