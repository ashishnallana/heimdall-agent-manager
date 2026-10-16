import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react';
import { useListBridgesQuery, type Bridge } from '../../api/endpoints/bridgeSupport';
import { resolveBridgeVaultStatus, type BridgeVaultStatus } from '../../utils/bridgeVaultStatus';
import {
  PANE_VAULT_LOCKED_EVENT,
  PANE_VAULT_LOCK_INITIAL,
  type PaneVaultLockedDetail,
  isPaneVaultLocked,
  isVaultLockedError,
  reducePaneVaultLock,
  shouldResumeAfterUnseal,
  vaultLockedBridgeId,
} from '../../utils/vaultLockedError';

export interface UsePaneVaultLockOptions {
  /** The pane's bridge, when the pane knows it up front. A signal's bridge_id wins. */
  bridgeId?: string | null;
  /**
   * The pane's session (shell session id, or agent instance id). Signals announced for
   * it on PANE_VAULT_LOCKED_EVENT — REST 423s, a refused restart or start — land here.
   */
  sessionId?: string | null;
  /** Called once when the overlay clears after an unseal: retry / re-attach the stream. */
  onResume?: () => void;
}

export interface UsePaneVaultLockResult {
  /** Show the overlay and refuse input. */
  locked: boolean;
  /** The bridge the overlay's Unlock button targets ('' when not yet known). */
  bridgeId: string;
  /**
   * Feed any error / frame / event / close here. Returns true when it was a
   * vault_locked signal, so the caller does NOT treat it as a generic failure.
   */
  report: (signal: unknown) => boolean;
  /** The operator completed an unseal from the overlay. */
  markUnsealed: () => void;
}

function bridgeIdOf(bridge: Bridge | undefined | null): string {
  return String(bridge?.bridge_id || (bridge as any)?.bridgeId || (bridge as any)?.id || '');
}

/**
 * T10 (REQ-T10-3): the one place a pane decides it is "vault locked". Shared by the
 * agent pane and shell panes; the state table lives in utils/vaultLockedError.ts.
 */
export function usePaneVaultLock({ bridgeId: propBridgeId, sessionId, onResume }: UsePaneVaultLockOptions): UsePaneVaultLockResult {
  const [state, dispatch] = useReducer(reducePaneVaultLock, PANE_VAULT_LOCK_INITIAL);
  const [signalBridgeId, setSignalBridgeId] = useState<string | undefined>(undefined);
  const bridgeId = signalBridgeId || propBridgeId || '';

  // The same cached list Settings -> User Vault reads; the hub invalidates it when a
  // bridge reports a vault change, which is what clears the overlay after an unseal.
  const { data } = useListBridgesQuery(undefined, { skip: !bridgeId });
  const bridgeStatus: BridgeVaultStatus | undefined = useMemo(() => {
    if (!bridgeId) return undefined;
    const row = (data?.bridges || []).find((b: Bridge) => bridgeIdOf(b) === bridgeId);
    if (!row) return undefined;
    return resolveBridgeVaultStatus({ bridgeStatus: row?.status || row?.runtime_status, vaultStatus: row?.vault_status });
  }, [data, bridgeId]);

  const bridgeStatusRef = useRef(bridgeStatus);
  useEffect(() => {
    bridgeStatusRef.current = bridgeStatus;
    dispatch({ type: 'status', bridgeStatus });
  }, [bridgeStatus]);

  const locked = isPaneVaultLocked(state, bridgeStatus);

  const onResumeRef = useRef(onResume);
  useEffect(() => { onResumeRef.current = onResume; }, [onResume]);
  const wasLockedRef = useRef(locked);
  useEffect(() => {
    const wasLocked = wasLockedRef.current;
    wasLockedRef.current = locked;
    if (shouldResumeAfterUnseal(wasLocked, locked)) {
      dispatch({ type: 'reset' });
      onResumeRef.current?.();
    }
  }, [locked]);

  // A different pane target starts clean.
  useEffect(() => {
    dispatch({ type: 'reset' });
    setSignalBridgeId(undefined);
  }, [propBridgeId]);

  const report = useCallback((signal: unknown): boolean => {
    if (!isVaultLockedError(signal)) return false;
    const named = vaultLockedBridgeId(signal);
    if (named) setSignalBridgeId(named);
    dispatch({ type: 'signal', bridgeStatus: bridgeStatusRef.current });
    return true;
  }, []);

  const markUnsealed = useCallback(() => dispatch({ type: 'unsealed' }), []);

  useEffect(() => {
    if (!sessionId || typeof window === 'undefined') return undefined;
    const onAnnounced = (event: Event) => {
      const detail = (event as CustomEvent<PaneVaultLockedDetail>).detail;
      if (detail?.session_id === sessionId) report(detail);
    };
    window.addEventListener(PANE_VAULT_LOCKED_EVENT, onAnnounced);
    return () => window.removeEventListener(PANE_VAULT_LOCKED_EVENT, onAnnounced);
  }, [sessionId, report]);

  return { locked, bridgeId, report, markUnsealed };
}
