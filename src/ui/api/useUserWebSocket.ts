import { apiAbsoluteUrl } from './apiBase';
import { refreshMcpWorkerRegistration, setMcpWorkerEnabled } from '../services/mcpWorker';
import { authenticatedStreamUrl } from './userStreamUrl';
import { useEffect } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { handleUserWsEvent, resyncAfterReconnect } from './wsInvalidation';
import { heimdallApi } from './heimdallApi';
import {
  UserWsAuthError,
  MAX_CONSECUTIVE_FAILURES,
  STABLE_CONNECTION_MS,
  USER_WS_RESYNC_EVENT,
  UserWsStreamTracker,
  classifyClose,
  createResyncScheduler,
  probeUserAuth,
  reconnectDelayMs,
  staleQueriesBefore,
  type AuthProbeResult,
  type UserWsResyncReason,
} from './userWsRecovery';
import {
  userWsConnecting,
  userWsConnected,
  userWsDisconnected,
  userWsError,
} from '../store/chatSlice';

// UI-14: the shell owns exactly ONE user WebSocket connection. It receives
// lightweight invalidation/summary events and routes them through the single
// `handleUserWsEvent` invalidation path (wsInvalidation.ts), which patches or
// invalidates the smallest relevant RTK Query cache entries. There is no second
// connection and no durable full-data stream.
//
// Auth model: browsers open `/api/v1/user-ws` with the Hub session cookie (the
// Hub checks Origin == ui_origin on cookie WebSocket upgrades and re-validates the
// session while the socket lives). Other streams mint a short-lived single-use
// ticket with a same-origin `POST /api/v1/me/ws-ticket` (cookie) and connect with
// `?ticket=...`. The packaged Electron app loads the Hub HTTPS origin and takes
// this same cookie path (Chromium carries the HttpOnly OIDC session cookie); its
// preload exposes no bearer-token bridge. See ElectronDeviceAuthGate.

// Hub keeps user WebSockets open by waiting for occasional client frames. Send a
// lightweight heartbeat well below the server idle timeout so healthy browser
// sockets do not reconnect/resync every minute.
const HEARTBEAT_INTERVAL_MS = 25000;
// The 'initial' resync waits at most this long for GETs that were still in flight when
// the socket became ready, then refetches each one once it settles.
const INITIAL_PENDING_WAIT_MS = 10000;
const INITIAL_PENDING_POLL_MS = 250;

// Focus context read at WS-event time. Only focusedChainId is consumed (targets
// an extra chain-view refresh for the chain the user is viewing); the shell
// populates it from the live route. Foreground notification suppression derives
// the open conversation from the route hash directly (see notificationService).
export type UserWsContext = {
  focusedChainId?: string;
};

// UserWsConnectionEnv is what the connection loop needs from the outside world. The
// defaults are the real ones; tests replace the socket, URL, auth probe and handlers.
export type UserWsConnectionEnv = {
  dispatch: any;
  getCtx?: () => UserWsContext;
  tracker?: UserWsStreamTracker;
  createSocket?: (url: string) => WebSocket;
  resolveUrl?: () => Promise<string>;
  probeAuth?: () => Promise<AuthProbeResult>;
  isElectron?: () => boolean;
  handleEvent?: (dispatch: any, payload: any, ctx: UserWsContext) => void;
  fullResync?: (dispatch: any) => void;
};

// startUserWsConnection runs the shell's single user WebSocket until the returned stop
// function is called. Lifecycle:
//   connect -> user_ws_ready (subscribed: resync 'initial' first time, 'reconnect' after)
//   -> events (gap / resync_required -> coalesced resync) -> close
//   close 4401/4403, or a pre-ready close whose /api/v1/me probe says 401/403, or a
//   resolveUrl rejecting with UserWsAuthError: PARK (no more retries)
//   any other close: retry after a capped, jittered delay; after
//   MAX_CONSECUTIVE_FAILURES connects without a stable ready (one that lasted
//   STABLE_CONNECTION_MS): PARK
//   parked: resume on 'online', window focus or the tab becoming visible.
export function startUserWsConnection(env: UserWsConnectionEnv): () => void {
  const dispatch = env.dispatch;
  const getCtx = env.getCtx ?? (() => ({}));
  const tracker = env.tracker ?? new UserWsStreamTracker();
  const createSocket = env.createSocket ?? ((url: string) => new WebSocket(url));
  const resolveUrl = env.resolveUrl ?? (() => authenticatedStreamUrl('/api/v1/user-ws'));
  const probeAuth = env.probeAuth ?? (() => probeUserAuth(apiAbsoluteUrl('/api/v1/me')));
  const isElectron = env.isElectron ?? (() => false);
  const handleEvent = env.handleEvent ?? handleUserWsEvent;
  const fullResync = env.fullResync ?? resyncAfterReconnect;
  let stopped = false;
  let socket: WebSocket | null = null;
  let reconnectTimer: number | undefined;
  let heartbeatTimer: number | undefined;
  let pendingWaitTimer: number | undefined;
  // Consecutive connects that never reached a STABLE ready: a connect that failed, or
  // one that closed within STABLE_CONNECTION_MS of user_ws_ready. Reset only once a
  // connection has stayed ready that long (stableTimer).
  let failures = 0;
  let stableTimer: number | undefined;
  // Set when retrying stopped on its own (auth, or too many failures); cleared by
  // the online/visibility/focus listeners below.
  let parked = false;

  const runResync = (reason: UserWsResyncReason, readyAt: number) => {
    // Ready already starts the live handshake synchronously, before any frames.
    if (reason === 'initial') {
      resyncQueriesStartedBefore(readyAt);
    } else {
      fullResync(dispatch);
    }
    try {
      window.dispatchEvent(new CustomEvent(USER_WS_RESYNC_EVENT, { detail: { reason } }));
    } catch { /* ignore */ }
    if (reason === 'reconnect') window.dispatchEvent(new CustomEvent('heimdall:user-ws-reconnected'));
  };
  let lastReadyAt = 0;
  const scheduler = createResyncScheduler((reason) => runResync(reason, lastReadyAt));

  // First open: only a query whose request STARTED before the socket was subscribed can
  // have missed an event, so refetch just those (fulfilled now, in-flight once they
  // settle) rather than invalidating every tag.
  const resyncQueriesStartedBefore = (readyAt: number) => {
    dispatch((innerDispatch: any, getState: any) => {
      const queries = () => getState()?.[heimdallApi.reducerPath]?.queries || {};
      const refetched = new Set<string>();
      const deadline = Date.now() + INITIAL_PENDING_WAIT_MS;
      const sweep = () => {
        pendingWaitTimer = undefined;
        if (stopped) return;
        let waiting = false;
        for (const [key, entry] of Object.entries<any>(queries())) {
          if (refetched.has(key)) continue;
          if (staleQueriesBefore({ [key]: entry }, readyAt).length === 0) continue;
          if (entry.status === 'pending') { waiting = true; continue; }
          refetched.add(key);
          const endpoint = (heimdallApi.endpoints as any)[entry.endpointName];
          if (!endpoint?.initiate) continue;
          try {
            innerDispatch(endpoint.initiate(entry.originalArgs, { subscribe: false, forceRefetch: true }));
          } catch { /* a refetch must never break the socket */ }
        }
        if (waiting && Date.now() < deadline) pendingWaitTimer = window.setTimeout(sweep, INITIAL_PENDING_POLL_MS);
      };
      sweep();
    });
  };

  const clearStableTimer = () => {
    if (stableTimer) window.clearTimeout(stableTimer);
    stableTimer = undefined;
  };

  const clearHeartbeat = () => {
    if (heartbeatTimer) window.clearInterval(heartbeatTimer);
    heartbeatTimer = undefined;
  };

  const startHeartbeat = () => {
    clearHeartbeat();
    heartbeatTimer = window.setInterval(() => {
      if (!socket || socket.readyState !== 1 /* OPEN */) return;
      try {
        socket.send(JSON.stringify({ type: 'client_heartbeat', at: Date.now() }));
        void refreshMcpWorkerRegistration();
      } catch (_err) {
        try { socket.close(); } catch { /* ignore */ }
      }
    }, HEARTBEAT_INTERVAL_MS);
  };

  const park = (message: string) => {
    parked = true;
    dispatch(userWsError(message));
  };

  const scheduleReconnect = () => {
    if (stopped || parked) return;
    if (failures >= MAX_CONSECUTIVE_FAILURES) {
      park('User WebSocket unavailable; will retry when the app is focused or back online');
      return;
    }
    const delay = reconnectDelayMs(failures);
    failures += 1;
    reconnectTimer = window.setTimeout(() => { reconnectTimer = undefined; void connect(); }, delay);
  };

  // A browser cannot see why an upgrade was refused (it is reported as 1006), so a
  // socket that closed without ever becoming ready asks /api/v1/me. 401/403 stops
  // retrying (and the shell's fetch observer shows the signed-out / denied screen);
  // anything else is an outage and is retried with backoff.
  const onCloseBeforeReady = async () => {
    if (isElectron()) { scheduleReconnect(); return; }
    const verdict = await probeAuth();
    if (stopped) return;
    if (verdict === 'unauthenticated' || verdict === 'forbidden') {
      park(verdict === 'unauthenticated' ? 'Signed out' : 'Access denied');
      return;
    }
    scheduleReconnect();
  };

  const connect = async () => {
    if (stopped || parked) return;
    dispatch(userWsConnecting());
    let ready = false;
    try {
      const url = await resolveUrl();
      if (!url || stopped) return;
      socket = createSocket(url);
    } catch (err: any) {
      if (err instanceof UserWsAuthError) {
        park(err.message || 'WebSocket authentication failed');
        return;
      }
      dispatch(userWsError(String(err?.message || err || 'WebSocket construction failed')));
      scheduleReconnect();
      return;
    }

    socket.onopen = () => {
      startHeartbeat();
    };

    socket.onmessage = (event) => {
      let payload: any;
      try {
        payload = JSON.parse(event.data);
      } catch {
        return;
      }
      if (payload?.type === 'user_ws_ready') {
        void refreshMcpWorkerRegistration();
        // Ready, not open, is "subscribed": the hub registers the socket and then sends
        // ready, so every event after it is delivered.
        ready = true;
        lastReadyAt = Date.now();
        if (stableTimer) window.clearTimeout(stableTimer);
        stableTimer = window.setTimeout(() => { stableTimer = undefined; failures = 0; }, STABLE_CONNECTION_MS);
        dispatch(userWsConnected());
        scheduler.trigger(tracker.onReady(payload));
        return;
      }
      const verdict = tracker.onEvent(payload);
      if (verdict.resync) scheduler.trigger(verdict.resync);
      if (verdict.deliver) handleEvent(dispatch, payload, getCtx());
    };

    socket.onerror = () => {
      dispatch(userWsError('User WebSocket connection error'));
    };

    socket.onclose = (event) => {
      void setMcpWorkerEnabled(false).catch(() => {});
      clearHeartbeat();
      clearStableTimer();
      socket = null;
      if (stopped) return;
      const kind = classifyClose(event?.code);
      if (kind === 'auth' || kind === 'forbidden') {
        park(kind === 'auth' ? 'Signed out' : 'Access denied');
        if (kind === 'auth') window.dispatchEvent(new CustomEvent('heimdall:api-unauthenticated'));
        return;
      }
      dispatch(userWsDisconnected());
      if (!ready && kind === 'unknown') { void onCloseBeforeReady(); return; }
      scheduleReconnect();
    };
  };

  // Resume a parked socket when there is reason to think it may work now.
  const resume = () => {
    if (stopped || !parked) return;
    if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return;
    parked = false;
    failures = 0;
    void connect();
  };
  window.addEventListener('online', resume);
  window.addEventListener('focus', resume);
  document.addEventListener('visibilitychange', resume);

  void connect();

  return () => {
    stopped = true;
    scheduler.cancel();
    window.removeEventListener('online', resume);
    window.removeEventListener('focus', resume);
    document.removeEventListener('visibilitychange', resume);
    if (reconnectTimer) window.clearTimeout(reconnectTimer);
    if (pendingWaitTimer) window.clearTimeout(pendingWaitTimer);
    clearStableTimer();
    clearHeartbeat();
    if (socket) {
      void setMcpWorkerEnabled(false).catch(() => {});
      socket.onclose = null;
      socket.onerror = null;
      socket.onmessage = null;
      socket.onopen = null;
      try { socket.close(); } catch { /* ignore */ }
    }
  };
}

// React hook form: pass a ref-like object whose `.current` is the live ctx.
export function useUserWebSocket(ctxRef?: { current: UserWsContext }): { status: string; connected: boolean } {
  const dispatch = useDispatch<any>();
  // Connect once for the shell's lifetime. ctxRef is read at event time, so it
  // does not need to be a dependency. The stream tracker is created per connection
  // loop (startUserWsConnection's default), not held in a ref: a ref survives React
  // StrictMode's dev unmount/remount, which made the remounted loop's first ready look
  // like a 'reconnect' (full invalidation) instead of 'initial'.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => startUserWsConnection({ dispatch, getCtx: () => ctxRef?.current || {} }), [dispatch]);

  const status = useSelector((state: any) => state?.chat?.session?.wsStatus || 'idle');
  const connected = useSelector((state: any) => Boolean(state?.chat?.session?.wsConnected));
  return { status, connected };
}
