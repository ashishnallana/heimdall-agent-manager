import { createSlice, type PayloadAction } from '@reduxjs/toolkit';
import {
  importRawKeyHex,
  isVaultSupported,
  getActiveVaultKey,
  setActiveVaultKey as setActiveVaultKeyHandle,
  getActiveBridgeVaultKeyMaterial,
  setActiveBridgeVaultKeyMaterial as setActiveBridgeVaultKeyMaterialHandle,
  currentKey,
  setActiveVaultUserId,
  type VaultKeyring,
} from '../utils/vaultCrypto.ts';
import {
  persistVaultKey,
  persistVaultKeys,
  restoreVaultKeys,
  deleteVaultKey,
} from '../utils/vaultPersistence.ts';
import {
  beginTaskChainSearchKeyDerivation,
  getActiveTaskChainSearchKey,
  setActiveTaskChainSearchKey,
  waitForActiveTaskChainSearchKey,
  type TaskChainSearchKey,
} from '../utils/taskChainSearchKey.ts';

export {
  getActiveVaultKey,
  setActiveVaultUserId,
  getActiveBridgeVaultKeyMaterial,
  getActiveTaskChainSearchKey,
  waitForActiveTaskChainSearchKey,
};

let activeVaultRemembered = false;
let activeVaultGeneration = 0;

// P1-TEMPORARY ADAPTER (deleted in P3): the password-vault CryptoKey is installed as
// epoch 1 of the active keyring (see vaultCrypto.setActiveVaultKey). Persistence and
// the search key therefore always refer to epoch 1 here.
const ADAPTER_EPOCH = 1;

function installActiveVaultKeys(
  contentKey: CryptoKey | null,
  taskChainSearchKey: CryptoKey | null = null,
  remembered = false,
): void {
  activeVaultGeneration += 1;
  activeVaultRemembered = Boolean(contentKey && remembered);
  setActiveVaultKeyHandle(contentKey);
  if (contentKey && taskChainSearchKey) {
    setActiveTaskChainSearchKey(Object.freeze({ epoch: ADAPTER_EPOCH, key: taskChainSearchKey }));
  }
}

export function setActiveVaultKey(key: CryptoKey | VaultKeyring | null): void {
  if (key && !('algorithm' in key)) {
    activeVaultGeneration += 1;
    activeVaultRemembered = false;
    setActiveVaultKeyHandle(key);
    return;
  }
  installActiveVaultKeys(key as CryptoKey | null);
}

export function setActiveBridgeVaultKeyMaterial(rawHex: string | null): Promise<TaskChainSearchKey | null> {
  setActiveBridgeVaultKeyMaterialHandle(rawHex);
  const clean = String(rawHex || '').trim().toLowerCase();
  const keyring = getActiveVaultKey();
  if (!keyring || keyring.currentEpoch !== ADAPTER_EPOCH || !/^[0-9a-f]{64}$/.test(clean)) {
    setActiveTaskChainSearchKey(null);
    return Promise.resolve(null);
  }
  const contentKey = currentKey(keyring);

  const generation = activeVaultGeneration;
  const activation = beginTaskChainSearchKeyDerivation(clean, ADAPTER_EPOCH).then(async (searchKey) => {
    if (generation !== activeVaultGeneration || getActiveVaultKey() !== keyring) return null;
    if (activeVaultRemembered) {
      await persistVaultKeys(contentKey, searchKey.key);
    }
    return searchKey;
  });
  // Most UI callers intentionally fire-and-forget because the pending key is
  // consumed by waitForActiveTaskChainSearchKey(). Mark the rejection handled
  // for those callers while preserving it on the returned promise for callers
  // such as unlockVaultWithHex() that need persistence failures to propagate.
  void activation.catch(() => null);
  return activation;
}

export const VAULT_SESSION_KEY = 'heimdall:vault:raw-key';
export const VAULT_ONBOARDING_DISMISSED_KEY = 'heimdall:vault:onboarding-dismissed';

function getSessionStorage(): Storage | null {
  if (typeof window !== 'undefined' && window.sessionStorage) {
    return window.sessionStorage;
  }
  if (typeof globalThis !== 'undefined' && (globalThis as any).sessionStorage) {
    return (globalThis as any).sessionStorage;
  }
  return null;
}

/**
 * Deprecated: raw keys are never stored in sessionStorage (REQ-VAULT-HARDEN-1).
 * Always returns null to ensure no script or XSS can retrieve raw keys from storage.
 */
export function readSessionVaultKey(): string | null {
  return null;
}

/**
 * Deprecated: raw keys are never written to sessionStorage (REQ-VAULT-HARDEN-1).
 */
export function writeSessionVaultKey(_rawHex: string): void {
  // No-op for security hardening: key material is held exclusively in non-extractable CryptoKey handles
}

/**
 * Clear any legacy vault key from sessionStorage.
 */
export function clearSessionVaultKey(): void {
  try {
    const storage = getSessionStorage();
    if (!storage) return;
    storage.removeItem(VAULT_SESSION_KEY);
  } catch {}
}

export function readOnboardingDismissed(): boolean {
  try {
    const storage = getSessionStorage();
    if (!storage) return false;
    return storage.getItem(VAULT_ONBOARDING_DISMISSED_KEY) === 'true';
  } catch {
    return false;
  }
}

export function writeOnboardingDismissed(dismissed = true): void {
  try {
    const storage = getSessionStorage();
    if (!storage) return;
    if (dismissed) {
      storage.setItem(VAULT_ONBOARDING_DISMISSED_KEY, 'true');
    } else {
      storage.removeItem(VAULT_ONBOARDING_DISMISSED_KEY);
    }
  } catch {}
}

export function validateHexVaultKey(hexKey: string): string {
  const clean = String(hexKey || '').trim().toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(clean)) {
    throw new Error(`Invalid vault key: expected 64 hex characters, got length ${clean.length}`);
  }
  return clean;
}

/**
 * Validate and import a hex key as a non-extractable WebCrypto CryptoKey.
 * Wipes transient buffers immediately.
 */
export async function importAndValidateCryptoKey(hexKey: string): Promise<CryptoKey> {
  const clean = validateHexVaultKey(hexKey);
  const key = await importRawKeyHex(clean);
  installActiveVaultKeys(key);
  // Keep the matching raw material in memory for bridge delivery during this
  // unlocked browser session. It is never put in Redux, browser storage, or IDB.
  await setActiveBridgeVaultKeyMaterial(clean);
  return key;
}

/**
 * Unlock vault with a hex key, storing the non-extractable handle and optionally persisting to IndexedDB.
 */
export async function unlockVaultWithHex(hexKey: string, remember = true): Promise<CryptoKey> {
  const clean = validateHexVaultKey(hexKey);
  const key = await importRawKeyHex(clean);
  installActiveVaultKeys(key, null, remember);
  await setActiveBridgeVaultKeyMaterial(clean);
  return key;
}

/** Prove transient raw material represents the already-active content key. */
export async function verifyActiveVaultKeyMaterial(rawHex: string): Promise<boolean> {
  const keyring = getActiveVaultKey();
  const clean = String(rawHex || '').trim().toLowerCase();
  if (!keyring || !/^[0-9a-f]{64}$/.test(clean)) return false;
  const activeKey = keyring.keys.get(ADAPTER_EPOCH);
  if (!activeKey) return false;
  try {
    const candidateKey = await importRawKeyHex(clean);
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const probe = crypto.getRandomValues(new Uint8Array(32));
    const ciphertext = await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: nonce },
      activeKey,
      probe,
    );
    const opened = new Uint8Array(await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: nonce },
      candidateKey,
      ciphertext,
    ));
    return opened.length === probe.length && opened.every((byte, index) => byte === probe[index]);
  } catch {
    return false;
  }
}

/**
 * Restore non-extractable CryptoKey from IndexedDB on page load/init (REQ-VAULT-HARDEN-2).
 */
export async function initializeVaultPersistence(
  dispatch?: (action: any) => void,
): Promise<CryptoKey | null> {
  try {
    const keys = await restoreVaultKeys();
    if (keys) {
      installActiveVaultKeys(keys.contentKey, keys.taskChainSearchKey, true);
      if (dispatch) {
        dispatch(hydrateVaultFromSession());
      }
      return keys.contentKey;
    }
  } catch (err) {
    console.warn('Failed to restore vault key from IndexedDB:', err);
  }
  return null;
}

/**
 * Strictly serializable Redux state for the Vault slice.
 * Contains no raw keys and no non-serializable objects (REQ-VAULT-HARDEN-1).
 */
export interface VaultState {
  isConfigured: boolean;
  isUnlocked: boolean;
  isUnlockModalOpen?: boolean;
  unlockModalPurpose?: 'search-reauthentication';
}

export function loadInitialVaultState(): VaultState {
  return {
    isConfigured: false,
    isUnlocked: Boolean(getActiveVaultKey()),
    isUnlockModalOpen: false,
  };
}

const initialState: VaultState = loadInitialVaultState();

export const vaultSlice = createSlice({
  name: 'vault',
  initialState,
  reducers: {
    setVaultConfigured(state, action: PayloadAction<boolean>) {
      state.isConfigured = action.payload;
      if (!action.payload) {
        state.isUnlocked = false;
        state.isUnlockModalOpen = false;
        delete state.unlockModalPurpose;
        installActiveVaultKeys(null);
        clearSessionVaultKey();
        deleteVaultKey().catch(() => {});
      }
    },
    openUnlockModal(state) {
      state.isUnlockModalOpen = true;
      delete state.unlockModalPurpose;
    },
    openSearchReauthentication(state) {
      state.isUnlockModalOpen = true;
      state.unlockModalPurpose = 'search-reauthentication';
    },
    closeUnlockModal(state) {
      state.isUnlockModalOpen = false;
      delete state.unlockModalPurpose;
    },
    setUnlockModalOpen(state, action: PayloadAction<boolean>) {
      state.isUnlockModalOpen = action.payload;
      if (!action.payload) delete state.unlockModalPurpose;
    },
    setVaultUnlocked: {
      reducer(
        state,
        action: PayloadAction<{
          key?: CryptoKey;
          rawVaultKeyHex?: string;
          rememberSession?: boolean;
        } | void>,
      ) {
        state.isConfigured = true;
        state.isUnlocked = true;
        state.isUnlockModalOpen = false;
        delete state.unlockModalPurpose;

        const payload = action.payload;
        if (payload && typeof payload === 'object') {
          if ('algorithm' in payload) {
            installActiveVaultKeys(payload as CryptoKey, null, true);
            persistVaultKey(payload as CryptoKey).catch(() => {});
          } else if (payload.key) {
            const remembered = payload.rememberSession !== false;
            installActiveVaultKeys(payload.key, null, remembered);
            if (payload.rawVaultKeyHex) {
              setActiveBridgeVaultKeyMaterial(payload.rawVaultKeyHex);
            }
            if (payload.rememberSession !== false) {
              persistVaultKey(payload.key).catch(() => {});
            }
          } else if (payload.rawVaultKeyHex) {
            // Asynchronously import hex key for backward compatibility with tests
            importRawKeyHex(payload.rawVaultKeyHex).then((key) => {
              const remembered = payload.rememberSession === true;
              installActiveVaultKeys(key, null, remembered);
              setActiveBridgeVaultKeyMaterial(payload.rawVaultKeyHex || null);
              if (payload.rememberSession) {
                persistVaultKey(key).catch(() => {});
              }
            }).catch(() => {});
          }
        }
      },
      prepare(
        payloadOrKey?: any,
        maybeRemember?: boolean,
      ) {
        if (!payloadOrKey) {
          return { payload: undefined };
        }
        if (typeof payloadOrKey === 'string') {
          return {
            payload: {
              rawVaultKeyHex: payloadOrKey,
              rememberSession: maybeRemember,
            },
          };
        }
        if (typeof payloadOrKey === 'object' && 'algorithm' in payloadOrKey) {
          return {
            payload: {
              key: payloadOrKey as CryptoKey,
              rememberSession: maybeRemember !== false,
            },
          };
        }
        return {
          payload: {
            key: payloadOrKey.key,
            rawVaultKeyHex: payloadOrKey.rawVaultKeyHex,
            rememberSession: payloadOrKey.rememberSession ?? maybeRemember,
          },
        };
      },
    },
    importLocalKey: {
      reducer(
        state,
        action: PayloadAction<{
          hexKey?: string;
          key?: CryptoKey;
          rememberSession?: boolean;
        } | void>,
      ) {
        state.isConfigured = true;
        state.isUnlocked = true;
        state.isUnlockModalOpen = false;
        delete state.unlockModalPurpose;

        const payload = action.payload;
        if (payload && typeof payload === 'object') {
          if ('algorithm' in payload) {
            installActiveVaultKeys(payload as CryptoKey, null, true);
            persistVaultKey(payload as CryptoKey).catch(() => {});
          } else if (payload.key) {
            const remembered = payload.rememberSession !== false;
            installActiveVaultKeys(payload.key, null, remembered);
            if (payload.hexKey) setActiveBridgeVaultKeyMaterial(payload.hexKey);
            if (payload.rememberSession !== false) {
              persistVaultKey(payload.key).catch(() => {});
            }
          } else if (payload.hexKey) {
            importRawKeyHex(payload.hexKey).then((key) => {
              const remembered = payload.rememberSession === true;
              installActiveVaultKeys(key, null, remembered);
              setActiveBridgeVaultKeyMaterial(payload.hexKey || null);
              if (payload.rememberSession) {
                persistVaultKey(key).catch(() => {});
              }
            }).catch(() => {});
          }
        }
      },
      prepare(
        payloadOrHex?: any,
        maybeRemember?: boolean,
      ) {
        if (!payloadOrHex) {
          return { payload: undefined };
        }
        if (typeof payloadOrHex === 'string') {
          return {
            payload: {
              hexKey: payloadOrHex,
              rememberSession: Boolean(maybeRemember),
            },
          };
        }
        // A bare CryptoKey, mirroring setVaultUnlocked.prepare above. Without this
        // branch the object branch below reads `.hexKey`/`.key` off the CryptoKey --
        // both undefined -- so `prepare` DESTROYED the key before the reducer saw it.
        // The reducer's own `'algorithm' in payload` branch could not save it either,
        // because the returned payload no longer carries `algorithm`. All three
        // install branches missed while `state.isUnlocked = true` still ran, leaving
        // the store claiming unlocked with nothing able to decrypt and no async
        // recovery path. Latent rather than live: no current call site passes a bare
        // key here.
        if (typeof payloadOrHex === 'object' && 'algorithm' in payloadOrHex) {
          return {
            payload: {
              key: payloadOrHex as CryptoKey,
              rememberSession: maybeRemember !== false,
            },
          };
        }
        return {
          payload: {
            hexKey: payloadOrHex.hexKey,
            key: payloadOrHex.key,
            rememberSession: Boolean(payloadOrHex.rememberSession ?? maybeRemember),
          },
        };
      },
    },
    hydrateVaultFromSession(state) {
      if (getActiveVaultKey()) {
        state.isConfigured = true;
        state.isUnlocked = true;
      }
    },
    lockVault(state) {
      state.isUnlocked = false;
      state.isUnlockModalOpen = false;
      delete state.unlockModalPurpose;
      installActiveVaultKeys(null);
      clearSessionVaultKey();
      deleteVaultKey().catch(() => {});
    },
  },
});

export const {
  setVaultConfigured,
  setVaultUnlocked,
  importLocalKey,
  hydrateVaultFromSession,
  lockVault,
  openUnlockModal,
  openSearchReauthentication,
  closeUnlockModal,
  setUnlockModalOpen,
} = vaultSlice.actions;

export const VAULT_UNSUPPORTED_TITLE = 'User Vault unavailable';
export const VAULT_UNSUPPORTED_REASON =
  'User Vault unavailable: this page is not a secure context, so Web Crypto (crypto.subtle) is missing. Open Heimdall over HTTPS or on localhost.';

export type VaultStatus = 'Disabled' | 'Locked' | 'Unlocked';

export function resolveVaultStatus(args: {
  isConfigured: boolean;
  isUnlocked: boolean;
}): VaultStatus {
  if (!args.isConfigured) return 'Disabled';
  return args.isUnlocked ? 'Unlocked' : 'Locked';
}

export type VaultStatusLabel = 'Unsupported' | 'Unlocked' | 'Locked' | 'Unconfigured';

export function vaultStatusLabel(args: {
  isVaultUnlocked: boolean;
  isVaultConfigured: boolean;
  supported?: boolean;
}): VaultStatusLabel {
  const supported = args.supported ?? isVaultSupported();
  if (!supported) return 'Unsupported';
  if (args.isVaultUnlocked) return 'Unlocked';
  return args.isVaultConfigured ? 'Locked' : 'Unconfigured';
}

export function shouldOpenVaultOnboarding(args: {
  isVaultUnlocked: boolean;
  dismissed: boolean;
  supported?: boolean;
}): boolean {
  const supported = args.supported ?? isVaultSupported();
  if (!supported) return false;
  return !args.isVaultUnlocked && !args.dismissed;
}

export const selectVaultState = (state: { vault?: VaultState }) => state?.vault;
export const selectIsVaultConfigured = (state: { vault?: VaultState }) => Boolean(state?.vault?.isConfigured);
export const selectIsVaultUnlocked = (state: { vault?: VaultState }) => Boolean(state?.vault?.isUnlocked);
/**
 * Deprecated: raw key material never enters Redux state (REQ-VAULT-HARDEN-1, REQ-RAWKEY-A7).
 * `VaultState.rawVaultKeyHex` has been removed, so this selector is retained only as a
 * shim for callers that still import it and always returns null. Resolve the key with
 * `getActiveVaultKey()` instead -- note `selectActiveVaultKey` below is NOT reactive.
 */
export const selectRawVaultKeyHex = (_state?: { vault?: VaultState }): string | null => null;
export const selectActiveVaultKey = (_state?: { vault?: VaultState }): VaultKeyring | null => getActiveVaultKey();
export const selectIsUnlockModalOpen = (state: { vault?: VaultState }) => Boolean(state?.vault?.isUnlockModalOpen);
export const selectIsSearchReauthentication = (state: { vault?: VaultState }) => (
  state?.vault?.unlockModalPurpose === 'search-reauthentication'
);

export default vaultSlice.reducer;
