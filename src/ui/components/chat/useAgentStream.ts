import { PaneDeliveryQueue, normalizeSnapshotBytes, repaintCapturedScreen, splitPaneInput } from '../shells/paneDeliveryQueue.ts';
import { useCallback, useEffect, useRef, useState } from 'react';
import { useSelector } from 'react-redux';
import { apiAbsoluteUrl } from '../../api/apiBase';
import { decryptShellStreamPayload, encryptShellStreamPayload } from '../shells/useShellStream';
import { VAULT_ARMOR_PREFIX, bytesToBase64, getActiveVaultKey } from '../../utils/vaultContent';
import { isVaultLockedError } from '../../utils/vaultLockedError.ts';

const HEARTBEAT_INTERVAL_MS = 30000;
const INITIAL_RECONNECT_DELAY_MS = 1000;
const MAX_RECONNECT_DELAY_MS = 5000;
const MAX_RECONNECT_ATTEMPTS = 3;

function toBase64(str: string): string {
  try {
    return btoa(str);
  } catch {
    return bytesToBase64(new TextEncoder().encode(str));
  }
}

type AgentStreamMsg =
  | { type: 'output'; data_b64: string; is_encrypted: boolean; is_snapshot?: boolean }
  | { type: 'screen'; data_b64: string; is_encrypted: boolean; cursor_row?: number; cursor_col?: number }
  | { type: 'ready'; agent_instance_id?: string; session_id?: string }
  | { type: 'stream_ready'; session_id?: string; agent_instance_id?: string; [key: string]: any }
  | { type: 'stream_closed'; session_id?: string; agent_instance_id?: string; exit_code?: number; [key: string]: any }
  | { type: 'status'; status: string }
  // T10: `code`/`bridge_id` are set for typed errors (e.g. vault_locked).
  | { type: 'error'; message: string; code?: string; bridge_id?: string; session_id?: string };

export type UseAgentStreamOptions = {
  agentInstanceId: string | null | undefined;
  enabled?: boolean;
  rows?: number;
  cols?: number;
  onConnect?: () => void;
  onReset?: () => void;
  onOutput?: (data: Uint8Array) => void;
  onStatus?: (status: string) => void;
  onStreamReady?: (info?: { sessionId?: string; agentInstanceId?: string; [key: string]: any }) => void;
  onStreamClosed?: (info?: { sessionId?: string; agentInstanceId?: string; exitCode?: number; [key: string]: any }) => void;
  onError?: (message: string) => void;
  /**
   * T10 (REQ-T10-3): the hub reported this pane's bridge vault as locked (a typed
   * `error` frame or a `vault_locked` close reason). Receives the raw frame/close so
   * the caller can classify it with isVaultLockedError / vaultLockedBridgeId. Such a
   * signal is NOT also reported through onError.
   */
  onVaultLocked?: (signal: unknown) => void;
  onClose?: () => void;
  isVaultUnlocked?: boolean;
};

export interface UseAgentStreamResult {
  connected: boolean;
  isStreamReady: boolean;
  sendInput: (data: string) => void;
  sendResize: (rows: number, cols: number) => void;
  reconnect: () => void;
}

function hasElectronDeviceAuth(): boolean {
  return typeof window !== 'undefined' && Boolean((window as any).odinApi?.deviceAuth);
}

async function electronApiBaseUrl(): Promise<string> {
  try {
    const cfg = await (window as any).odinApi?.deviceAuth?.getConfig?.();
    return String(cfg?.apiBaseUrl || (window as any).odinApi?.hubApiBaseUrl || '').replace(/\/$/, '');
  } catch {
    return String((window as any).odinApi?.hubApiBaseUrl || '').replace(/\/$/, '');
  }
}

function httpToWsUrl(base: string, path: string): string {
  const origin = base || (typeof window !== 'undefined' ? window.location.origin : 'http://127.0.0.1:5173');
  const parsed = new URL(origin);
  parsed.protocol = parsed.protocol === 'https:' ? 'wss:' : 'ws:';
  parsed.pathname = path;
  parsed.search = '';
  parsed.hash = '';
  return parsed.toString();
}

function httpUrlToWs(httpUrl: string): string {
  const url = new URL(httpUrl);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  return url.toString();
}

/**
 * Resolves the WebSocket stream URL directly using browser cookie session authentication,
 * eliminating the mandatory HTTP pre-flight ticket request per user directive.
 * Outside Electron, resolves via apiAbsoluteUrl to preserve preview tunnel prefixes.
 */
async function agentStreamUrl(agentInstanceId: string): Promise<string> {
  const path = `/api/v1/agent-instances/${encodeURIComponent(agentInstanceId)}/stream`;
  if (hasElectronDeviceAuth()) {
    const base = await electronApiBaseUrl();
    return httpToWsUrl(base, path);
  }
  return httpUrlToWs(apiAbsoluteUrl(path));
}

export function useAgentStream({
  agentInstanceId,
  enabled = true,
  rows,
  cols,
  onConnect,
  onReset,
  onOutput,
  onStatus,
  onStreamReady,
  onStreamClosed,
  onError,
  onVaultLocked,
  onClose,
  isVaultUnlocked: propIsVaultUnlocked,
}: UseAgentStreamOptions): UseAgentStreamResult {
  const [connected, setConnected] = useState(false);
  const [isStreamReady, setIsStreamReady] = useState(false);
  const isStreamReadyRef = useRef(false);
  const pendingKeyEventsRef = useRef<Array<{ data: string; timestamp: number }>>([]);
  const streamReadyFallbackTimerRef = useRef<number | undefined>(undefined);
  const dispatchInputRef = useRef<(data: string) => void>(() => {});

  const socketRef = useRef<WebSocket | null>(null);
  const heartbeatRef = useRef<number | undefined>(undefined);
  const reconnectTimerRef = useRef<number | undefined>(undefined);
  const microNudgeTimerRef = useRef<number | undefined>(undefined);
  const reconnectAttemptsRef = useRef(0);
  const stoppedRef = useRef(false);
  const activeConnectIdRef = useRef(0);

  // Vault state subscription
  let reduxUnlocked = false;
  try {
    reduxUnlocked = useSelector((state: any) => Boolean(state?.vault?.isUnlocked || state?.vault?.unlocked));
  } catch {
    // Non-fatal when rendered outside Redux Provider (e.g. standalone test)
  }

  // Key material exists only as a non-extractable CryptoKey (REQ-VAULT-HARDEN-1):
  // state.vault.rawVaultKeyHex is never assigned and readSessionVaultKey() is hardened to
  // return null unconditionally, so getActiveVaultKey() is the single source of key material.
  const activeKey = getActiveVaultKey();
  const isVaultUnlocked = propIsVaultUnlocked !== undefined
    ? propIsVaultUnlocked
    : (reduxUnlocked || Boolean(activeKey));

  const isVaultUnlockedRef = useRef(isVaultUnlocked);
  isVaultUnlockedRef.current = isVaultUnlocked;
  const outputQueueRef = useRef<Promise<void>>(Promise.resolve());
  const paneQueueRef = useRef<PaneDeliveryQueue | null>(null);
  const inputQueueRef = useRef<Promise<void>>(Promise.resolve());

  useEffect(() => {
    isVaultUnlockedRef.current = isVaultUnlocked;
  }, [isVaultUnlocked]);


  const rowsRef = useRef(rows);
  const colsRef = useRef(cols);
  const onConnectRef = useRef(onConnect);
  const onResetRef = useRef(onReset);
  const onOutputRef = useRef(onOutput);
  const onStatusRef = useRef(onStatus);
  const onStreamReadyRef = useRef(onStreamReady);
  const onStreamClosedRef = useRef(onStreamClosed);
  const onErrorRef = useRef(onError);
  const onCloseRef = useRef(onClose);

  useEffect(() => { rowsRef.current = rows; }, [rows]);
  useEffect(() => { colsRef.current = cols; }, [cols]);
  useEffect(() => { onConnectRef.current = onConnect; }, [onConnect]);
  useEffect(() => { onResetRef.current = onReset; }, [onReset]);
  useEffect(() => { onOutputRef.current = onOutput; }, [onOutput]);
  useEffect(() => { onStatusRef.current = onStatus; }, [onStatus]);
  useEffect(() => { onStreamReadyRef.current = onStreamReady; }, [onStreamReady]);
  useEffect(() => { onStreamClosedRef.current = onStreamClosed; }, [onStreamClosed]);
  useEffect(() => { onErrorRef.current = onError; }, [onError]);
  const onVaultLockedRef = useRef(onVaultLocked);
  useEffect(() => { onVaultLockedRef.current = onVaultLocked; }, [onVaultLocked]);
  useEffect(() => { onCloseRef.current = onClose; }, [onClose]);

  const clearHeartbeat = () => {
    if (heartbeatRef.current) window.clearInterval(heartbeatRef.current);
    heartbeatRef.current = undefined;
  };

  const clearReconnectTimer = () => {
    if (reconnectTimerRef.current) window.clearTimeout(reconnectTimerRef.current);
    reconnectTimerRef.current = undefined;
  };

  const clearMicroNudgeTimer = () => {
    if (microNudgeTimerRef.current) window.clearTimeout(microNudgeTimerRef.current);
    microNudgeTimerRef.current = undefined;
  };

  const clearStreamReadyFallbackTimer = () => {
    if (streamReadyFallbackTimerRef.current) window.clearTimeout(streamReadyFallbackTimerRef.current);
    streamReadyFallbackTimerRef.current = undefined;
  };

  const startHeartbeat = (socket: WebSocket) => {
    clearHeartbeat();
    heartbeatRef.current = window.setInterval(() => {
      if (socket.readyState === WebSocket.OPEN) {
        try {
          socket.send(JSON.stringify({ type: 'heartbeat' }));
        } catch {
          try { socket.close(); } catch { /* ignore */ }
        }
      }
    }, HEARTBEAT_INTERVAL_MS);
  };

  const closeSocket = () => {
    activeConnectIdRef.current += 1;
    clearHeartbeat();
    clearReconnectTimer();
    clearMicroNudgeTimer();
    clearStreamReadyFallbackTimer();
    isStreamReadyRef.current = false;
    setIsStreamReady(false);
    pendingKeyEventsRef.current = [];
    if (socketRef.current) {
      socketRef.current.onclose = null;
      socketRef.current.onerror = null;
      socketRef.current.onmessage = null;
      socketRef.current.onopen = null;
      try { socketRef.current.close(); } catch { /* ignore */ }
      socketRef.current = null;
    }
    setConnected(false);
  };

  const sendResize = useCallback((rows: number, cols: number) => {
    const s = socketRef.current;
    if (!s || s.readyState !== WebSocket.OPEN) return;
    s.send(JSON.stringify({ type: 'resize', rows, cols }));
  }, []);

  const connect = useCallback(() => {
    if (!agentInstanceId || !enabled || stoppedRef.current) return;
    closeSocket();

    const connectId = ++activeConnectIdRef.current;
    let socket: WebSocket;

    agentStreamUrl(agentInstanceId)
      .then((url) => {
        if (activeConnectIdRef.current !== connectId || stoppedRef.current || !enabled) return;
        socket = new WebSocket(url);
        socketRef.current = socket;

        socket.onopen = () => {
          if (activeConnectIdRef.current !== connectId) {
            try { socket.close(); } catch { /* ignore */ }
            return;
          }
          reconnectAttemptsRef.current = 0;
          outputQueueRef.current = Promise.resolve();
          setConnected(true);
          startHeartbeat(socket);

          // Purge stale terminal buffer on stream open / reconnect (REQ-STREAM-REDRAW-1)
          onConnectRef.current?.();
          onResetRef.current?.();

          // SIGWINCH micro-nudge for instant full-screen native repaint (REQ-STREAM-REDRAW-2)
          // Matches tools/pty_host/src/dclient.rs:392-414: resize to cols - 1 then restore after 25ms
          const targetRows = rowsRef.current ?? 24;
          const targetCols = colsRef.current ?? 80;
          if (targetCols > 1) {
            // REQ-SHELL-29: announce the REAL geometry FIRST, before the nudge.
            // The hub captures the late-join screen snapshot from the FIRST resize frame
            // it sees (agent_instance_handlers.odin), and the nudge below deliberately
            // sends a wrong width. Without this line that wrong width is what the capture
            // wraps at, so a full-width line breaks one column early and every line after
            // it shifts — and a shell sitting at a prompt never repaints to correct it.
            // The shells hook already announces honest geometry on open
            // (useShellStream.ts:202); this makes the agent pane consistent with it.
            // ORDER IS LOAD-BEARING: keep this call above the cols - 1 nudge.
            sendResize(targetRows, targetCols);
            sendResize(targetRows, targetCols - 1);
            clearMicroNudgeTimer();
            microNudgeTimerRef.current = window.setTimeout(() => {
              if (activeConnectIdRef.current === connectId && socket.readyState === WebSocket.OPEN) {
                sendResize(targetRows, targetCols);
              }
            }, 25);
          }

          // Fallback timer: if explicit stream_ready is not received within 750ms, mark ready and drain
          clearStreamReadyFallbackTimer();
          streamReadyFallbackTimerRef.current = window.setTimeout(() => {
            if (activeConnectIdRef.current === connectId && socket.readyState === WebSocket.OPEN && !isStreamReadyRef.current) {
              isStreamReadyRef.current = true;
              setIsStreamReady(true);
              if (pendingKeyEventsRef.current.length > 0) {
                const queued = [...pendingKeyEventsRef.current];
                pendingKeyEventsRef.current = [];
                for (const item of queued) {
                  dispatchInputRef.current(item.data);
                }
              }
            }
          }, 750);
        };

        const paneQueue = new PaneDeliveryQueue(() => {
          try { socket.close(4008, 'pane delivery overloaded'); } catch { /* connection already closed */ }
        });
        paneQueueRef.current = paneQueue;
        const handleMessage = async (event: MessageEvent) => {
          if (activeConnectIdRef.current !== connectId) return;
          let msg: AgentStreamMsg;
          try {
            msg = JSON.parse(event.data);
          } catch {
            return;
          }

          if (msg.type === 'output') {
            const isArmored = msg.is_encrypted === true;
            const enc_b64 = isArmored ? msg.data_b64 : undefined;
            const data_b64 = !isArmored ? msg.data_b64 : undefined;

            // If unarmored plaintext base64 arrives, decode immediately via atob() with zero delay.
            if (!isArmored && data_b64) {
              try {
                const raw = atob(data_b64);
                const bytes = new Uint8Array(raw.length);
                for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
                onOutputRef.current?.(msg.is_snapshot ? normalizeSnapshotBytes(bytes) : bytes);
              } catch { socket.close(4007, 'invalid pane base64'); }
              return;
            }

            if (enc_b64) {
              await (outputQueueRef.current = outputQueueRef.current.then(async () => {
                if (activeConnectIdRef.current !== connectId) return;
                const keyToUse = getActiveVaultKey();
                const isUnlocked = isVaultUnlockedRef.current || Boolean(keyToUse);
                if (isUnlocked && keyToUse) {
                  try {
                    const bytes = await decryptShellStreamPayload(enc_b64, keyToUse);
                    if (activeConnectIdRef.current !== connectId || socket.readyState !== WebSocket.OPEN) return;
                    onOutputRef.current?.(msg.is_snapshot ? normalizeSnapshotBytes(bytes) : bytes);
                  } catch { socket.close(4007, 'pane decryption failed'); }
                }
              }).catch(() => { /* ignore queue errors */ }));
            }
          } else if (msg.type === 'screen') {
            const isArmored = msg.is_encrypted === true;
            const enc_b64 = isArmored ? msg.data_b64 : undefined;
            const b64 = !isArmored ? msg.data_b64 : undefined;

            // If unarmored plaintext base64 arrives, decode immediately via atob() with zero delay.
            if (!isArmored && b64) {
              try {
                const raw = atob(b64);
                const bytes = new Uint8Array(raw.length);
                for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
                onOutputRef.current?.(bytes);
              } catch { socket.close(4007, 'invalid pane base64'); }
              return;
            }

            if (enc_b64) {
              await (outputQueueRef.current = outputQueueRef.current.then(async () => {
                if (activeConnectIdRef.current !== connectId) return;
                const keyToUse = getActiveVaultKey();
                const isUnlocked = isVaultUnlockedRef.current || Boolean(keyToUse);
                if (isUnlocked && keyToUse) {
                  try {
                    const bytes = await decryptShellStreamPayload(enc_b64, keyToUse);
                    if (activeConnectIdRef.current !== connectId || socket.readyState !== WebSocket.OPEN) return;
                    onOutputRef.current?.(repaintCapturedScreen(bytes, msg.cursor_row, msg.cursor_col));
                  } catch { socket.close(4007, 'pane decryption failed'); }
                }
              }).catch(() => { /* ignore queue errors */ }));
            }
          } else if (msg.type === 'stream_ready') {
            clearStreamReadyFallbackTimer();
            isStreamReadyRef.current = true;
            setIsStreamReady(true);
            onStreamReadyRef.current?.(msg);
            if (pendingKeyEventsRef.current.length > 0) {
              const queued = [...pendingKeyEventsRef.current];
              pendingKeyEventsRef.current = [];
              for (const item of queued) {
                dispatchInputRef.current(item.data);
              }
            }
          } else if (msg.type === 'stream_closed') {
            clearStreamReadyFallbackTimer();
            isStreamReadyRef.current = false;
            setIsStreamReady(false);
            pendingKeyEventsRef.current = [];
            onStreamClosedRef.current?.(msg);
          } else if (msg.type === 'status') {
            onStatusRef.current?.(msg.status);
          } else if (msg.type === 'error') {
            if (isVaultLockedError(msg)) {
              onVaultLockedRef.current?.(msg);
            } else {
              onErrorRef.current?.(msg.message);
            }
          }
        };

        socket.onmessage = (event) => {
          if (activeConnectIdRef.current !== connectId) return;
          let type: string;
          try {
            const frame = JSON.parse(event.data);
            type = frame.type;
            if ((type === 'output' || type === 'screen') && (typeof frame.data_b64 !== 'string' || typeof frame.is_encrypted !== 'boolean')) {
              socket.close(4007, 'invalid pane payload');
              return;
            }
          } catch { return; }
          if (type === 'output' || type === 'screen' || type === 'status' || type === 'stream_closed') {
            // JSON/Base64 pane frames are ASCII; count UTF-16 storage conservatively.
            paneQueue.enqueue(event.data.length * 2, () => handleMessage(event));
          } else {
            void handleMessage(event);
          }
        };

        socket.onclose = (event: CloseEvent) => {
          paneQueue.cancel();
          if (activeConnectIdRef.current !== connectId) return;
          if (isVaultLockedError({ reason: event?.reason })) {
            // T10: a locked vault is not a transport failure — no reconnect storm and
            // no fallback to polling; the pane shows its locked overlay instead.
            clearHeartbeat();
            clearMicroNudgeTimer();
            clearStreamReadyFallbackTimer();
            isStreamReadyRef.current = false;
            setIsStreamReady(false);
            pendingKeyEventsRef.current = [];
            setConnected(false);
            onVaultLockedRef.current?.(event);
            return;
          }
          clearHeartbeat();
          clearMicroNudgeTimer();
          clearStreamReadyFallbackTimer();
          isStreamReadyRef.current = false;
          setIsStreamReady(false);
          pendingKeyEventsRef.current = [];
          setConnected(false);

          // Auto-reconnect with exponential backoff if not explicitly stopped
          if (!stoppedRef.current && enabled && reconnectAttemptsRef.current < MAX_RECONNECT_ATTEMPTS) {
            const delay = Math.min(
              INITIAL_RECONNECT_DELAY_MS * Math.pow(2, reconnectAttemptsRef.current),
              MAX_RECONNECT_DELAY_MS
            );
            reconnectAttemptsRef.current += 1;
            reconnectTimerRef.current = window.setTimeout(() => {
              if (!stoppedRef.current && enabled) {
                connect();
              }
            }, delay);
          } else {
            onCloseRef.current?.();
          }
        };

        socket.onerror = () => {
          if (activeConnectIdRef.current !== connectId) return;
          if (reconnectAttemptsRef.current >= MAX_RECONNECT_ATTEMPTS) {
            onErrorRef.current?.('Agent instance stream connection error');
          }
        };
      })
      .catch((err) => {
        if (activeConnectIdRef.current !== connectId) return;
        onErrorRef.current?.(String(err?.message || err || 'Failed to connect to agent instance stream'));
      });
  }, [agentInstanceId, enabled, sendResize]);

  useEffect(() => {
    stoppedRef.current = false;
    reconnectAttemptsRef.current = 0;
    if (enabled && agentInstanceId) {
      connect();
    } else {
      closeSocket();
    }

    return () => {
      stoppedRef.current = true;
      closeSocket();
    };
  }, [agentInstanceId, enabled, connect]);

  const dispatchInput: (data: string) => void = useCallback((data: string) => {
    if (data.length > 8192) {
      for (const part of splitPaneInput(data)) dispatchInput(part);
      return;
    }
    const s = socketRef.current;
    if (!s || s.readyState !== WebSocket.OPEN) return;

    const keyToUse = getActiveVaultKey();
    const isUnlocked = isVaultUnlockedRef.current || Boolean(keyToUse);

    if (isUnlocked && keyToUse) {
      inputQueueRef.current = inputQueueRef.current.then(async () => {
        if (s.readyState !== WebSocket.OPEN) return;
        try {
          const enc_b64 = await encryptShellStreamPayload(data, keyToUse);
          if (s.readyState === WebSocket.OPEN) {
            s.send(JSON.stringify({ type: 'input', data_b64: enc_b64, is_encrypted: true }));
          }
        } catch {
          onErrorRef.current?.('Terminal input encryption failed');
        }
      }).catch(() => { /* ignore queue error */ });
    } else {
      s.send(JSON.stringify({ type: 'input', data_b64: toBase64(data), is_encrypted: false }));
    }
  }, []);

  useEffect(() => {
    dispatchInputRef.current = dispatchInput;
  }, [dispatchInput]);

  const sendInput = useCallback((data: string) => {
    if (!isStreamReadyRef.current) {
      pendingKeyEventsRef.current.push({ data, timestamp: Date.now() });
      return;
    }
    dispatchInput(data);
  }, [dispatchInput]);

  const reconnect = useCallback(() => {
    reconnectAttemptsRef.current = 0;
    connect();
  }, [connect]);

  return { connected, isStreamReady, sendInput, sendResize, reconnect };
}
