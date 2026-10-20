// Keyring accessors (docs/plans/passwordless-vault.md §2 P3: "reduce it to keyring
// accessors"). There is no password, no lock and no unlock: a device's keyring is
// installed by vaultKeyringSession once its wrap verified against the signed
// directory chain, and purged only when the device is revoked / the vault reset /
// the user changes. This slice mirrors that fact for React (`isUnlocked` means
// "this device's keyring is installed") and nothing else. Serializable only.

import { createSlice, type PayloadAction } from '@reduxjs/toolkit';
import { getActiveVaultKey, type VaultKeyring } from '../utils/vaultCrypto.ts';
import {
  getActiveTaskChainSearchKey,
  waitForActiveTaskChainSearchKey,
} from '../utils/taskChainSearchKey.ts';

export { getActiveVaultKey, getActiveTaskChainSearchKey, waitForActiveTaskChainSearchKey };

export interface VaultState {
  /** This device's keyring is installed (decryption available). */
  isUnlocked: boolean;
  currentEpoch: number;
}

const initialState: VaultState = { isUnlocked: false, currentEpoch: 0 };

export const vaultSlice = createSlice({
  name: 'vault',
  initialState,
  reducers: {
    keyringInstalled(state, action: PayloadAction<{ currentEpoch: number }>) {
      state.isUnlocked = true;
      state.currentEpoch = action.payload.currentEpoch;
    },
    keyringCleared(state) {
      state.isUnlocked = false;
      state.currentEpoch = 0;
    },
  },
});

export const { keyringInstalled, keyringCleared } = vaultSlice.actions;
export const selectIsVaultUnlocked = (state: { vault?: VaultState }) => Boolean(state?.vault?.isUnlocked);
export const selectVaultEpoch = (state: { vault?: VaultState }) => state?.vault?.currentEpoch ?? 0;
/** Not reactive: read the module-level keyring. Pair with selectIsVaultUnlocked for re-renders. */
export const selectActiveVaultKey = (_state?: { vault?: VaultState }): VaultKeyring | null => getActiveVaultKey();

export default vaultSlice.reducer;
