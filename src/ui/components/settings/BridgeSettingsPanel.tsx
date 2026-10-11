import React, { useState, useCallback, useMemo, type FormEvent } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  Button,
  Input,
  StatusPill,
  Icon,
  Modal,
  ModalBody,
  ModalFooter,
} from '@ui';
import {
  type Bridge,
  bridgeSupportApi,
  useListBridgesQuery,
} from '../../api/endpoints/bridgeSupport';
import {
  useGetUserVaultQuery,
} from '../../api/endpoints/userVault';
import {
  selectIsVaultConfigured,
  selectIsVaultUnlocked,
  setVaultUnlocked,
  lockVault,
  resolveVaultStatus,
  type VaultStatus,
  getActiveVaultKey,
  getActiveBridgeVaultKeyMaterial,
  setActiveBridgeVaultKeyMaterial,
} from '../../store/vaultSlice';
import {
  fetchBridgePublicKey,
  unsealBridgeE2EE,
  lockBridge,
  unsealAllConnectedBridges,
  lockAllConnectedBridges,
} from '../../api/endpoints/bridges';
import {
  deriveKeyFromPassword,
  decryptVaultKeyEnvelope,
  decryptVaultKeyEnvelopeHex,
  DEFAULT_KDF_ITERATIONS,
} from '../../utils/vaultCrypto';
import { canUnsealWithKey, resolveUnsealOutcome } from '../../utils/vaultBridgeUnseal';
import {
  resolveBridgeVaultStatus,
  canLockBridgeVault,
  canUnlockBridgeVault,
  canConfigureBridgeVault,
  BRIDGE_VAULT_STATUS_TONE,
  type BridgeVaultStatus,
} from '../../utils/bridgeVaultStatus';
import VaultOnboardingModal from './VaultOnboardingModal';

// REQ-BVS-3: the visible wording for each of the five per-bridge states. The state is
// carried by these WORDS, not by the pill colour — `Unknown` is neutral and says so,
// so a bridge that never reported can never be mistaken for an unlocked one.
const BRIDGE_VAULT_STATUS_LABEL: Record<BridgeVaultStatus, string> = {
  NotRunning: 'Not running',
  NotConfigured: 'Not configured',
  Locked: 'Bridge Locked',
  Unlocked: 'Bridge Unlocked',
  Unknown: 'Unknown',
};

const BRIDGE_VAULT_STATUS_DESCRIPTION: Record<BridgeVaultStatus, string> = {
  NotRunning: 'Bridge is offline. Its vault state cannot be determined and it holds no key.',
  NotConfigured: 'Encryption is not configured on this bridge. Files and terminal streams run unencrypted.',
  Locked: 'Vault is locked on this bridge. Unseal it to resume encrypted file and terminal access.',
  Unlocked: 'Vault is unsealed on this bridge. Files and terminal chunks are encrypted with AES-256-GCM.',
  Unknown: 'This bridge has not reported a vault state (older build). Treated as unknown, not unlocked.',
};

// REQ-T4-2: a NotConfigured bridge whose owner HAS a vault is not "unencrypted by
// choice" — it simply has not been given the key yet, so the row says so and offers
// to configure it rather than describing a dead end.
const BRIDGE_VAULT_CONFIGURABLE_DESCRIPTION =
  'Encryption is enabled for your account but this bridge has no key yet. Configure it to encrypt files and terminal streams on this machine.';

/** Reads the bridge id out of whichever casing the API happened to use. */
function bridgeIdOf(bridge: Bridge | undefined | null): string {
  return String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
}

/** Human label for a bridge row, falling back through label -> hostname -> id. */
function bridgeNameOf(bridge: Bridge): string {
  return String(bridge?.label || bridge?.machine_hostname || bridge?.hostname || bridgeIdOf(bridge) || 'Unknown bridge');
}

export interface BridgeSettingsPanelProps {
  bridges?: Bridge[];
  selectedBridgeId?: string;
  onOpenVaultSetup?: () => void;
}

export default function BridgeSettingsPanel({
  bridges: propBridges,
  selectedBridgeId,
  onOpenVaultSetup,
}: BridgeSettingsPanelProps) {
  const dispatch = useDispatch();
  const queryBridgesResult = useListBridgesQuery(undefined, { skip: Boolean(propBridges && propBridges.length > 0) });
  const bridges: Bridge[] = (propBridges && propBridges.length > 0) ? propBridges : (queryBridgesResult.data?.bridges || []);

  const isConfigured = useSelector(selectIsVaultConfigured);
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const userVaultQuery = useGetUserVaultQuery();
  const vaultEnvelope = userVaultQuery.data?.vault;

  // Tri-state status of THIS UI CLIENT's vault: 'Disabled' | 'Locked' | 'Unlocked'.
  // REQ-BVS-3: this value says nothing whatsoever about any bridge — it is derived
  // purely from the client's own Redux/CryptoKey state. It used to be rendered as the
  // one and only "Bridge Locked / Bridge Unlocked" pill, identical next to every
  // bridge, which is exactly the bug this task fixes. It is kept ONLY for the
  // client-scoped concerns it genuinely answers: whether encryption is configured at
  // all, and whether this client currently holds a key it could send to a bridge.
  // Per-bridge state comes from `bridge.vault_status` via `resolveBridgeVaultStatus`.
  // REQ-T4-1: "the owner has a vault" — the same expression that decides whether this
  // client's encryption is configured at all. Gates per-bridge "Configure encryption".
  const ownerHasVault = Boolean(isConfigured || vaultEnvelope?.encrypted_vault_key);
  const clientVaultStatus: VaultStatus = resolveVaultStatus({
    isConfigured: ownerHasVault,
    isUnlocked,
  });

  const [unlockModalOpen, setUnlockModalOpen] = useState(false);
  const [onboardingOpen, setOnboardingOpen] = useState(false);
  const [masterPassword, setMasterPassword] = useState('');
  const [rememberSession, setRememberSession] = useState(true);
  const [unlockBusy, setUnlockBusy] = useState(false);
  const [unlockError, setUnlockError] = useState('');
  const [lockBusy, setLockBusy] = useState(false);
  const [unsealSuccessMsg, setUnsealSuccessMsg] = useState('');

  // REQ-BVS-3/REQ-BVS-4: per-bridge busy / error / success, keyed by bridge id so one
  // bridge's failed lock never paints over another row.
  const [bridgeBusy, setBridgeBusy] = useState<Record<string, 'lock' | 'unlock'>>({});
  const [bridgeError, setBridgeError] = useState<Record<string, string>>({});
  const [bridgeNotice, setBridgeNotice] = useState<Record<string, string>>({});

  // REQ-UNSEAL-1: when the key this client holds cannot be wrapped for a bridge, the
  // operator is asked for it through the ONE existing key-entry surface (the master
  // password modal below). This records which single bridge that prompt was raised
  // for, so submitting it unseals that row rather than silently widening to every
  // bridge; `null` means the prompt came from the client-scoped control and targets
  // all of `targetBridges`, which is the pre-existing behaviour.
  const [pendingUnsealBridgeId, setPendingUnsealBridgeId] = useState<string | null>(null);

  // REQ-BVS-3: the per-bridge rows — the single source of truth for "which bridges does
  // this panel act on". Each row's badge is derived from THAT bridge's reported
  // `vault_status` plus hub liveness, never from this client's `isUnlocked`.
  const bridgeRows: Array<{ bridge: Bridge; id: string; name: string; status: BridgeVaultStatus }> = useMemo(
    () =>
      bridges
        .filter((b: Bridge) => {
          const id = bridgeIdOf(b);
          if (!id) return false;
          if (selectedBridgeId) return id === selectedBridgeId;
          return String(b?.status || b?.runtime_status || '').toLowerCase() !== 'revoked';
        })
        .map((bridge: Bridge) => ({
          bridge,
          id: bridgeIdOf(bridge),
          name: bridgeNameOf(bridge),
          status: resolveBridgeVaultStatus({
            bridgeStatus: bridge?.status || bridge?.runtime_status,
            vaultStatus: bridge?.vault_status,
          }),
        })),
    [bridges, selectedBridgeId],
  );

  // Target bridges for the CLIENT-scoped actions (either `selectedBridgeId` or every
  // non-revoked bridge). Derived from `bridgeRows` so the two cannot drift apart — it
  // used to be a second hand-rolled copy of the same filter.
  const targetBridges = useMemo(() => bridgeRows.map((row) => row.bridge), [bridgeRows]);

  // After a per-bridge lock/unseal the authoritative state is whatever the bridge next
  // reports, so the badge is refreshed by re-reading the bridges list rather than being
  // flipped optimistically in local state (REQ-BVS-4: a failed lock must not look like
  // a success). Invalidating the tag also refreshes the copy held by a parent that
  // passed `bridges` in as a prop.
  const refreshBridges = useCallback(() => {
    dispatch(bridgeSupportApi.util.invalidateTags([{ type: 'Bridges' as const, id: 'LIST' }]) as any);
  }, [dispatch]);

  /**
   * REQ-BVS-5: locks ONE bridge and nothing else.
   *
   * It deliberately does NOT dispatch `lockVault()` and does not clear the active
   * CryptoKey: locking a remote machine's vault is not a reason to lock the operator's
   * own browser out of every other bridge. After this runs, `getActiveVaultKey()` still
   * returns the key and every other bridge is untouched.
   *
   * `lockBridge` now throws on failure (REQ-BVS-4), so a failure surfaces as a row
   * error and the badge stays on whatever the bridge still reports.
   */
  const handleBridgeLock = useCallback(async (bridgeId: string) => {
    if (!bridgeId) return;
    setBridgeBusy((prev) => ({ ...prev, [bridgeId]: 'lock' }));
    setBridgeError((prev) => ({ ...prev, [bridgeId]: '' }));
    setBridgeNotice((prev) => ({ ...prev, [bridgeId]: '' }));
    try {
      await lockBridge(bridgeId);
      setBridgeNotice((prev) => ({ ...prev, [bridgeId]: 'Lock requested. Vault key purged on this bridge.' }));
      refreshBridges();
    } catch (err: any) {
      setBridgeError((prev) => ({
        ...prev,
        [bridgeId]: `Failed to lock this bridge: ${err?.message || String(err)}`,
      }));
    } finally {
      setBridgeBusy((prev) => {
        const next = { ...prev };
        delete next[bridgeId];
        return next;
      });
    }
  }, [refreshBridges]);

  /**
   * Opens the master-password prompt so the operator can supply key material for an
   * unseal (REQ-UNSEAL-1, REQ-UNSEAL-4).
   *
   * `bridgeId` scopes it to one row; `null` means the client-scoped control raised it
   * and every target bridge is unsealed on submit. This reuses the modal that already
   * existed for "Unlock this client" -- there is deliberately no second key-entry
   * surface, and nothing is cached so that a later unseal can skip the prompt.
   */
  const promptForUnsealKey = useCallback((bridgeId: string | null) => {
    setPendingUnsealBridgeId(bridgeId);
    setMasterPassword('');
    setUnlockError('');
    setUnsealSuccessMsg('');
    setUnlockModalOpen(true);
  }, []);

  /**
   * Unseals ONE bridge.
   *
   * REQ-UNSEAL-1: the two ways this client can come to hold a key -- the operator
   * typed/derived it this session, or it was restored from IndexedDB at boot -- both
   * end up holding a NON-extractable handle, and the unseal protocol has to transmit
   * the master key itself. So neither path can unseal from the handle alone, and both
   * take exactly the same branch below into the password prompt. They converge on one
   * code path rather than one of them happening to work: the hex side-channel that
   * used to make the typed path succeed (and only until the next reload) is gone.
   */
  const handleBridgeUnlock = useCallback(async (bridgeId: string) => {
    if (!bridgeId) return;
    const activeKey = getActiveBridgeVaultKeyMaterial() || getActiveVaultKey();
    if (!activeKey) {
      setBridgeError((prev) => ({
        ...prev,
        [bridgeId]: 'This client holds no vault key. Unlock the client vault first, then unseal this bridge.',
      }));
      return;
    }
    if (!canUnsealWithKey(activeKey)) {
      setBridgeError((prev) => ({ ...prev, [bridgeId]: '' }));
      setBridgeNotice((prev) => ({
        ...prev,
        [bridgeId]:
          'Re-enter your master password to unseal this bridge: the key held in this browser is a non-extractable handle and cannot be wrapped for a bridge.',
      }));
      promptForUnsealKey(bridgeId);
      return;
    }
    setBridgeBusy((prev) => ({ ...prev, [bridgeId]: 'unlock' }));
    setBridgeError((prev) => ({ ...prev, [bridgeId]: '' }));
    setBridgeNotice((prev) => ({ ...prev, [bridgeId]: '' }));
    try {
      const pubKey = await fetchBridgePublicKey(bridgeId);
      if (!pubKey) {
        throw new Error('Bridge advertised no public key — it may have gone offline.');
      }
      await unsealBridgeE2EE(bridgeId, pubKey, activeKey);
      setBridgeNotice((prev) => ({ ...prev, [bridgeId]: 'Unseal payload delivered to this bridge.' }));
      refreshBridges();
    } catch (err: any) {
      setBridgeError((prev) => ({
        ...prev,
        [bridgeId]: `Failed to unseal this bridge: ${err?.message || String(err)}`,
      }));
    } finally {
      setBridgeBusy((prev) => {
        const next = { ...prev };
        delete next[bridgeId];
        return next;
      });
    }
  }, [refreshBridges, promptForUnsealKey]);

  /**
   * REQ-T4-2/REQ-T4-3: configures a NotConfigured bridge by unsealing it — the SAME
   * path as the row's Unlock. The one difference is a locked client: Unlock can only
   * send a key the client already holds, whereas Configure opens the existing
   * master-password prompt scoped to this one bridge, so the operator is never sent
   * to the client-scoped "Unlock this client" (which unseals every bridge).
   */
  const handleBridgeConfigure = useCallback((bridgeId: string) => {
    if (!bridgeId) return;
    if (!(getActiveBridgeVaultKeyMaterial() || getActiveVaultKey())) {
      setBridgeError((prev) => ({ ...prev, [bridgeId]: '' }));
      promptForUnsealKey(bridgeId);
      return;
    }
    void handleBridgeUnlock(bridgeId);
  }, [handleBridgeUnlock, promptForUnsealKey]);

  const handleUnlockClick = useCallback(async () => {
    setUnlockError('');
    setUnsealSuccessMsg('');

    // If the key already in memory can actually be wrapped for a bridge, unseal
    // directly. REQ-UNSEAL-1: a non-extractable handle cannot, whether it was derived
    // this session or restored from IndexedDB, so both of those fall through to the
    // prompt below instead of one of them reaching into a cached hex copy.
    const activeKey = getActiveVaultKey();
    if (isUnlocked && activeKey && canUnsealWithKey(activeKey)) {
      setUnlockBusy(true);
      try {
        let unsealedCount = 0;
        const candidates = targetBridges.length > 0 ? targetBridges : bridges;
        for (const bridge of candidates) {
          const bridgeId = bridgeIdOf(bridge);
          if (!bridgeId) continue;
          try {
            const pubKey = await fetchBridgePublicKey(bridgeId);
            if (pubKey) {
              await unsealBridgeE2EE(bridgeId, pubKey, activeKey);
              unsealedCount++;
            }
          } catch (bridgeErr) {
            console.warn(`[BridgeSettingsPanel] failed unsealing bridge ${bridgeId}:`, bridgeErr);
          }
        }
        if (unsealedCount === 0 && candidates.length === 0) {
          unsealedCount = await unsealAllConnectedBridges(activeKey);
        }
        setUnsealSuccessMsg(
          unsealedCount > 0
            ? `Successfully unsealed ${unsealedCount} bridge${unsealedCount === 1 ? '' : 's'}.`
            : 'Bridge unseal payload dispatched.'
        );
      } catch (err: any) {
        setUnlockError(err?.message || 'Failed to unseal bridge');
      } finally {
        setUnlockBusy(false);
      }
      return;
    }

    // Otherwise, prompt for the master password. Client-scoped, so no single bridge.
    promptForUnsealKey(null);
  }, [isUnlocked, targetBridges, bridges, promptForUnsealKey]);

  const handlePasswordUnlockSubmit = useCallback(async (e: FormEvent) => {
    e.preventDefault();
    if (!masterPassword || !vaultEnvelope) return;

    setUnlockBusy(true);
    setUnlockError('');

    try {
      const derivedKey = await deriveKeyFromPassword(
        masterPassword,
        vaultEnvelope.kdf_salt,
        vaultEnvelope.kdf_iterations || DEFAULT_KDF_ITERATIONS
      );

      // REQ-UNSEAL-3: the master key is obtained TWICE from the same envelope, in two
      // deliberately different shapes, and neither widens what is kept at rest:
      //
      //  * `unsealHex` is the raw hex the unseal protocol has to transmit. It is a
      //    local `const` for the duration of this submit and is never cached, stored,
      //    or put in Redux -- the module-level hex cache that used to serve this role
      //    is deleted. It dies with this closure, so the next unseal in a later
      //    session prompts again.
      //  * `decryptedVaultKey` is the handle installed as the active key, imported
      //    NON-extractable. This previously asked for `extractable: true` purely so
      //    that `exportKey` could later recover the hex for an unseal; now that the
      //    hex is passed explicitly, the long-lived key no longer has to be
      //    exfiltratable, which narrows the exposure this path leaves behind.
      const unsealHex = await decryptVaultKeyEnvelopeHex(
        derivedKey,
        vaultEnvelope.encrypted_vault_key,
        vaultEnvelope.vault_key_nonce,
        vaultEnvelope.vault_key_tag
      );

      const decryptedVaultKey = await decryptVaultKeyEnvelope(
        derivedKey,
        vaultEnvelope.encrypted_vault_key,
        vaultEnvelope.vault_key_nonce,
        vaultEnvelope.vault_key_tag
      );

      dispatch(setVaultUnlocked({
        key: decryptedVaultKey,
        rememberSession,
      }));
      setActiveBridgeVaultKeyMaterial(unsealHex);

      // Unseal with the hex just derived. When the prompt was raised by a single
      // bridge row, unseal only that row: a prompt the operator answered for one
      // bridge is not consent to push the key to every other one.
      const pendingBridge = pendingUnsealBridgeId
        ? bridges.find((b) => bridgeIdOf(b) === pendingUnsealBridgeId)
        : undefined;
      const candidates = pendingUnsealBridgeId
        ? (pendingBridge ? [pendingBridge] : [])
        : (targetBridges.length > 0 ? targetBridges : bridges);

      let unsealedCount = 0;
      const failedUnseals: string[] = [];
      for (const bridge of candidates) {
        const bridgeId = bridgeIdOf(bridge);
        if (!bridgeId) continue;
        try {
          const pubKey = await fetchBridgePublicKey(bridgeId);
          if (!pubKey) {
            throw new Error('Bridge advertised no public key — it may have gone offline.');
          }
          await unsealBridgeE2EE(bridgeId, pubKey, unsealHex);
          unsealedCount++;
        } catch (bridgeErr: any) {
          // REQ-UNSEAL-4: a failed unseal is reported, not just logged to a console
          // nobody is reading, and never retried with a weaker payload.
          console.warn(`[BridgeSettingsPanel] failed unsealing bridge ${bridgeId}:`, bridgeErr);
          failedUnseals.push(bridgeNameOf(bridge));
          if (pendingUnsealBridgeId === bridgeId) {
            setBridgeError((prev) => ({
              ...prev,
              [bridgeId]: `Failed to unseal this bridge: ${bridgeErr?.message || String(bridgeErr)}`,
            }));
          }
        }
      }
      if (unsealedCount === 0 && candidates.length === 0 && !pendingUnsealBridgeId) {
        unsealedCount = await unsealAllConnectedBridges(unsealHex);
      }

      setUnlockModalOpen(false);
      setMasterPassword('');
      setPendingUnsealBridgeId(null);

      // REQ-UNSEAL-4/5: say what actually happened. The vault is unlocked by this
      // point either way, so the only question left is whether an unseal was really
      // sent -- and `targeted-bridge-missing` is the case where none was, with
      // nothing having failed to make that obvious.
      const outcome = resolveUnsealOutcome({
        pendingUnsealBridgeId,
        pendingBridgeFound: Boolean(pendingBridge),
        unsealedCount,
        failedCount: failedUnseals.length,
      });

      if (outcome.kind === 'targeted-bridge-missing') {
        setBridgeError((prev) => ({
          ...prev,
          [pendingUnsealBridgeId as string]:
            'This bridge is no longer listed, so nothing was unsealed. Refresh and try again.',
        }));
        setUnlockError('That bridge is no longer listed, so no unseal was sent. The vault is unlocked.');
        setUnsealSuccessMsg('');
        refreshBridges();
        return;
      }

      if (failedUnseals.length > 0) {
        setUnlockError(`Could not unseal ${failedUnseals.length} bridge(s): ${failedUnseals.join(', ')}.`);
      }
      if (outcome.kind === 'unsealed' && pendingUnsealBridgeId) {
        setBridgeNotice((prev) => ({
          ...prev,
          [pendingUnsealBridgeId]: 'Unseal payload delivered to this bridge.',
        }));
      }
      setUnsealSuccessMsg(
        outcome.kind === 'unsealed'
          ? `Successfully unsealed ${outcome.count} bridge${outcome.count === 1 ? '' : 's'}.`
          : outcome.kind === 'failed'
            ? ''
            : 'Bridge unlocked and unseal dispatched.'
      );
      refreshBridges();
    } catch (err: any) {
      setUnlockError(err?.message || 'Incorrect master password. Failed to unlock vault.');
    } finally {
      setUnlockBusy(false);
    }
  }, [masterPassword, vaultEnvelope, rememberSession, dispatch, targetBridges, bridges, pendingUnsealBridgeId, refreshBridges]);

  const handleLockClick = useCallback(async () => {
    setLockBusy(true);
    setUnlockError('');
    setUnsealSuccessMsg('');

    try {
      // 1. Lock target bridges first over network
      const candidates = targetBridges.length > 0 ? targetBridges : bridges;
      // REQ-BVS-4: `lockBridge` now throws instead of reporting a fabricated success,
      // so a bridge that could not be locked is collected and reported rather than
      // being logged to a console nobody is reading.
      const failedLocks: string[] = [];
      for (const bridge of candidates) {
        const bridgeId = bridgeIdOf(bridge);
        if (!bridgeId) continue;
        try {
          await lockBridge(bridgeId);
        } catch (err) {
          console.warn(`[BridgeSettingsPanel] lock request failed for bridge ${bridgeId}:`, err);
          failedLocks.push(bridgeNameOf(bridge));
        }
      }
      if (failedLocks.length > 0) {
        setUnlockError(`Could not lock ${failedLocks.length} bridge(s): ${failedLocks.join(', ')}.`);
      }
      if (candidates.length === 0) {
        await lockAllConnectedBridges();
      }

      // 2. Purge UI vault key from Redux and memory
      // Client-scoped: this is the "lock this client & all bridges" control, so purging
      // the client's own key is intended here. The PER-BRIDGE Lock above must NOT do
      // this (REQ-BVS-5).
      dispatch(lockVault());

      refreshBridges();
      setUnsealSuccessMsg('This client locked and its key purged from memory.');
    } catch (err: any) {
      setUnlockError(err?.message || 'Failed to lock bridge');
    } finally {
      setLockBusy(false);
    }
  }, [dispatch, targetBridges, bridges, refreshBridges]);

  return (
    <div
      data-debug-id="bridge-settings-panel"
      className="w-full max-w-full overflow-hidden rounded-xl border border-subtle bg-surface-raised/40 p-3.5 sm:p-4 my-3"
    >
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-sm font-semibold text-primary">Bridge Encryption & Vault</span>
            {/*
              CLIENT-scoped pill. It reports whether THIS browser has encryption
              configured and whether it currently holds the key — nothing about any
              bridge. Each bridge's own state is the per-bridge badge further down.
            */}
            {clientVaultStatus === 'Disabled' && (
              <StatusPill tone="neutral" data-debug-id="bridge-vault-status-pill">
                Encryption: Disabled (Optional)
              </StatusPill>
            )}
            {clientVaultStatus === 'Locked' && (
              <StatusPill tone="warning" data-debug-id="bridge-vault-status-pill">
                This client: Locked
              </StatusPill>
            )}
            {clientVaultStatus === 'Unlocked' && (
              <StatusPill tone="success" data-debug-id="bridge-vault-status-pill">
                This client: Unlocked
              </StatusPill>
            )}
          </div>
          <p className="mt-1 text-xs text-muted leading-relaxed break-words">
            {clientVaultStatus === 'Disabled' &&
              'End-to-end encrypted storage and terminal streaming are currently optional and not configured. Files and terminal streams execute without encryption.'}
            {clientVaultStatus === 'Locked' &&
              'This client holds no vault key. Unlock with your master password to unseal bridges; until then no bridge can be unsealed from here.'}
            {clientVaultStatus === 'Unlocked' &&
              'This client holds the vault key and can unseal bridges. Each bridge reports its own state below.'}
          </p>
        </div>

        <div className="flex flex-wrap items-center gap-2 pt-1 sm:pt-0">
          {clientVaultStatus === 'Disabled' && (
            <Button
              variant="secondary"
              size="sm"
              data-debug-id="bridge-vault-setup-btn"
              className="min-h-[44px] min-w-[44px] touch-manipulation w-full sm:w-auto"
              onClick={() => {
                if (onOpenVaultSetup) onOpenVaultSetup();
                else setOnboardingOpen(true);
              }}
            >
              <Icon name="lock" size="sm" className="mr-1.5" />
              Enable Encryption
            </Button>
          )}

          {/*
            CLIENT-scoped controls, unchanged in behaviour. "Unlock this client" prompts
            for the master password and then unseals the target bridges, which is how a
            locked client gets a key in the first place — the per-bridge Unlock below
            cannot do that, it can only send a key the client already holds.
          */}
          {clientVaultStatus === 'Locked' && (
            <Button
              variant="primary"
              size="sm"
              loading={unlockBusy}
              data-debug-id="bridge-vault-unlock-btn"
              className="min-h-[44px] min-w-[44px] touch-manipulation w-full sm:w-auto"
              onClick={() => void handleUnlockClick()}
            >
              <Icon name="lock" size="sm" className="mr-1.5" />
              Unlock this client
            </Button>
          )}

          {clientVaultStatus === 'Unlocked' && (
            <Button
              variant="secondary"
              size="sm"
              loading={lockBusy}
              data-debug-id="bridge-vault-lock-btn"
              className="min-h-[44px] min-w-[44px] touch-manipulation w-full sm:w-auto text-danger hover:border-danger/40"
              onClick={() => void handleLockClick()}
            >
              <Icon name="lock" size="sm" className="mr-1.5" />
              Lock this client &amp; all bridges
            </Button>
          )}
        </div>
      </div>

      {/*
        REQ-BVS-3/4/5: one row per bridge, each reporting ITS OWN vault state.
        The badge is derived from `bridge.vault_status` + hub liveness
        (`resolveBridgeVaultStatus`), never from this client's `isUnlocked`.
      */}
      <div className="mt-3 flex flex-col gap-2" data-debug-id="bridge-vault-per-bridge-list">
        {bridgeRows.length === 0 ? (
          <p className="text-xs text-muted" data-debug-id="bridge-vault-no-bridges">
            No bridges to report. Enroll a bridge to see its vault state here.
          </p>
        ) : (
          bridgeRows.map(({ id, name, status }) => {
            const busy = bridgeBusy[id];
            const rowError = bridgeError[id] || '';
            const rowNotice = bridgeNotice[id] || '';
            // Unseal needs a key in hand; a locked client has none to send.
            const clientHoldsKey = clientVaultStatus === 'Unlocked';
            const unlockAllowed = canUnlockBridgeVault(status) && clientHoldsKey;
            // REQ-T4-2: shown even while this client is locked (REQ-T4-3) — clicking it
            // then asks for the master password for this bridge only.
            const configureAllowed = canConfigureBridgeVault(status, ownerHasVault);
            const unlockBlockedReason = !canUnlockBridgeVault(status)
              ? status === 'Unlocked'
                ? 'Already unsealed.'
                : status === 'NotRunning'
                  ? 'Bridge is offline.'
                  : 'Encryption is not configured on this bridge.'
              : 'This client is locked — unlock it above to get a key to send.';
            return (
              <div
                key={id}
                data-debug-id="bridge-vault-row"
                data-bridge-id={id}
                data-bridge-vault-state={status}
                className="flex flex-col gap-2 rounded-lg border border-subtle bg-surface p-2.5 sm:flex-row sm:items-center sm:justify-between"
              >
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="truncate text-xs font-semibold text-primary">{name}</span>
                    <StatusPill
                      tone={BRIDGE_VAULT_STATUS_TONE[status]}
                      data-debug-id="bridge-vault-row-status-pill"
                    >
                      {BRIDGE_VAULT_STATUS_LABEL[status]}
                    </StatusPill>
                  </div>
                  <p className="mt-1 text-xs text-muted leading-relaxed break-words">
                    {configureAllowed
                      ? BRIDGE_VAULT_CONFIGURABLE_DESCRIPTION
                      : BRIDGE_VAULT_STATUS_DESCRIPTION[status]}
                  </p>
                  {rowError ? (
                    <p
                      data-debug-id="bridge-vault-row-error"
                      className="mt-1.5 text-xs text-danger break-words"
                    >
                      {rowError}
                    </p>
                  ) : null}
                  {rowNotice ? (
                    <p
                      data-debug-id="bridge-vault-row-notice"
                      className="mt-1.5 text-xs text-success break-words"
                    >
                      {rowNotice}
                    </p>
                  ) : null}
                </div>

                <div className="flex flex-wrap items-center gap-2">
                  {configureAllowed ? (
                    <Button
                      variant="primary"
                      size="sm"
                      loading={busy === 'unlock'}
                      disabled={Boolean(busy)}
                      title={
                        clientHoldsKey
                          ? 'Send this client\u2019s vault key to the bridge'
                          : 'Enter your master password to give this bridge its key'
                      }
                      data-debug-id={`bridge-row-configure-btn-${id}`}
                      className="min-h-[44px] min-w-[44px] touch-manipulation w-full sm:w-auto"
                      onClick={() => handleBridgeConfigure(id)}
                    >
                      <Icon name="lock" size="sm" className="mr-1.5" />
                      Configure encryption
                    </Button>
                  ) : (
                    <Button
                      variant="primary"
                      size="sm"
                      loading={busy === 'unlock'}
                      disabled={Boolean(busy) || !unlockAllowed}
                      title={unlockAllowed ? 'Send this client\u2019s vault key to the bridge' : unlockBlockedReason}
                      data-debug-id="bridge-vault-row-unlock-btn"
                      className="min-h-[44px] min-w-[44px] touch-manipulation w-full sm:w-auto"
                      onClick={() => void handleBridgeUnlock(id)}
                    >
                      <Icon name="lock" size="sm" className="mr-1.5" />
                      Unlock
                    </Button>
                  )}
                  {/*
                    REQ-BVS-5: per-bridge Lock calls `lockBridge(id)` ONLY. It must never
                    dispatch `lockVault()` — this client stays unlocked and every other
                    bridge is untouched.
                  */}
                  <Button
                    variant="secondary"
                    size="sm"
                    loading={busy === 'lock'}
                    disabled={Boolean(busy) || !canLockBridgeVault(status)}
                    title={
                      canLockBridgeVault(status)
                        ? 'Purge the vault key on this bridge only'
                        : 'Only an unsealed bridge can be locked.'
                    }
                    data-debug-id="bridge-vault-row-lock-btn"
                    className="min-h-[44px] min-w-[44px] touch-manipulation w-full sm:w-auto text-danger hover:border-danger/40"
                    onClick={() => void handleBridgeLock(id)}
                  >
                    <Icon name="lock" size="sm" className="mr-1.5" />
                    Lock
                  </Button>
                </div>
              </div>
            );
          })
        )}
      </div>

      {unsealSuccessMsg ? (
        <div
          data-debug-id="bridge-vault-success-msg"
          className="mt-3 rounded-lg border border-success/30 bg-success-soft p-2.5 text-xs text-success flex items-center gap-1.5"
        >
          <Icon name="check" size="sm" />
          <span>{unsealSuccessMsg}</span>
        </div>
      ) : null}

      {unlockError ? (
        <div
          data-debug-id="bridge-vault-error-msg"
          className="mt-3 rounded-lg border border-danger/30 bg-danger-soft p-2.5 text-xs text-danger flex items-center gap-1.5"
        >
          <Icon name="alert" size="sm" />
          <span>{unlockError}</span>
        </div>
      ) : null}

      {/* Unlock Bridge Modal (Master Password prompt) */}
      {unlockModalOpen ? (
        <Modal
          open={unlockModalOpen}
          onOpenChange={(open) => {
            if (!open) {
              setUnlockModalOpen(false);
              setMasterPassword('');
              setUnlockError('');
              setPendingUnsealBridgeId(null);
            }
          }}
          title="Unlock Bridge Vault"
          data-debug-id="bridge-unlock-modal"
        >
          <form onSubmit={(e) => void handlePasswordUnlockSubmit(e)}>
            <ModalBody className="space-y-4">
              <div className="flex items-center gap-2">
                <Icon name="lock" size="md" className="text-accent" />
                <h3 className="text-base font-semibold text-primary">Unlock Bridge Vault</h3>
              </div>

              <p className="text-xs text-muted leading-relaxed">
                {pendingUnsealBridgeId
                  ? 'Enter your master password to dispatch an authenticated E2EE unseal payload to this one bridge. The key this browser holds is a non-extractable handle, so it cannot be wrapped for a bridge — nothing re-usable is kept, which is why this is asked each session.'
                  : 'Enter your master password to decrypt the vault key and dispatch an authenticated E2EE unseal payload to the bridge.'}
              </p>

              <div>
                <label className="block text-xs font-medium text-primary mb-1.5">
                  Master Password
                </label>
                <Input
                  type="password"
                  value={masterPassword}
                  onChange={setMasterPassword}
                  placeholder="Enter your master password"
                  autoFocus
                  required
                  data-debug-id="bridge-unlock-password-input"
                  className="min-h-[44px] w-full"
                />
              </div>

              <label className="flex items-center gap-2 text-xs text-muted cursor-pointer min-h-[44px]">
                <input
                  type="checkbox"
                  checked={rememberSession}
                  onChange={(e) => setRememberSession(e.target.checked)}
                  className="rounded text-accent focus:ring-accent min-h-[20px] min-w-[20px]"
                />
                <span>Remember key for this browser session</span>
              </label>

              {unlockError ? (
                <div
                  data-debug-id="bridge-unlock-modal-error"
                  className="rounded-lg border border-danger/30 bg-danger-soft p-2.5 text-xs text-danger"
                >
                  {unlockError}
                </div>
              ) : null}
            </ModalBody>

            <ModalFooter>
              <Button
                variant="secondary"
                onClick={() => {
                  setUnlockModalOpen(false);
                  setMasterPassword('');
                  setUnlockError('');
                  setPendingUnsealBridgeId(null);
                }}
                disabled={unlockBusy}
                className="min-h-[44px] min-w-[44px] touch-manipulation"
              >
                Cancel
              </Button>
              <Button
                type="submit"
                variant="primary"
                loading={unlockBusy}
                disabled={!masterPassword}
                data-debug-id="bridge-unlock-modal-submit"
                className="min-h-[44px] min-w-[44px] touch-manipulation"
              >
                Unlock & Unseal
              </Button>
            </ModalFooter>
          </form>
        </Modal>
      ) : null}

      {/* Vault Onboarding Modal if user clicked Enable Encryption */}
      {onboardingOpen ? (
        <VaultOnboardingModal
          open={onboardingOpen}
          onOpenChange={setOnboardingOpen}
          onDismiss={() => setOnboardingOpen(false)}
        />
      ) : null}
    </div>
  );
}
