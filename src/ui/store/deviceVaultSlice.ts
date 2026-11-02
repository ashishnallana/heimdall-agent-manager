// Device-vault lifecycle state (docs/plans/passwordless-vault.md §2 P3).
//
// Serializable only: no keys, no CryptoKey handles, no keyring bytes. The keys live
// in vaultCrypto's active keyring (installed by vaultKeyringSession); this slice only
// says which gate screen the app shows and carries display data for it.
//
//   unsupported      no WebCrypto/IndexedDB: the app cannot run its vault
//   initializing     loading the identity / directory
//   genesis          first device of the account: creating the vault (automatic)
//   pending-approval this device shows its secret pairing code and waits for an approved
//                    device to type it (hub-blind pairing; no fingerprint typing here)
//   other-account    this browser already holds pins for another account: no automatic
//                    genesis or pairing until the user accepts it explicitly
//   ready            keyring installed; the app is usable
//   revoked          the signed log revoked this device; keys purged
//   reset-scheduled  a vault reset is pending and this device is not approved
//   error            verification failed (fail closed) or the hub misbehaved

import { createSlice, type PayloadAction } from '@reduxjs/toolkit';

export type DeviceVaultStatus =
  | 'unsupported'
  | 'initializing'
  | 'genesis'
  | 'pending-approval'
  | 'other-account'
  | 'ready'
  | 'revoked'
  | 'reset-scheduled'
  | 'error';

export interface DeviceVaultReset {
  requestedAt: string;
  effectiveAt: string;
}

export interface PendingDeviceSummary {
  deviceId: string;
  kind: string;
  fingerprint: string;
}

export interface DeviceVaultState {
  status: DeviceVaultStatus;
  userId: string;
  deviceId: string;
  fingerprint: string;
  /** Pending only: the secret pairing code to type on an approved device. Never sent anywhere. */
  userCode: string;
  codeExpiresAt: string;
  /** SHA256(root_sign_pub) in quads, once a verified directory is known. */
  accountFingerprint: string;
  currentEpoch: number;
  directoryVersion: number;
  /** First hex chars of the verified log head hash (compare across devices). */
  headHash: string;
  /**
   * M1 freshness guard: the verified head is old and this device was offline before
   * the fetch; automatic bridge key delivery and hint revokes are paused.
   */
  staleHead: boolean;
  reset: DeviceVaultReset | null;
  /** Pending devices of the account (for the approval toast / attention entry). */
  pendingDevices: PendingDeviceSummary[];
  /** Machine reason for `error` (e.g. 'chain_invalid', 'vault_missing', 'hub_unreachable'). */
  errorCode: string;
  errorMessage: string;
  busy: boolean;
  /** Bridges whose last key delivery failed (bridge id -> error); cleared on success. */
  bridgeKeyFailures: Record<string, string>;
  mcpKeyDeliveryError: string;
  /** other-account: account ids this browser already holds pins for. */
  otherAccounts: string[];
  /**
   * error 'vault_missing': the phrase the user must type to start a new vault anyway
   * (the account fingerprint's first group + " RESET"); error 'device_state_malformed':
   * the phrase to reset this browser's device data. Empty otherwise.
   */
  startOverPhrase: string;
}

export const initialDeviceVaultState: DeviceVaultState = {
  status: 'initializing',
  userId: '',
  deviceId: '',
  fingerprint: '',
  userCode: '',
  codeExpiresAt: '',
  accountFingerprint: '',
  currentEpoch: 0,
  directoryVersion: 0,
  headHash: '',
  staleHead: false,
  reset: null,
  pendingDevices: [],
  errorCode: '',
  errorMessage: '',
  busy: false,
  bridgeKeyFailures: {},
  mcpKeyDeliveryError: '',
  otherAccounts: [],
  startOverPhrase: '',
};

export const deviceVaultSlice = createSlice({
  name: 'deviceVault',
  initialState: initialDeviceVaultState,
  reducers: {
    deviceVaultStatusChanged(state, action: PayloadAction<{ status: DeviceVaultStatus } & Partial<Omit<DeviceVaultState, 'status'>>>) {
      const { status, ...rest } = action.payload;
      Object.assign(state, rest);
      state.status = status;
      if (status !== 'error') {
        state.errorCode = rest.errorCode ?? '';
        state.errorMessage = rest.errorMessage ?? '';
        state.startOverPhrase = '';
      }
      if (status !== 'pending-approval' && status !== 'reset-scheduled') {
        state.userCode = '';
        state.codeExpiresAt = '';
      }
      state.busy = false;
    },
    deviceVaultIdentityKnown(state, action: PayloadAction<{ userId: string; deviceId: string; fingerprint: string }>) {
      state.userId = action.payload.userId;
      state.deviceId = action.payload.deviceId;
      state.fingerprint = action.payload.fingerprint;
    },
    deviceVaultDirectoryVerified(state, action: PayloadAction<{ accountFingerprint: string; currentEpoch: number; directoryVersion: number; headHash: string; staleHead: boolean; reset: DeviceVaultReset | null; pendingDevices: PendingDeviceSummary[] }>) {
      Object.assign(state, action.payload);
    },
    deviceVaultBusy(state, action: PayloadAction<boolean>) {
      state.busy = action.payload;
    },
    deviceVaultFailed(state, action: PayloadAction<{ code: string; message: string; startOverPhrase?: string }>) {
      state.status = 'error';
      state.errorCode = action.payload.code;
      state.errorMessage = action.payload.message;
      state.startOverPhrase = action.payload.startOverPhrase ?? '';
      state.busy = false;
    },
    bridgeKeyDeliveryReported(state, action: PayloadAction<{ succeeded: string[]; failed: Array<{ bridgeId: string; error: string }> }>) {
      for (const id of action.payload.succeeded) delete state.bridgeKeyFailures[id];
      for (const f of action.payload.failed) state.bridgeKeyFailures[f.bridgeId] = f.error;
    },
    mcpKeyDeliveryReported(state, action: PayloadAction<string>) {
      state.mcpKeyDeliveryError = action.payload;
    },
    deviceVaultSignedOut() {
      return initialDeviceVaultState;
    },
  },
});

export const {
  deviceVaultStatusChanged,
  deviceVaultIdentityKnown,
  deviceVaultDirectoryVerified,
  deviceVaultBusy,
  deviceVaultFailed,
  deviceVaultSignedOut,
  bridgeKeyDeliveryReported,
  mcpKeyDeliveryReported,
} = deviceVaultSlice.actions;

type WithDeviceVault = { deviceVault?: DeviceVaultState };

export const selectDeviceVault = (state: WithDeviceVault): DeviceVaultState => state?.deviceVault ?? initialDeviceVaultState;

export default deviceVaultSlice.reducer;
