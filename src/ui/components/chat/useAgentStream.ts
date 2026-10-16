import { PTY_COLOR_RESET, PaneDeliveryQueue, PaneWriteBatcher, normalizeSnapshotText, repaintCapturedScreenText } from '../shells/paneDeliveryQueue.ts';
import { PTY_WIRE_FLAG_ENCRYPTED, PTY_WIRE_KIND_INPUT, PTY_WIRE_KIND_OUTPUT, PTY_WIRE_KIND_SCREEN, PTY_WIRE_VIEWER_HEADER_BYTES, PtyTextDecoder, decodePtyViewerFrame, decryptPtyPayload, encodePtyViewerFrame, encryptPtyPayload, type PtyViewerFrame } from '../shells/ptyWire.ts';
import { createInputCoalescer, type InputCoalescer } from '../shells/ptyInputCoalescer.ts';
import { createVisibilityGate } from '../shells/paneVisibilityGate.ts';
import { useCallback, useEffect, useRef, useState } from 'react';
import { useSelector } from 'react-redux';
import { apiAbsoluteUrl } from '../../api/apiBase';
import { getActiveVaultKey } from '../../utils/vaultContent';
import { isVaultLockedError } from '../../utils/vaultLockedError.ts';

const HEARTBEAT_INTERVAL_MS = 30000;
const INITIAL_RECONNECT_DELAY_MS = 1000;
const MAX_RECONNECT_DELAY_MS = 5000;
const MAX_RECONNECT_ATTEMPTS = 3;

// Control frames only (REQ-PTY-NET-2): pty output/screen bytes are binary frames, see ptyWire.ts.
type AgentStreamMsg =
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
  /** Decoded terminal text (see useShellStream.onOutput). */
  onOutput?: (data: string) => void;
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
  const hiddenPausedRef = useRef(false);
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
    inputCoalescerRef.current?.reset();
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
    if (!agentInstanceId || !enabled || stoppedRef.current || hiddenPausedRef.current) return;
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
        // REQ-PTY-NET-2: identical receive path to useShellStream — the agent pane shares the
        // hub pipeline. Binary frames are pty bytes; JSON text frames are control only.
        socket.binaryType = 'arraybuffer';
        const textDecoder = new PtyTextDecoder();
        let previousWasSnapshot = false;
        // REQ-PTY-NET-7: one term.write per animation frame; a repaint always leads its own write.
        const writeBatcher = new PaneWriteBatcher((text) => onOutputRef.current?.(text));

        const handleBinaryFrame = async (frame: PtyViewerFrame) => {
          if (activeConnectIdRef.current !== connectId) return;
          if (frame.kind !== PTY_WIRE_KIND_OUTPUT && frame.kind !== PTY_WIRE_KIND_SCREEN) return;
          let bytes = frame.payload;
          if (frame.encrypted) {
            const keyToUse = getActiveVaultKey();
            const isUnlocked = isVaultUnlockedRef.current || Boolean(keyToUse);
            if (!isUnlocked || !keyToUse) return;
            try {
              bytes = await decryptPtyPayload(frame.payload, keyToUse);
            } catch { socket.close(4007, 'pane decryption failed'); return; }
            if (activeConnectIdRef.current !== connectId || socket.readyState !== WebSocket.OPEN) return;
          }
          const isScreen = frame.kind === PTY_WIRE_KIND_SCREEN;
          const startsRepaint = frame.snapshot && !previousWasSnapshot;
          previousWasSnapshot = frame.snapshot;
          if (startsRepaint) textDecoder.reset();
          let text = textDecoder.decode(bytes);
          if (isScreen && frame.encrypted) {
            text = repaintCapturedScreenText(text, frame.cursorRow, frame.cursorCol);
          } else if (!isScreen && frame.snapshot && startsRepaint) {
            text = normalizeSnapshotText(text);
          }
          // REQ-PTY-COLOR-1: a repaint starts from the theme defaults; the capture's own
          // preamble (if any) re-applies the bridge machine's colours right after.
          if (startsRepaint) text = PTY_COLOR_RESET + text;
          if (text.length > 0) writeBatcher.push(text, startsRepaint);
        };

        const handleControlMessage = (msg: AgentStreamMsg) => {
          if (activeConnectIdRef.current !== connectId) return;
          if (msg.type === 'stream_ready') {
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
          if (event.data instanceof ArrayBuffer) {
            const frame = decodePtyViewerFrame(event.data);
            if (!frame) { socket.close(4007, 'invalid pane frame'); return; }
            paneQueue.enqueue(frame.payload.length * 2 + PTY_WIRE_VIEWER_HEADER_BYTES, () => handleBinaryFrame(frame));
            return;
          }
          let msg: AgentStreamMsg;
          try { msg = JSON.parse(event.data); } catch { return; }
          if (msg.type === 'status' || msg.type === 'stream_closed') {
            paneQueue.enqueue(0, async () => { writeBatcher.flush(); handleControlMessage(msg); });
          } else {
            handleControlMessage(msg);
          }
        };

        socket.onclose = (event: CloseEvent) => {
          paneQueue.cancel();
          writeBatcher.reset();
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

  // REQ-PTY-NET-5: a pane hidden for > PANE_HIDDEN_PAUSE_MS closes its socket (which
  // detaches the bridge stream when it was the last viewer) and reconnects the instant the
  // document is visible again; the fresh attach repaints the whole screen. A connect()
  // while hidden-paused is refused so a reconnect timer cannot resurrect the socket.
  useEffect(() => {
    if (!enabled || !agentInstanceId || typeof document === 'undefined') return;
    const gate = createVisibilityGate({
      isHidden: () => document.hidden === true,
      onPause: () => {
        hiddenPausedRef.current = true;
        closeSocket();
      },
      onResume: () => {
        hiddenPausedRef.current = false;
        reconnectAttemptsRef.current = 0;
        if (!stoppedRef.current) connect();
      },
    });
    const onVisibility = () => gate.notify();
    document.addEventListener('visibilitychange', onVisibility);
    gate.notify();
    return () => {
      document.removeEventListener('visibilitychange', onVisibility);
      gate.dispose();
      hiddenPausedRef.current = false;
    };
  }, [agentInstanceId, enabled, connect]);

  // REQ-PTY-NET-3: binary, coalesced, ack-less input — identical to useShellStream.
  const sendInputChunk = useCallback((data: string) => {
    const s = socketRef.current;
    if (!s || s.readyState !== WebSocket.OPEN) return;
    const keyToUse = getActiveVaultKey();
    const isUnlocked = isVaultUnlockedRef.current || Boolean(keyToUse);
    const bytes = new TextEncoder().encode(data);
    if (isUnlocked && keyToUse) {
      inputQueueRef.current = inputQueueRef.current.then(async () => {
        if (s.readyState !== WebSocket.OPEN) return;
        try {
          const sealed = await encryptPtyPayload(bytes, keyToUse);
          if (s.readyState === WebSocket.OPEN) {
            s.send(encodePtyViewerFrame(PTY_WIRE_KIND_INPUT, PTY_WIRE_FLAG_ENCRYPTED, sealed));
          }
        } catch {
          onErrorRef.current?.('Terminal input encryption failed');
        }
      }).catch(() => { /* ignore queue error */ });
    } else {
      s.send(encodePtyViewerFrame(PTY_WIRE_KIND_INPUT, 0, bytes));
    }
  }, []);

  const inputCoalescerRef = useRef<InputCoalescer | null>(null);
  if (inputCoalescerRef.current === null) {
    inputCoalescerRef.current = createInputCoalescer((chunk) => sendInputChunk(chunk));
  }

  const dispatchInput: (data: string) => void = useCallback((data: string) => {
    inputCoalescerRef.current?.push(data);
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
