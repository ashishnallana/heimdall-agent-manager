import { PaneDeliveryQueue, repaintCapturedScreen, splitPaneInput } from './paneDeliveryQueue.ts';
import { useCallback, useEffect, useRef, useState } from 'react';
import { useSelector } from 'react-redux';
import { apiAbsoluteUrl } from '../../api/apiBase.ts';
import { shellResizeFrame } from './shellStreamFrames.ts';
import { getActiveVaultKey } from '../../store/vaultSlice.ts';
import { importRawKeyHex, AES_GCM_NONCE_BYTES, AES_GCM_TAG_BYTES } from '../../utils/vaultCrypto.ts';
import { bytesToBase64, base64ToBytes, VAULT_ARMOR_PREFIX, MIN_ARMOR_PAYLOAD_BYTES } from '../../utils/vaultContent.ts';
import { isVaultLockedError } from '../../utils/vaultLockedError.ts';

const HEARTBEAT_INTERVAL_MS = 30000;
const INITIAL_RECONNECT_DELAY_MS = 1000;
const MAX_RECONNECT_DELAY_MS = 5000;
const MAX_RECONNECT_ATTEMPTS = 3;

type ShellStreamMsg =
  | { type: 'output'; data_b64: string; is_encrypted: boolean }
  | { type: 'screen'; data_b64: string; is_encrypted: boolean; cursor_row?: number; cursor_col?: number }
  | { type: 'ready'; session_id?: string }
  | { type: 'stream_ready'; session_id?: string; [key: string]: any }
  | { type: 'stream_closed'; session_id?: string; exit_code?: number; [key: string]: any }
  | { type: 'status'; status: string }
  // T10: `code`/`bridge_id` are set for typed errors (e.g. vault_locked).
  | { type: 'error'; message: string; code?: string; bridge_id?: string; session_id?: string };

export type UseShellStreamOptions = {
  sessionId: string | null;
  enabled?: boolean;
  onOutput?: (data: Uint8Array) => void;
  onStatus?: (status: string) => void;
  onStreamReady?: (info?: { sessionId?: string; [key: string]: any }) => void;
  onStreamClosed?: (info?: { sessionId?: string; exitCode?: number; [key: string]: any }) => void;
  onError?: (message: string) => void;
  /**
   * T10 (REQ-T10-3): the hub reported this pane's bridge vault as locked (a typed
   * `error` frame or a `vault_locked` close reason). Receives the raw frame/close so
   * the caller can classify it with isVaultLockedError / vaultLockedBridgeId. Such a
   * signal is NOT also reported through onError.
   */
  onVaultLocked?: (signal: unknown) => void;
  onClose?: () => void;
  /**
   * REQ-SHELL-18 — the pane's CURRENT geometry, read at the moment the socket opens.
   *
   * `sendResize` below can only send on an OPEN socket; before that it drops the frame and
   * returns. The consumer computes its geometry when it mounts and fits, which is BEFORE the
   * socket is open (`connect()` awaits `shellStreamUrl()`, then constructs the WebSocket, then
   * waits for the handshake), so that first frame is exactly the one that gets dropped — and
   * nothing used to re-send it. The PTY then stayed at its 80x24 default for the whole session,
   * and only a later window resize, which happens to arrive on an open socket, corrected it.
   *
   * A pull, not a push: the geometry is read INSIDE `onopen`, so it cannot be stale, and it is
   * read again on every reconnect — after a backoff reconnect the new PTY needs telling too.
   * If container is unmeasured (e.g. clientWidth === 0), getGeometry returns null to suppress
   * sending premature unmeasured 80x24 dimensions.
   */
  getGeometry?: () => { rows: number; cols: number } | null;
  /** Explicit vault unlock state override (defaults to Redux vault). */
  isVaultUnlocked?: boolean;
};

export interface UseShellStreamResult {
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
async function shellStreamUrl(sessionId: string): Promise<string> {
  const path = `/api/v1/shells/${encodeURIComponent(sessionId)}/stream`;
  if (hasElectronDeviceAuth()) {
    const base = await electronApiBaseUrl();
    return httpToWsUrl(base, path);
  }
  return httpUrlToWs(apiAbsoluteUrl(path));
}

let cachedRawKeyHex: string | null = null;
let cachedCryptoKey: CryptoKey | null = null;

async function getCryptoKey(rawKeyHex: string): Promise<CryptoKey> {
  if (cachedCryptoKey && cachedRawKeyHex === rawKeyHex) {
    return cachedCryptoKey;
  }
  const key = await importRawKeyHex(rawKeyHex);
  cachedRawKeyHex = rawKeyHex;
  cachedCryptoKey = key;
  return key;
}

function toBase64(str: string): string {
  try {
    return btoa(str);
  } catch {
    return bytesToBase64(new TextEncoder().encode(str));
  }
}

/**
 * Decrypts an incoming AES-GCM encrypted shell stream chunk (enc_b64).
 * Expects wire format: base64(12B nonce + 16B auth_tag + ciphertext),
 * with optional 'vault:v1:' prefix.
 */
export async function decryptShellStreamPayload(
  enc_b64: string,
  keyOrHex: CryptoKey | string,
): Promise<Uint8Array> {
  const cryptoKey = typeof keyOrHex === 'string' ? await getCryptoKey(keyOrHex) : keyOrHex;
  let clean = enc_b64.trim();
  if (clean.startsWith(VAULT_ARMOR_PREFIX)) {
    clean = clean.slice(VAULT_ARMOR_PREFIX.length);
  }
  const payload = base64ToBytes(clean);
  if (payload.length < MIN_ARMOR_PAYLOAD_BYTES) {
    throw new Error(`Encrypted stream frame shorter than header (${payload.length} < ${MIN_ARMOR_PAYLOAD_BYTES})`);
  }

  const nonce = payload.subarray(0, AES_GCM_NONCE_BYTES);
  const tag = payload.subarray(AES_GCM_NONCE_BYTES, MIN_ARMOR_PAYLOAD_BYTES);
  const ciphertext = payload.subarray(MIN_ARMOR_PAYLOAD_BYTES);

  // WebCrypto AES-GCM expects ciphertext || auth_tag
  const combined = new Uint8Array(ciphertext.length + tag.length);
  combined.set(ciphertext, 0);
  combined.set(tag, ciphertext.length);

  const decrypted = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: nonce as unknown as BufferSource, tagLength: 128 },
    cryptoKey,
    combined as unknown as BufferSource,
  );

  return new Uint8Array(decrypted);
}

/**
 * Encrypts outgoing keystrokes using WebCrypto AES-GCM with a random 12B IV.
 * Returns base64(12B IV + 16B auth_tag + ciphertext).
 */
export async function encryptShellStreamPayload(
  data: string | Uint8Array,
  keyOrHex: CryptoKey | string,
): Promise<string> {
  const cryptoKey = typeof keyOrHex === 'string' ? await getCryptoKey(keyOrHex) : keyOrHex;
  const inputBytes = typeof data === 'string' ? new TextEncoder().encode(data) : data;
  const iv = crypto.getRandomValues(new Uint8Array(AES_GCM_NONCE_BYTES));

  const encrypted = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: iv as unknown as BufferSource, tagLength: 128 },
    cryptoKey,
    inputBytes as unknown as BufferSource,
  );

  const encryptedBytes = new Uint8Array(encrypted);
  const ciphertextLen = encryptedBytes.length - AES_GCM_TAG_BYTES;
  const ciphertext = encryptedBytes.subarray(0, ciphertextLen);
  const tag = encryptedBytes.subarray(ciphertextLen);

  const payload = new Uint8Array(MIN_ARMOR_PAYLOAD_BYTES + ciphertextLen);
  payload.set(iv, 0);
  payload.set(tag, AES_GCM_NONCE_BYTES);
  payload.set(ciphertext, MIN_ARMOR_PAYLOAD_BYTES);

  return bytesToBase64(payload);
}

export function useShellStream({
  sessionId,
  enabled = true,
  onOutput,
  onStatus,
  onStreamReady,
  onStreamClosed,
  onError,
  onVaultLocked,
  onClose,
  getGeometry,
  isVaultUnlocked: propIsVaultUnlocked,
}: UseShellStreamOptions): UseShellStreamResult {
  const [connected, setConnected] = useState(false);
  const [isStreamReady, setIsStreamReady] = useState(false);
  const isStreamReadyRef = useRef(false);
  const pendingKeyEventsRef = useRef<Array<{ data: string; timestamp: number }>>([]);
  const streamReadyFallbackTimerRef = useRef<number | undefined>(undefined);
  const dispatchInputRef = useRef<(data: string) => void>(() => {});

  const socketRef = useRef<WebSocket | null>(null);
  const heartbeatRef = useRef<number | undefined>(undefined);
  const reconnectTimerRef = useRef<number | undefined>(undefined);
  const reconnectAttemptsRef = useRef(0);
  const stoppedRef = useRef(false);
  const activeConnectIdRef = useRef(0);

  const onOutputRef = useRef(onOutput);
  const onStatusRef = useRef(onStatus);
  const onStreamReadyRef = useRef(onStreamReady);
  const onStreamClosedRef = useRef(onStreamClosed);
  const onErrorRef = useRef(onError);
  const onCloseRef = useRef(onClose);
  const getGeometryRef = useRef(getGeometry);

  useEffect(() => { onOutputRef.current = onOutput; }, [onOutput]);
  useEffect(() => { onStatusRef.current = onStatus; }, [onStatus]);
  useEffect(() => { onStreamReadyRef.current = onStreamReady; }, [onStreamReady]);
  useEffect(() => { onStreamClosedRef.current = onStreamClosed; }, [onStreamClosed]);
  useEffect(() => { onErrorRef.current = onError; }, [onError]);
  const onVaultLockedRef = useRef(onVaultLocked);
  useEffect(() => { onVaultLockedRef.current = onVaultLocked; }, [onVaultLocked]);
  useEffect(() => { onCloseRef.current = onClose; }, [onClose]);
  useEffect(() => { getGeometryRef.current = getGeometry; }, [getGeometry]);

  // Vault state subscription. Key material itself is never held here: it lives
  // only as a non-extractable CryptoKey reached via getActiveVaultKey()
  // (REQ-VAULT-HARDEN-1 / REQ-RAWKEY-A5).
  let reduxUnlocked = false;
  try {
    reduxUnlocked = useSelector((state: any) => Boolean(state?.vault?.isUnlocked || state?.vault?.unlocked));
  } catch {
    // Non-fatal when rendered outside Redux Provider (e.g. standalone test)
  }

  const isVaultUnlocked = propIsVaultUnlocked !== undefined
    ? propIsVaultUnlocked
    : reduxUnlocked;

  const isVaultUnlockedRef = useRef(isVaultUnlocked);
  isVaultUnlockedRef.current = isVaultUnlocked;
  const vaultLockedNoticeShownRef = useRef(false);
  const outputQueueRef = useRef<Promise<void>>(Promise.resolve());
  const paneQueueRef = useRef<PaneDeliveryQueue | null>(null);
  const inputQueueRef = useRef<Promise<void>>(Promise.resolve());

  useEffect(() => {
    isVaultUnlockedRef.current = isVaultUnlocked;
    if (isVaultUnlocked) {
      vaultLockedNoticeShownRef.current = false;
    }
  }, [isVaultUnlocked]);

  const clearHeartbeat = () => {
    if (heartbeatRef.current) window.clearInterval(heartbeatRef.current);
    heartbeatRef.current = undefined;
  };

  const clearReconnectTimer = () => {
    if (reconnectTimerRef.current) window.clearTimeout(reconnectTimerRef.current);
    reconnectTimerRef.current = undefined;
  };

  const clearStreamReadyFallbackTimer = () => {
    if (streamReadyFallbackTimerRef.current) window.clearTimeout(streamReadyFallbackTimerRef.current);
    streamReadyFallbackTimerRef.current = undefined;
  };

  // REQ-SHELL-6 §6 — JUSTIFIED EXCEPTION 1 of 2 to the no-polling rule, and the one
  // that requirement explicitly told us to check for rather than pattern-match on
  // `setInterval`. This is a WEBSOCKET KEEPALIVE, not a poller: it sends a heartbeat
  // frame on an ALREADY-OPEN socket and closes it if the send fails. It fetches
  // nothing, invalidates no cache tag, and produces no UI update — deleting it would
  // not remove a poll, it would let idle sockets be reaped by the first intermediary
  // with a read timeout. KEEP.
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

  /**
   * REQ-SHELL-18 — tell the PTY its size the instant the socket is usable.
   *
   * Sent directly on `socket`, not through `sendResize`, and from inside `onopen` rather than
   * from an effect reacting to `connected`: `socketRef.current` and the `connected` state are
   * both a React round-trip behind this moment, and a backoff reconnect can leave `connected`
   * true throughout, so an effect keyed on it would not fire at all for the reconnect case.
   */
  const sendGeometry = (socket: WebSocket) => {
    const frame = shellResizeFrame(getGeometryRef.current?.());
    if (!frame) return;
    if (socket.readyState !== WebSocket.OPEN) return;
    try {
      socket.send(frame);
    } catch { /* a socket that fails here will surface through onclose */ }
  };

  const closeSocket = () => {
    console.log('[useShellStream] closeSocket() called for session:', sessionId);
    activeConnectIdRef.current += 1;
    clearHeartbeat();
    clearReconnectTimer();
    clearStreamReadyFallbackTimer();
    outputQueueRef.current = Promise.resolve();
    inputQueueRef.current = Promise.resolve();
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

  const connect = useCallback(() => {
    console.log('[useShellStream] connect() called:', { sessionId, enabled, stopped: stoppedRef.current });
    if (!sessionId || !enabled || stoppedRef.current) return;
    closeSocket();

    const connectId = ++activeConnectIdRef.current;
    let socket: WebSocket;

    shellStreamUrl(sessionId)
      .then((url) => {
        if (activeConnectIdRef.current !== connectId || stoppedRef.current || !enabled) {
          console.log('[useShellStream] aborting connect: state changed before socket creation');
          return;
        }
        console.log('[useShellStream] creating WebSocket connection to:', url);
        socket = new WebSocket(url);
        socketRef.current = socket;

        socket.onopen = () => {
          if (activeConnectIdRef.current !== connectId) {
            console.log('[useShellStream] onopen received for stale connectId, closing socket');
            try { socket.close(); } catch { /* ignore */ }
            return;
          }
          console.log('[useShellStream] socket.onopen connected successfully for session:', sessionId);
          reconnectAttemptsRef.current = 0;
          vaultLockedNoticeShownRef.current = false;
          outputQueueRef.current = Promise.resolve();
          inputQueueRef.current = Promise.resolve();
          setConnected(true);
          startHeartbeat(socket);
          sendGeometry(socket);

          // Fallback timer: if explicit stream_ready is not received within 750ms, mark ready and drain
          clearStreamReadyFallbackTimer();
          streamReadyFallbackTimerRef.current = window.setTimeout(() => {
            if (activeConnectIdRef.current === connectId && socket.readyState === WebSocket.OPEN && !isStreamReadyRef.current) {
              console.log('[useShellStream] fallback timer: marking stream_ready after timeout');
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
          let msg: ShellStreamMsg;
          try {
            msg = JSON.parse(event.data);
          } catch {
            console.warn('[useShellStream] failed to parse incoming JSON frame');
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
                onOutputRef.current?.(bytes);
              } catch (err) {
                console.error('[useShellStream] base64 decode failed for plaintext output frame:', err);
                socket.close(4007, 'invalid pane base64');
              }
              return;
            }

            await (outputQueueRef.current = outputQueueRef.current.then(async () => {
              if (activeConnectIdRef.current !== connectId) return;
              if (enc_b64) {
                const activeKey = getActiveVaultKey();
                const isUnlocked = isVaultUnlockedRef.current || Boolean(activeKey);
                if (isUnlocked && activeKey) {
                  try {
                    const bytes = await decryptShellStreamPayload(enc_b64, activeKey);
                    if (activeConnectIdRef.current !== connectId || socket.readyState !== WebSocket.OPEN) return;
                    onOutputRef.current?.(bytes);
                  } catch (err) {
                    console.error('[useShellStream] decryption failed for output frame:', err);
                    socket.close(4007, 'pane decryption failed');
                  }
                } else {
                  console.warn('[useShellStream] vault is locked; cannot decrypt encrypted output frame');
                  if (!vaultLockedNoticeShownRef.current) {
                    vaultLockedNoticeShownRef.current = true;
                    const notice = new TextEncoder().encode(
                      '\r\n\x1b[33m[Vault locked: terminal stream is encrypted. Unlock vault to view session.]\x1b[0m\r\n'
                    );
                    onOutputRef.current?.(notice);
                  }
                }
              }
            }).catch(() => { /* ignore queue errors */ }));
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
              } catch (err) {
                console.error('[useShellStream] base64 decode failed for plaintext screen frame:', err);
                socket.close(4007, 'invalid pane base64');
              }
              return;
            }

            await (outputQueueRef.current = outputQueueRef.current.then(async () => {
              if (activeConnectIdRef.current !== connectId) return;
              if (enc_b64) {
                const activeKey = getActiveVaultKey();
                const isUnlocked = isVaultUnlockedRef.current || Boolean(activeKey);
                if (isUnlocked && activeKey) {
                  try {
                    const bytes = await decryptShellStreamPayload(enc_b64, activeKey);
                    if (activeConnectIdRef.current !== connectId || socket.readyState !== WebSocket.OPEN) return;
                    onOutputRef.current?.(repaintCapturedScreen(bytes, msg.cursor_row, msg.cursor_col));
                  } catch (err) {
                    console.error('[useShellStream] decryption failed for screen frame:', err);
                    socket.close(4007, 'pane decryption failed');
                  }
                } else {
                  console.warn('[useShellStream] vault is locked; cannot decrypt encrypted screen frame');
                  if (!vaultLockedNoticeShownRef.current) {
                    vaultLockedNoticeShownRef.current = true;
                    const notice = new TextEncoder().encode(
                      '\r\n\x1b[33m[Vault locked: terminal stream is encrypted. Unlock vault to view session.]\x1b[0m\r\n'
                    );
                    onOutputRef.current?.(notice);
                  }
                }
              }
            }).catch(() => { /* ignore queue errors */ }));
          } else if (msg.type === 'stream_ready') {
            console.log('[useShellStream] received stream_ready frame:', msg);
            clearStreamReadyFallbackTimer();
            isStreamReadyRef.current = true;
            setIsStreamReady(true);
            onStreamReadyRef.current?.(msg);
            if (pendingKeyEventsRef.current.length > 0) {
              const queued = [...pendingKeyEventsRef.current];
              pendingKeyEventsRef.current = [];
              console.log(`[useShellStream] Flushing ${queued.length} buffered key events post stream_ready`);
              for (const item of queued) {
                dispatchInputRef.current(item.data);
              }
            }
          } else if (msg.type === 'stream_closed') {
            console.log('[useShellStream] received stream_closed frame:', msg);
            clearStreamReadyFallbackTimer();
            isStreamReadyRef.current = false;
            setIsStreamReady(false);
            pendingKeyEventsRef.current = [];
            onStreamClosedRef.current?.(msg);
          } else if (msg.type === 'status') {
            console.log('[useShellStream] received status frame:', msg.status);
            onStatusRef.current?.(msg.status);
          } else if (msg.type === 'error') {
            if (isVaultLockedError(msg)) {
              console.warn('[useShellStream] bridge vault is locked for session:', (msg as any).session_id);
              onVaultLockedRef.current?.(msg);
            } else {
              console.error('[useShellStream] received error frame from server:', msg.message);
              onErrorRef.current?.(msg.message);
            }
          } else if ((msg as any).type === 'ready') {
            console.log('[useShellStream] received ready frame for session:', (msg as any).session_id);
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
          if (activeConnectIdRef.current !== connectId) {
            console.log('[useShellStream] socket.onclose ignored for stale connectId');
            return;
          }
          console.warn('[useShellStream] socket.onclose triggered:', {
            code: event.code,
            reason: event.reason,
            wasClean: event.wasClean,
            reconnectAttempts: reconnectAttemptsRef.current,
            stopped: stoppedRef.current,
            enabled,
          });
          clearHeartbeat();
          clearStreamReadyFallbackTimer();
          isStreamReadyRef.current = false;
          setIsStreamReady(false);
          pendingKeyEventsRef.current = [];
          setConnected(false);

          // T10: a locked vault is not a transport failure — no reconnect storm; the
          // pane shows its locked overlay and re-attaches after the unseal.
          if (isVaultLockedError({ reason: event.reason })) {
            onVaultLockedRef.current?.(event);
            return;
          }

          // Auto-reconnect with exponential backoff if not explicitly stopped
          if (!stoppedRef.current && enabled && reconnectAttemptsRef.current < MAX_RECONNECT_ATTEMPTS) {
            const delay = Math.min(
              INITIAL_RECONNECT_DELAY_MS * Math.pow(2, reconnectAttemptsRef.current),
              MAX_RECONNECT_DELAY_MS
            );
            console.log(`[useShellStream] scheduling auto-reconnect attempt #${reconnectAttemptsRef.current + 1} in ${delay}ms`);
            reconnectAttemptsRef.current += 1;
            reconnectTimerRef.current = window.setTimeout(() => {
              if (!stoppedRef.current && enabled) {
                connect();
              }
            }, delay);
          } else {
            console.warn('[useShellStream] reconnect exhausted or disabled, calling onClose');
            onCloseRef.current?.();
          }
        };

        socket.onerror = (event) => {
          if (activeConnectIdRef.current !== connectId) return;
          console.error('[useShellStream] socket.onerror triggered:', event);
          if (reconnectAttemptsRef.current >= MAX_RECONNECT_ATTEMPTS) {
            onErrorRef.current?.('Shell stream connection error');
          }
        };
      })
      .catch((err) => {
        if (activeConnectIdRef.current !== connectId) return;
        console.error('[useShellStream] shellStreamUrl resolution error:', err);
        onErrorRef.current?.(String(err?.message || err || 'Failed to connect to shell stream'));
      });
  }, [sessionId, enabled]);

  useEffect(() => {
    stoppedRef.current = false;
    reconnectAttemptsRef.current = 0;
    if (enabled && sessionId) {
      console.log('[useShellStream] useEffect mount/change triggering connect() for session:', sessionId);
      connect();
    } else {
      console.log('[useShellStream] useEffect inactive (enabled=' + enabled + ', sessionId=' + sessionId + '), closing socket');
      closeSocket();
    }

    return () => {
      console.log('[useShellStream] useEffect unmount/cleanup for session:', sessionId);
      stoppedRef.current = true;
      closeSocket();
    };
  }, [sessionId, enabled, connect]);

  const dispatchInput: (data: string) => void = useCallback((data: string) => {
    if (data.length > 8192) {
      for (const part of splitPaneInput(data)) dispatchInput(part);
      return;
    }
    const s = socketRef.current;
    if (!s || s.readyState !== WebSocket.OPEN) {
      console.warn('[useShellStream] sendInput called but socket is not open, readyState:', s?.readyState);
      return;
    }

    const activeKey = getActiveVaultKey();
    const isUnlocked = isVaultUnlockedRef.current || Boolean(activeKey);

    console.log('[useShellStream] sendInput sending keystroke(s):', {
      chars: data.length,
      isUnlocked,
      hasKey: Boolean(activeKey),
    });

    if (isUnlocked && activeKey) {
      inputQueueRef.current = inputQueueRef.current.then(async () => {
        if (s.readyState !== WebSocket.OPEN) return;
        try {
          const enc_b64 = await encryptShellStreamPayload(data, activeKey);
          if (s.readyState === WebSocket.OPEN) {
            s.send(JSON.stringify({ type: 'input', data_b64: enc_b64, is_encrypted: true }));
            console.log('[useShellStream] sendInput sent encrypted input frame');
          }
        } catch (err) {
          console.warn('[useShellStream] input encryption failed:', err);
          onErrorRef.current?.('Terminal input encryption failed');
        }
      }).catch(() => { /* ignore queue error */ });
    } else {
      s.send(JSON.stringify({ type: 'input', data_b64: toBase64(data), is_encrypted: false }));
      console.log('[useShellStream] sendInput sent plaintext input frame');
    }
  }, []);

  useEffect(() => {
    dispatchInputRef.current = dispatchInput;
  }, [dispatchInput]);

  const sendInput = useCallback((data: string) => {
    if (!isStreamReadyRef.current) {
      console.log('[useShellStream] Buffering early input before stream_ready:', { length: data.length });
      pendingKeyEventsRef.current.push({ data, timestamp: Date.now() });
      return;
    }
    dispatchInput(data);
  }, [dispatchInput]);

  const sendResize = useCallback((rows: number, cols: number) => {
    const s = socketRef.current;
    console.log('[useShellStream] sendResize called:', { rows, cols, readyState: s?.readyState });
    if (!s || s.readyState !== WebSocket.OPEN) return;
    s.send(JSON.stringify({ type: 'resize', rows, cols }));
  }, []);

  const reconnect = useCallback(() => {
    console.log('[useShellStream] reconnect() manually invoked for session:', sessionId);
    reconnectAttemptsRef.current = 0;
    vaultLockedNoticeShownRef.current = false;
    connect();
  }, [connect]);

  return { connected, isStreamReady, sendInput, sendResize, reconnect };
}
