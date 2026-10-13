import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import type { Terminal as TerminalType } from '@xterm/xterm';
import type { FitAddon as FitAddonType } from '@xterm/addon-fit';
import type { SerializeAddon as SerializeAddonType } from '@xterm/addon-serialize';
import * as xtermModule from '@xterm/xterm';
import * as fitAddonModule from '@xterm/addon-fit';
import * as serializeAddonModule from '@xterm/addon-serialize';
import { terminalSessionRegistry } from './terminalSessionRegistry';
import {
  dispatchShellInput,
  dispatchShellResize,
  pollingSubscriptionSessionId,
  resolveStreamRenderMode,
  resolveStreamingMode,
} from './streamingMode';
import {
  beginTerminalWrite,
  dispatchTerminalData,
} from './terminalWriteAccounting';
import { activateVisibleTerminal } from './terminalPaneActivation';
import { deliverTerminalOutput } from './terminalOutputDelivery';

const xtermObj = xtermModule as Record<string, any>;
const Terminal = (xtermObj.Terminal || xtermObj['default']?.Terminal || xtermObj['default']) as typeof TerminalType;
const fitAddonObj = fitAddonModule as Record<string, any>;
const FitAddon = (fitAddonObj.FitAddon || fitAddonObj['default']?.FitAddon || fitAddonObj['default']) as typeof FitAddonType;
const serializeAddonObj = serializeAddonModule as Record<string, any>;
const SerializeAddon = (serializeAddonObj.SerializeAddon || serializeAddonObj['default']?.SerializeAddon || serializeAddonObj['default']) as typeof SerializeAddonType;

import Icon from '../Icon';
import { useTheme } from '../../store/themeSlice';
import { useShellPaneSubscription } from '../../hooks/useShellPaneSubscription';
import { useFetchExperimentsQuery } from '../../api/endpoints/settings';
import { useShellStream } from './useShellStream';
import { usePaneVaultLock } from './usePaneVaultLock';
import VaultLockedOverlay from './VaultLockedOverlay';
import {
  useRestartShellMutation,
  useSendShellInputMutation,
  useSendShellResizeMutation,
} from '../../api/endpoints/shells';
import type { ShellSession } from '../../api/endpoints/shells';

interface ShellTerminalPaneProps {
  session: ShellSession;
  isActive: boolean;
  layoutRevision?: number;
  isBridgeUnreachable?: boolean;
  onClose?: () => void;
}

/**
 * CALLERS MUST KEY THIS BY SESSION ID: `<ShellTerminalPane key={s.session_id} session={s} />`
 * (REQ-SHELL-18)
 *
 * The xterm `Terminal` is built in a mount effect with an EMPTY dependency array, so swapping the
 * `session` prop switches the STREAM while leaving the previous session's scrollback on screen —
 * the bleed the user reported when switching tabs in the bottom dock. A `key` makes a session
 * change a remount, which is what this component needs rather than a targeted reset: it owns five
 * mutable refs (terminalRef, fitAddonRef, sessionIdRef, lastWrittenOutputRef, userScrolledUpRef)
 * that must all agree with the new session, and a remount cannot forget one of them.
 *
 * A remount also resets every session-owned ref and runs the initial fit. BottomDock deliberately
 * keeps one keyed instance per session instead; its explicit `isActive` prop triggers a fit when a
 * pane mounted under `display: none` becomes visible, even if ResizeObserver misses that change.
 *
 * tests/ui_shell_streaming_test.ts asserts every call site passes the key, because a fourth call
 * site that forgets it reintroduces the bleed silently.
 */

export function ShellTerminalPane({
  session,
  isActive,
  layoutRevision = 0,
  isBridgeUnreachable: propIsBridgeUnreachable,
}: ShellTerminalPaneProps) {
  const { theme } = useTheme();
  const terminalContainerRef = useRef<HTMLDivElement | null>(null);
  const terminalRef = useRef<TerminalType | null>(null);
  const fitAddonRef = useRef<FitAddonType | null>(null);
  const serializeAddonRef = useRef<SerializeAddonType | null>(null);
  const isExplicitlyClosedRef = useRef(false);
  const isSizedRef = useRef(false);
  const pendingWritesRef = useRef(0);
  const [isSized, setIsSized] = useState(false);

  const isTerminal = session.kind === 'shell';
  const isRunning = session.status === 'running' || session.status === 'starting';
  const paneSessionId = isTerminal && isRunning ? session.session_id : null;

  // --------------------------------------------------------------------------
  // Experimental Flag & Dual-Mode Configuration (REQ-STREAM-IMPL-3)
  // --------------------------------------------------------------------------
  const { data: expData } = useFetchExperimentsQuery();
  const isStreamingExperimentEnabled = Boolean(
    expData?.flags?.find((f) => f.key === 'streaming_terminal_pane')?.enabled
  );

  const [fallbackToPolling, setFallbackToPolling] = useState(false);

  // REQ-FIX-2 — how bytes are decoded, and whether the socket should be up. Resolved before the
  // hook because it is what opens the socket; the transport half needs `streamConnected` and so
  // is resolved just below it.
  const { isStreamingActive, isStreamEnabled } = resolveStreamRenderMode({
    isStreamingExperimentEnabled,
    fallbackToPolling,
  });

  // --------------------------------------------------------------------------
  // T10 (REQ-T10-3): VAULT LOCK — same shared overlay and state as the agent pane.
  // Signals: a vault_locked stream frame / close (below), a REST input or restart
  // answered 423, or the refused-start exit event (both announced for this session).
  // --------------------------------------------------------------------------
  const resumeAfterUnsealRef = useRef<() => void>(() => {});
  const vaultLock = usePaneVaultLock({
    bridgeId: session.bridge_id,
    sessionId: session.session_id,
    onResume: () => resumeAfterUnsealRef.current(),
  });
  const vaultLockedRef = useRef(vaultLock.locked);
  useEffect(() => { vaultLockedRef.current = vaultLock.locked; }, [vaultLock.locked]);

  // --------------------------------------------------------------------------
  // STREAMING PATH: Low-latency WebSocket streaming without term.reset()
  // --------------------------------------------------------------------------
  const {
    connected: streamConnected,
    sendInput: sendStreamInput,
    sendResize: sendStreamResize,
    reconnect: reconnectStream,
  } = useShellStream({
    sessionId: paneSessionId,
    enabled: isStreamEnabled,
    // REQ-SHELL-18 & REQ-SHELL-DOCK-NO-VSCROLL-23 — read back by the hook from inside the socket's `onopen`,
    // and again on every reconnect. The mount-time fit below computes the right geometry and pushes it,
    // but the socket is not open yet at that point, so that frame is dropped; this is what makes the PTY
    // learn the pane's real size on create instead of sitting at its default until the user happens to
    // resize the window. Column floor applied here too, for the same reason handleResize applies it.
    getGeometry: () => {
      const term = terminalRef.current;
      const container = terminalContainerRef.current;
      const fitAddon = fitAddonRef.current;
      if (!term) return null;
      if (container && container.clientWidth > 0 && container.clientHeight > 0 && fitAddon && !isSizedRef.current) {
        try {
          fitAddon.fit();
          term.resize(Math.max(term.cols, 40), term.rows);
          isSizedRef.current = true;
          setIsSized(true);
          // This path flips isSizedRef too, so it owes the same flush the other three sizing
          // paths perform. While the flush lived inside the mount effect it was unreachable from
          // here and the withheld output sat stranded until some later resize happened to fire.
          flushPendingOutput();
        } catch { /* ignore */ }
      }
      if (!isSizedRef.current && (!container || container.clientWidth === 0 || container.clientHeight === 0)) {
        return null;
      }
      return { rows: Math.max(term.rows, 1), cols: Math.max(term.cols, 40) };
    },
    onOutput: (bytes) => {
      const term = terminalRef.current;
      const sessionId = sessionIdRef.current;
      // xterm is part of the PTY protocol, not just a renderer. It must parse terminal queries
      // even while its dock is 0px tall so onData can return DSR/device/color responses. Only a
      // genuinely unmounted terminal buffers; layout readiness controls fit/resize separately.
      deliverTerminalOutput(term, sessionId, bytes, {
        write: writeStreamBytes,
        buffer: (targetId, chunk) => terminalSessionRegistry.bufferSessionDelta(targetId, chunk),
      });
    },
    onVaultLocked: (signal) => {
      // A locked vault is not a stream failure: no fallback to polling.
      vaultLock.report(signal);
    },
    onError: () => {
      console.error('[ShellTerminalPane] stream onError -> triggering setFallbackToPolling(true)');
      // Graceful fallback: If WebSocket encounters error, fall back to polling
      if (isStreamingExperimentEnabled) {
        setFallbackToPolling(true);
      }
    },
    onClose: () => {
      console.warn('[ShellTerminalPane] stream onClose -> triggering setFallbackToPolling(true)');
      // Graceful fallback: If WebSocket disconnects, fall back to polling
      if (isStreamingExperimentEnabled) {
        setFallbackToPolling(true);
      }
    },
  });

  // REQ-FIX-2 — which transport actually carries input, resize and repaints right now.
  const streamingMode = resolveStreamingMode(
    { isStreamingActive, isStreamEnabled },
    streamConnected
  );
  const { isPolledRepaintOwner } = streamingMode;

  /**
   * The single write path for raw stream bytes.
   *
   * convertEol is forced off at the WRITE SITE rather than trusted from the React flag: the
   * polled repaint below needs it ON, and the effect that syncs it lags a render behind the
   * socket, so a frame arriving in the same tick as `connected` could otherwise be LF-translated.
   * PTY bytes must never be translated, whatever the render happens to be doing.
   */
  const writeStreamBytes = useCallback((term: TerminalType, bytes: Uint8Array) => {
    if (term.options.convertEol) {
      term.options.convertEol = false;
    }
    // Live output is not replay, even when it enters the alternate buffer. Full-screen
    // applications issue terminal queries in the same chunk and xterm emits their replies
    // synchronously from `write`; suppressing those replies makes Neovim time out with E1568.
    const finishWrite = beginTerminalWrite(pendingWritesRef);
    term.write(bytes, () => {
      finishWrite();
      const buffer = term.buffer.active;
      if (!userScrolledUpRef.current && buffer.type !== 'alternate' && buffer.baseY > 0) {
        term.scrollToBottom();
      }
    });
  }, []);

  /**
   * Writes the registry's buffered deltas into the live terminal once the container has a size.
   *
   * Hoisted out of the mount effect deliberately: `getGeometry` also flips `isSizedRef`, and a
   * flush scoped inside the effect is unreachable from there (REQ-FIX-7 carve-out).
   *
   * A truncated buffer yields nothing — `drainSessionDeltas` refuses to replay bytes that may
   * start mid-code-point or mid-CSI, so the screen stays clean and the next server `screen` frame
   * brings it current.
   */
  const flushPendingOutput = useCallback(() => {
    const term = terminalRef.current;
    const sessionId = sessionIdRef.current;
    if (!term || !sessionId) return;
    const chunks = terminalSessionRegistry.drainSessionDeltas(sessionId);
    for (const chunk of chunks) {
      writeStreamBytes(term, chunk);
    }
  }, [writeStreamBytes]);

  // --------------------------------------------------------------------------
  // LEGACY POLLING PATH: 500ms polled capture with SHA-256 diff & term.reset()
  // Cleanly isolated so that removing legacy polling in the future only requires
  // deleting this block and the legacy branches in handleInput / handleResize.
  // --------------------------------------------------------------------------
  const {
    output,
    isLoading,
    isBridgeUnreachable: subIsBridgeUnreachable,
    refetch,
  } = useShellPaneSubscription({
    // Live for the whole reconnect window, so a stream drop degrades to a real polled repaint
    // instead of a pane that silently stops updating (REQ-FIX-2).
    sessionId: pollingSubscriptionSessionId(paneSessionId, streamingMode),
    status: session.status,
  });

  const isBridgeUnreachable = Boolean(propIsBridgeUnreachable || subIsBridgeUnreachable);

  const [sendShellInput] = useSendShellInputMutation();
  const [sendShellResize] = useSendShellResizeMutation();

  const sessionIdRef = useRef<string | null>(paneSessionId);
  useEffect(() => {
    sessionIdRef.current = paneSessionId;
  }, [paneSessionId]);

  const refetchRef = useRef(refetch);
  useEffect(() => {
    refetchRef.current = refetch;
  }, [refetch]);

  const keystrokeDebounceTimerRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const lastWrittenOutputRef = useRef<string>('');
  const userScrolledUpRef = useRef(false);

  // Unified retry handler that triggers both streaming reconnect and polling refetch
  const handleRetry = useCallback(() => {
    console.log('[ShellTerminalPane] handleRetry clicked');
    setFallbackToPolling(false);
    reconnectStream();
    refetch();
  }, [reconnectStream, refetch]);

  // T10: after an unseal, a live session re-attaches; an interactive shell whose START
  // was refused (failed, never ran) is started again — the "retry the stream start".
  // A `run`/`server` is not re-executed on the operator's behalf.
  const [restartShell] = useRestartShellMutation();
  resumeAfterUnsealRef.current = () => {
    if (!isRunning && isTerminal && session.status === 'failed') {
      void restartShell({ sessionId: session.session_id });
      return;
    }
    handleRetry();
  };

  // Unified input handler cleanly routing between streaming and legacy polling.
  //
  // The CHOICE of transport is `dispatchShellInput`'s, not this handler's (REQ-FIX-8): a branch
  // written here is unreachable by every test in the repo, since the pane cannot be rendered
  // without a DOM harness, and that unreachability is how F2 shipped. This handler now only
  // supplies the two sinks.
  const handleInput = useCallback(
    (data: string) => {
      dispatchShellInput(streamingMode, data, {
        // STREAMING: Send keystrokes directly over WebSocket without debounce
        sendOverStream: sendStreamInput,
        // LEGACY POLLING: HTTP POST with 50ms debounced capture refetch
        sendOverHttp: (payload) => {
          const targetId = sessionIdRef.current;
          if (targetId) {
            sendShellInput({ sessionId: targetId, data: payload }).catch(() => {});
          }
          if (keystrokeDebounceTimerRef.current) {
            clearTimeout(keystrokeDebounceTimerRef.current);
          }
          keystrokeDebounceTimerRef.current = setTimeout(() => {
            refetchRef.current?.();
          }, 50);
        },
      });
    },
    [streamingMode, sendStreamInput, sendShellInput]
  );

  // Unified resize handler routing between streaming and legacy polling
  //
  // REQ-SHELL-DOCK-NO-VSCROLL-23: The 40-col floor is a DELIBERATE MINIMUM, kept on purpose, not a
  // workaround for a mis-measured fit. It pairs with `overflow-x-auto` on the xterm container
  // below: on a narrow pane (< 40 cols), keep 40 usable columns and let the user scroll sideways, rather
  // than hand a TUI 20 columns and have it reflow into unreadability. No 24-row floor is enforced so terminal
  // rows fit the parent container directly via FitAddon, eliminating vertical scrolling across all view sizes.
  //
  // It is also provably innocent of "the new terminal does not fill the pane width":
  // `Math.max(n, 40)` is monotonic and binds ONLY below 40, so if the fit proposes 200 columns it
  // stays 200. No value of the floor can make a WIDE pane render narrow, which means the floor
  // cannot have been masking the geometry bug and changing it would not have fixed anything. That
  // bug was the dropped resize frame (see getGeometry below), and it is fixed there.
  //
  // The floors are applied HERE and the transport choice is `dispatchShellResize`'s (REQ-FIX-8),
  // for the same reason as `handleInput` above.
  const handleResize = useCallback(
    (rows: number, cols: number) => {
      const effectiveCols = Math.max(cols, 40);
      const effectiveRows = Math.max(rows, 1);
      dispatchShellResize(streamingMode, effectiveRows, effectiveCols, {
        sendOverStream: sendStreamResize,
        sendOverHttp: (sinkRows, sinkCols) => {
          const targetId = sessionIdRef.current;
          if (targetId) {
            sendShellResize({ sessionId: targetId, rows: sinkRows, cols: sinkCols }).catch(() => {});
          }
        },
      });
    },
    [streamingMode, sendStreamResize, sendShellResize]
  );

  const handleInputRef = useRef(handleInput);
  useEffect(() => {
    handleInputRef.current = handleInput;
  }, [handleInput]);

  const handleResizeRef = useRef(handleResize);
  useEffect(() => {
    handleResizeRef.current = handleResize;
  }, [handleResize]);

  // --------------------------------------------------------------------------
  // Terminal Lifecycle & Addon Management
  // --------------------------------------------------------------------------
  useEffect(() => {
    const container = terminalContainerRef.current;
    if (!container) return;

    if (paneSessionId) {
      terminalSessionRegistry.registerActiveSession(paneSessionId);
    }
    const restorationData = paneSessionId
      ? terminalSessionRegistry.consumeRestorationData(paneSessionId)
      : null;

    const term = new Terminal({
      convertEol: !isStreamingActive,
      cursorBlink: true,
      cursorStyle: 'bar',
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace',
      fontSize: 12,
      lineHeight: 1.25,
      scrollback: 5000,
      theme: theme.terminal,
      allowProposedApi: true,
    });
    const fitAddon = new FitAddon();
    term.loadAddon(fitAddon);
    const serializeAddon = new SerializeAddon();
    term.loadAddon(serializeAddon);
    serializeAddonRef.current = serializeAddon;
    if (paneSessionId) {
      terminalSessionRegistry.registerSerializeAddon(paneSessionId, serializeAddon);
    }

    term.open(container);
    term.focus();
    terminalRef.current = term;
    fitAddonRef.current = fitAddon;

    const replayToXterm = (data: string | Uint8Array, onDone?: () => void) => {
      const finishWrite = beginTerminalWrite(pendingWritesRef);
      term.write(data, () => {
        finishWrite();
        onDone?.();
      });
    };

    const dataDisposable = term.onData((data) => {
      // Terminal-generated replies (OSC color reports, DSR, device attributes) use the same
      // channel as keystrokes and must reach the PTY. Only a locked vault suppresses input.
      dispatchTerminalData(data, vaultLockedRef.current, (payload) => {
        handleInputRef.current(payload);
      });
    });

    const resizeDisposable = term.onResize(({ cols, rows }) => {
      handleResizeRef.current(rows, cols);
    });

    // Close the small mount-order gap without waiting for layout. This MUST happen after
    // onData is subscribed: buffered startup bytes can contain Neovim's terminal queries, and
    // parsing them before the reply channel exists silently drops the answers. A later remount
    // appeared to fix the blank pane only because its protocol handler won that race.
    flushPendingOutput();

    // Track manual scroll-up so a repaint does not yank the viewport back down.
    term.onScroll(() => {
      const buffer = term.buffer.active;
      userScrolledUpRef.current = buffer.viewportY < buffer.baseY;
    });

    // Fit terminal dimensions BEFORE replaying saved snapshot so full-screen TUI snapshots
    // (such as Neovim in alternate buffer mode) do not wrap or clip against the 80x24 default.
    try {
      if (container.clientWidth > 0 && container.clientHeight > 0) {
        fitAddon.fit();
        term.resize(Math.max(term.cols, 40), term.rows);
        isSizedRef.current = true;
        setIsSized(true);
      } else if (restorationData && restorationData.cols > 0 && restorationData.rows > 0) {
        term.resize(Math.max(restorationData.cols, 40), Math.max(restorationData.rows, 1));
      }
    } catch { /* ignore */ }

    const snapshotHidesCursor = Boolean(
      restorationData?.snapshot &&
        (restorationData.snapshot.includes('\x1b[?1049h') ||
          restorationData.snapshot.includes('\x1b[?25l'))
    );
    if (session.kind === 'shell' && !snapshotHidesCursor) {
      replayToXterm('\x1b[?25h');
    }

    // Restore saved snapshot and unmounted deltas if present
    if (restorationData) {
      if (restorationData.snapshot) {
        replayToXterm(restorationData.snapshot, () => {
          if (restorationData.deltaChunks && restorationData.deltaChunks.length > 0) {
            for (const chunk of restorationData.deltaChunks) {
              replayToXterm(chunk);
            }
          }
          if (restorationData.savedViewportY !== undefined && restorationData.savedViewportY >= 0) {
            try {
              if (term.buffer.active.type !== 'alternate') {
                term.scrollToLine(restorationData.savedViewportY);
              }
              const buffer = term.buffer.active;
              userScrolledUpRef.current = buffer.viewportY < buffer.baseY;
            } catch { /* ignore */ }
          }
        });
      } else if (restorationData.deltaChunks && restorationData.deltaChunks.length > 0) {
        for (const chunk of restorationData.deltaChunks) {
          replayToXterm(chunk);
        }
      }
    }

    const dispatchResize = () => {
      try {
        if (container.clientWidth > 0 && container.clientHeight > 0) {
          fitAddon.fit();
          term.resize(Math.max(term.cols, 40), term.rows);
          handleResizeRef.current(term.rows, term.cols);
          term.focus();
          if (!isSizedRef.current) {
            isSizedRef.current = true;
            setIsSized(true);
          }
          flushPendingOutput();
        }
      } catch { /* ignore */ }
    };

    dispatchResize();
    const timer = setTimeout(() => {
      dispatchResize();
      term.focus();
    }, 150);

    const resizeObserver = new ResizeObserver(() => {
      try {
        if (container.clientWidth > 0 && container.clientHeight > 0) {
          fitAddon.fit();
          term.resize(Math.max(term.cols, 40), term.rows);
          if (!isSizedRef.current) {
            isSizedRef.current = true;
            setIsSized(true);
            handleResizeRef.current(term.rows, term.cols);
            flushPendingOutput();
          }
        }
      } catch { /* ignore */ }
    });
    resizeObserver.observe(container);

    const handleWindowResize = () => {
      try {
        if (container.clientWidth > 0 && container.clientHeight > 0) {
          fitAddon.fit();
          term.resize(Math.max(term.cols, 40), term.rows);
          if (!isSizedRef.current) {
            isSizedRef.current = true;
            setIsSized(true);
            handleResizeRef.current(term.rows, term.cols);
            flushPendingOutput();
          }
        }
      } catch { /* ignore */ }
    };
    window.addEventListener('resize', handleWindowResize);

    // Initial paint on mount for polled output if available. Gated on OWNERSHIP, not on the
    // transport: a stream that has not finished connecting still owns the screen, and resetting
    // here would wipe the snapshot and deltas restored just above — which consumeRestorationData
    // has already drained from the registry and cannot hand back.
    if (isPolledRepaintOwner && output) {
      // A polled capture is a full-screen string that relies on LF translation. This was the one
      // write site not asserting it, and a capture written with convertEol false staircases.
      term.options.convertEol = true;
      term.reset();
      term.write(output);
      if (session.kind === 'shell') {
        term.write('\x1b[?25h');
      }
      lastWrittenOutputRef.current = output;
    }

    return () => {
      window.removeEventListener('resize', handleWindowResize);
      if (keystrokeDebounceTimerRef.current) {
        clearTimeout(keystrokeDebounceTimerRef.current);
      }
      clearTimeout(timer);
      resizeObserver.disconnect();
      dataDisposable.dispose();
      resizeDisposable.dispose();

      const currentSessionId = sessionIdRef.current;
      if (currentSessionId) {
        // REQ-FIX-1 — nothing clears the buffered deltas here on purpose. A pane that was never
        // sized has no screen worth serializing, so it saves no snapshot; its withheld output
        // lives in the registry and is replayed by `consumeRestorationData` on the next mount.
        // Discarding it here is what made a backgrounded-then-closed-then-reopened tab lose
        // output silently. A pane that WAS sized has already flushed, so the buffer is empty and
        // the snapshot below is the whole story — no double replay either way.
        const canSaveSnapshot =
          pendingWritesRef.current === 0 || !terminalSessionRegistry.get(currentSessionId)?.snapshot;
        if (
          !isExplicitlyClosedRef.current &&
          terminalSessionRegistry.isSessionActive(currentSessionId) &&
          serializeAddonRef.current &&
          isSizedRef.current &&
          canSaveSnapshot
        ) {
          try {
            const serialized = serializeAddonRef.current.serialize();
            const viewportY = term.buffer.active.viewportY;
            terminalSessionRegistry.saveSnapshot(
              currentSessionId,
              serialized,
              viewportY,
              term.cols,
              term.rows
            );
          } catch (err) {
            console.warn('[ShellTerminalPane] failed to serialize snapshot on unmount:', err);
          }
        }
        terminalSessionRegistry.unregisterSerializeAddon(currentSessionId);
        terminalSessionRegistry.unregisterActiveSession(currentSessionId);
      }

      term.dispose();
      terminalRef.current = null;
      fitAddonRef.current = null;
      serializeAddonRef.current = null;
      lastWrittenOutputRef.current = '';
      isSizedRef.current = false;
      setIsSized(false);
    };
  }, []);

  // A keep-alive pane may mount while its wrapper is `display: none`, or while the dock is at the
  // zero-height start of its expansion transition. BottomDock publishes transition completion as
  // layoutRevision; ResizeObserver remains the continuous fallback for every other size change.
  // This effect is deliberately event-driven: no timing loop and no arbitrary retry budget.
  useLayoutEffect(() => {
    if (!isActive) return;
    const container = terminalContainerRef.current;
    const fitAddon = fitAddonRef.current;
    const term = terminalRef.current;
    if (!container || !fitAddon || !term) return;
    try {
      activateVisibleTerminal(container, fitAddon, term, {
        markSized: () => {
          if (!isSizedRef.current) {
            isSizedRef.current = true;
            setIsSized(true);
          }
        },
        sendResize: (rows, cols) => handleResizeRef.current(rows, cols),
        flushPendingOutput,
      });
    } catch { /* ResizeObserver or the next layout event will retry */ }
  }, [isActive, layoutRevision, flushPendingOutput]);

  // --------------------------------------------------------------------------
  // LEGACY POLLING PATH: Snapshot Diff & Repaint
  // When streaming is active, incoming bytes bypass term.reset() and are written directly.
  // --------------------------------------------------------------------------
  useEffect(() => {
    // Gated on OWNERSHIP of the screen, which a transient drop does NOT transfer.
    //
    // This effect calls term.reset(). The capture it repaints from is bounded at 120 lines while
    // the terminal holds 5000 of scrollback, so running it on a reconnect blip destroys thousands
    // of lines of real history to recover a fraction of one screen — and would reset over a
    // restoration whose deltas are already drained and unrecoverable. A drop moves input and
    // resize to HTTP (see handleInput/handleResize); it does not move the screen.
    if (!isPolledRepaintOwner) return;

    const term = terminalRef.current;
    if (!term || output === undefined) return;
    if (output === lastWrittenOutputRef.current) return;

    lastWrittenOutputRef.current = output;
    // A polled capture is a full-screen string that relies on LF translation, unlike raw stream
    // bytes — so this writer asserts what it needs rather than inheriting the flag.
    term.options.convertEol = true;
    term.reset();
    term.write(output || '', () => {
      if (session.kind === 'shell') {
        term.write('\x1b[?25h');
      }
      const buffer = term.buffer.active;
      if (!userScrolledUpRef.current && buffer.baseY > 0) {
        term.scrollToBottom();
      }
    });
  }, [output, isPolledRepaintOwner, session.kind]);

  useEffect(() => {
    if (terminalRef.current) {
      terminalRef.current.options.theme = theme.terminal;
    }
  }, [theme]);

  // Synchronize terminal convertEol option with streaming status (disabled during streaming)
  useEffect(() => {
    if (terminalRef.current) {
      terminalRef.current.options.convertEol = !isStreamingActive;
    }
  }, [isStreamingActive]);

  // A drop no longer repaints the pane (that would reset scrollback), so the user needs to be
  // told the stream is down rather than watching a frozen terminal. A thin banner, deliberately
  // not the covering overlay below: the existing content stays readable.
  const showReconnectingBanner = isStreamEnabled && !streamConnected && isRunning && !isBridgeUnreachable && !vaultLock.locked;
  const showUnreachableOverlay = isBridgeUnreachable && !output && !streamConnected;
  const showUnreachableBanner = isBridgeUnreachable && (Boolean(output) || streamConnected);
  const showConnecting = !output && !streamConnected && (session.status === 'starting' || isLoading);

  return (
    <div
      data-debug-id={`shell-terminal-pane-${session.session_id}`}
      className="relative flex flex-col flex-1 h-full min-h-0 w-full overflow-hidden bg-canvas"
    >
      {showUnreachableBanner && (
        <div
          data-debug-id="shell-terminal-unreachable-banner"
          className="z-10 flex shrink-0 items-center justify-between gap-2 border-b border-warning/30 bg-warning-soft px-3 py-1.5 text-xs text-warning"
        >
          <div className="flex items-center gap-1.5">
            <Icon name="alert" size={14} className="shrink-0 text-warning" />
            <span>Bridge Unreachable. Showing cached output.</span>
          </div>
          <button
            type="button"
            data-debug-id="shell-terminal-unreachable-banner-retry-btn"
            onClick={handleRetry}
            className="inline-flex items-center gap-1 rounded px-2 py-0.5 text-[11px] font-medium text-warning hover:bg-warning/20 transition-colors cursor-pointer"
          >
            <Icon name="refresh" size={12} />
            <span>Retry</span>
          </button>
        </div>
      )}

      {showReconnectingBanner && (
        <div
          data-debug-id="shell-terminal-reconnecting-banner"
          className="z-10 flex shrink-0 items-center gap-1.5 border-b border-subtle bg-surface-raised px-3 py-1.5 text-xs text-muted"
        >
          <Icon name="refresh" size={12} className="shrink-0 animate-spin text-accent" />
          <span>Reconnecting to terminal… keystrokes are still being delivered.</span>
        </div>
      )}

      {vaultLock.locked ? (
        <VaultLockedOverlay bridgeId={vaultLock.bridgeId} onUnsealed={vaultLock.markUnsealed} />
      ) : showUnreachableOverlay ? (
        <div
          data-debug-id="shell-terminal-unreachable"
          className="absolute inset-0 z-20 flex flex-col items-center justify-center gap-3 bg-canvas/95 p-6 text-center text-xs"
        >
          <div className="grid h-10 w-10 place-items-center rounded-full bg-danger/10 text-danger">
            <Icon name="alert" size={20} />
          </div>
          <div className="max-w-xs space-y-1">
            <p className="font-semibold text-primary">Bridge Unreachable</p>
            <p className="text-muted">
              The bridge hosting this shell session is offline or unreachable. Terminal input and output are temporarily unavailable.
            </p>
          </div>
          <button
            type="button"
            data-debug-id="shell-terminal-unreachable-retry-btn"
            onClick={handleRetry}
            className="inline-flex items-center gap-1.5 rounded-lg bg-surface-raised px-3 py-1.5 font-medium text-primary hover:bg-neutral-soft border border-subtle transition-colors cursor-pointer"
          >
            <Icon name="refresh" size={12} />
            <span>Retry</span>
          </button>
        </div>
      ) : showConnecting ? (
        <div
          data-debug-id={`shell-terminal-loading-${session.session_id}`}
          className="absolute inset-0 z-10 flex flex-col items-center justify-center gap-2 bg-canvas/90 text-xs text-muted pointer-events-none"
        >
          <Icon name="refresh" className="animate-spin text-accent" size={18} />
          <span>Connecting to terminal…</span>
        </div>
      ) : null}

      {/* xterm container */}
      <div
        ref={terminalContainerRef}
        data-debug-id={`shell-terminal-xterm-${session.session_id}`}
        onClick={() => terminalRef.current?.focus()}
        tabIndex={0}
        role="region"
        aria-label="Shell Terminal"
        style={{ backgroundColor: theme.terminal.background }}
        className="chat-scrollbar relative flex-1 min-h-0 w-full overflow-x-auto p-2 font-mono text-xs cursor-text touch-manipulation focus:outline-none"
      />
    </div>
  );
}
