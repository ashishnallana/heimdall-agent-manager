import UpgradePrompt from '../billing/UpgradePrompt';
import { useEntitlements } from '../../hooks/useEntitlements';
import { planLimitDetails, type PlanLimitDetails } from '../../utils/planLimit';
import { isPaneRepaintStart } from '../shells/paneDeliveryQueue.ts';
import { useCallback, useEffect, useRef, useState } from 'react';
import type { Terminal as TerminalType } from '@xterm/xterm';
import type { FitAddon as FitAddonType } from '@xterm/addon-fit';
import * as xtermModule from '@xterm/xterm';
import * as fitAddonModule from '@xterm/addon-fit';

const xtermObj = xtermModule as Record<string, any>;
const Terminal = (xtermObj.Terminal || xtermObj['default']?.Terminal || xtermObj['default']) as typeof TerminalType;

const fitAddonObj = fitAddonModule as Record<string, any>;
const FitAddon = (fitAddonObj.FitAddon || fitAddonObj['default']?.FitAddon || fitAddonObj['default']) as typeof FitAddonType;
import { useAgentPaneSubscription } from '../../hooks/useAgentPaneSubscription';
import { useFetchAgentInstanceQuery, useSendAgentPaneInputMutation, useSendAgentPaneResizeMutation } from '../../api/endpoints/agents';
import { useFetchExperimentsQuery } from '../../api/endpoints/settings';
import { useAgentStream } from './useAgentStream';
import { usePaneVaultLock } from '../shells/usePaneVaultLock';
import VaultLockedOverlay from '../shells/VaultLockedOverlay';
import { useTheme } from '../../store/themeSlice';
import { usePaneVisible } from '../workbench/paneVisibility';

/**
 * Compute fitted font size for terminal container on narrow viewports (<500px).
 * Standard CLI layouts require 80 columns. On mobile screens (e.g. 360px - 390px),
 * normal 12px font (~7.2px/col) exceeds container width and causes horizontal scrollbars.
 * Scaling font size ensures 80 columns fit within available width (REQ-PANE-MOBILE-2).
 */
export function computeFittedFontSize(containerWidth: number): number {
  if (containerWidth >= 500) {
    return 12;
  }
  // Available width accounting for p-2 (16px) horizontal padding
  const availableWidth = Math.max(0, containerWidth - 16);
  // Monospace character aspect ratio is ~0.6 (charWidth ~= fontSize * 0.6)
  // For 80 columns: fontSize <= availableWidth / (80 * 0.6) = availableWidth / 48
  const calculated = Math.floor(availableWidth / (80 * 0.6));
  return Math.max(6, Math.min(12, calculated));
}

export interface AgentPaneComposerPanelProps {
  agentInstanceId?: string | null;
  isExpanded: boolean;
  onClose?: () => void;
  onToggleExpand?: () => void;
  isActiveTab?: boolean;
  runtimeStatus?: string;
  startupStatus?: string;
  isStarting?: boolean;
  runCount?: number;
  startedAt?: string;
  onStreamOutput?: () => void;
  onStreamReady?: (info?: any) => void;
  onStreamClosed?: (info?: any) => void;
  className?: string;
  hideHeader?: boolean;
  fillPane?: boolean;
}

export function AgentPaneComposerPanel({
  agentInstanceId,
  isExpanded,
  onClose,
  onToggleExpand,
  isActiveTab = true,
  runtimeStatus,
  startupStatus,
  isStarting = false,
  runCount,
  startedAt,
  onStreamOutput,
  onStreamReady,
  onStreamClosed,
  className = '',
  hideHeader = false,
  fillPane,
}: AgentPaneComposerPanelProps) {
  const entitlements = useEntitlements();
  const [planLimit, setPlanLimit] = useState<PlanLimitDetails | null>(null);
  const reportPlanLimit = (error: unknown) => setPlanLimit(planLimitDetails(error));
  useEffect(() => { setPlanLimit(null); }, [agentInstanceId]);
  const { theme } = useTheme();
  const [terminalDimensions, setTerminalDimensions] = useState<{ cols: number; rows: number }>({
    cols: 80,
    rows: 24,
  });

  // Track if panel has been expanded at least once or started, to lazily initialize xterm
  const [hasBeenExpanded, setHasBeenExpanded] = useState<boolean>(isExpanded || isStarting);
  useEffect(() => {
    if (isExpanded || isStarting) {
      setHasBeenExpanded(true);
    }
  }, [isExpanded, isStarting]);

  // --------------------------------------------------------------------------
  // Experimental Flag & Dual-Mode Configuration (REQ-STREAM-IMPL-4)
  // --------------------------------------------------------------------------
  const { data: expData } = useFetchExperimentsQuery();
  const isStreamingExperimentEnabled = Boolean(
    expData?.flags?.find((f) => f.key === 'streaming_terminal_pane')?.enabled
  );

  const [streamRuntimeStatus, setStreamRuntimeStatus] = useState<string | null>(null);

  useEffect(() => {
    setStreamRuntimeStatus(null);
  }, [agentInstanceId, runtimeStatus]);

  const onStreamOutputRef = useRef(onStreamOutput);
  useEffect(() => {
    onStreamOutputRef.current = onStreamOutput;
  }, [onStreamOutput]);

  const onStreamReadyRef = useRef(onStreamReady);
  useEffect(() => {
    onStreamReadyRef.current = onStreamReady;
  }, [onStreamReady]);

  const onStreamClosedRef = useRef(onStreamClosed);
  useEffect(() => {
    onStreamClosedRef.current = onStreamClosed;
  }, [onStreamClosed]);

  const hasReceivedOutputRef = useRef<boolean>(false);
  const streamBufferRef = useRef<Array<Uint8Array | string>>([]);
  // REQ-PTY-NET-7: replay gate. While an absolute repaint (snapshot/screen, recognised by
  // its leading erase-screen or alt-screen escape) is being written, xterm's own answers to
  // the queries inside it (DA, DSR, OSC 11 colour reports) must not be sent back to the pty
  // as if the user typed them. ShellTerminalPane has had this gate (pendingReplaysRef) for a
  // while; the agent pane shares the same pipeline and lacked it.
  const pendingReplaysRef = useRef(0);

  useEffect(() => {
    // A mounted pane may switch targets: discard the old agent's scrollback and
    // buffered output, while same-agent reconnects keep their terminal contents.
    hasReceivedOutputRef.current = false;
    streamBufferRef.current = [];
    pendingReplaysRef.current = 0;
    userScrolledUpRef.current = false;
    lastWrittenOutputRef.current = '';
    terminalRef.current?.reset();
  }, [agentInstanceId]);

  useEffect(() => {
    if (isStarting) {
      hasReceivedOutputRef.current = false;
      streamBufferRef.current = [];
    }
  }, [isStarting]);

  // --------------------------------------------------------------------------
  // T10 (REQ-T10-3): VAULT LOCK. A locked bridge refuses this pane's input; the pane
  // shows the shared locked overlay (scrollback stays visible underneath), drops
  // keystrokes, and re-attaches its stream once the bridge is unsealed. The bridge
  // comes from the cached instance row; a vault_locked frame's bridge_id wins.
  // --------------------------------------------------------------------------
  const { data: instanceData } = useFetchAgentInstanceQuery(
    { instanceId: agentInstanceId || '' },
    { skip: !agentInstanceId },
  );
  const instanceBridgeId: string | undefined = instanceData?.instance?.bridge_id || undefined;
  const resumeAfterUnsealRef = useRef<() => void>(() => {});
  const vaultLock = usePaneVaultLock({
    bridgeId: instanceBridgeId,
    sessionId: agentInstanceId,
    onResume: () => resumeAfterUnsealRef.current(),
  });
  const vaultLockedRef = useRef(vaultLock.locked);
  useEffect(() => { vaultLockedRef.current = vaultLock.locked; }, [vaultLock.locked]);

  // --------------------------------------------------------------------------
  // STREAMING PATH: Keep output mounted through transport failures and manual retry.
  // --------------------------------------------------------------------------
  const streamRuntimeStopped = !isStarting && [runtimeStatus, streamRuntimeStatus].some(
    (status) => status === 'stopped' || status === 'failed' || status === 'exited'
  );
  const streamEnabled = isStreamingExperimentEnabled && !planLimit && entitlements.terminal_streaming_enabled && !streamRuntimeStopped && !vaultLock.locked;
  const {
    readOnly: streamReadOnly,
    connected: streamConnected,
    disconnected: streamDisconnected,
    isStreamReady,
    sendInput: sendStreamInput,
    sendResize: sendStreamResize,
    reconnect: reconnectStream,
  } = useAgentStream({
    agentInstanceId: (isExpanded || isStarting) && isActiveTab ? agentInstanceId : null,
    enabled: streamEnabled,
    rows: terminalDimensions.rows,
    cols: terminalDimensions.cols,
    onStreamReady: (info) => {
      onStreamReadyRef.current?.(info);
    },
    onStreamClosed: (info) => {
      setStreamRuntimeStatus('stopped');
      onStreamClosedRef.current?.(info);
    },
    onOutput: (bytes) => {
      if (bytes && bytes.length > 0) {
        streamBufferRef.current.push(bytes);
        onStreamOutputRef.current?.();
      }
      hasReceivedOutputRef.current = true;
      const term = terminalRef.current;
      if (!term) return;
      if (term.options.convertEol) {
        term.options.convertEol = false;
      }
      const isRepaint = isPaneRepaintStart(bytes);
      if (isRepaint) pendingReplaysRef.current += 1;
      term.write(bytes, () => {
        if (isRepaint) pendingReplaysRef.current = Math.max(0, pendingReplaysRef.current - 1);
        const buffer = term.buffer.active;
        if (!userScrolledUpRef.current && buffer.type !== 'alternate' && buffer.baseY > 0) {
          term.scrollToBottom();
        }
      });
    },
    onStatus: (status) => {
      if (status) {
        setStreamRuntimeStatus(status);
      }
    },
    onPlanLimit: reportPlanLimit,
    onVaultLocked: (signal) => {
      // A locked vault is not a stream failure: no fallback to polling.
      vaultLock.report(signal);
    },
  });

  const readOnly = streamReadOnly || !entitlements.terminal_input_enabled || Boolean(planLimit);
  const readOnlyRef = useRef(readOnly);
  readOnlyRef.current = readOnly;
  // Rendering stays in stream mode while disconnected; polling must not erase scrollback.
  const isStreamingActive = isStreamingExperimentEnabled;
  const isStreamTransportReady = isStreamingActive && streamConnected;

  // After an unseal: re-attach the stream (it may have been closed for vault_locked),
  // or, on the polling path, refetch the pane so it repaints at once.
  resumeAfterUnsealRef.current = () => {
    if (isStreamingExperimentEnabled) {
      reconnectStream();
    } else {
      refetchRef.current?.();
    }
  };

  // Track runCount, startedAt, and isStarting to reset stream on agent restart (REQ-STREAM-RECONNECT-27)
  const prevRunCountRef = useRef<number | undefined>(runCount);
  const prevStartedAtRef = useRef<string | undefined>(startedAt);
  const prevIsStartingRef = useRef<boolean>(isStarting);

  useEffect(() => {
    const runCountChanged = prevRunCountRef.current !== undefined && prevRunCountRef.current !== runCount;
    const startedAtChanged = prevStartedAtRef.current !== undefined && prevStartedAtRef.current !== startedAt;
    const isRestartStarting = !prevIsStartingRef.current && isStarting;

    prevRunCountRef.current = runCount;
    prevStartedAtRef.current = startedAt;
    prevIsStartingRef.current = isStarting;

    if (runCountChanged || startedAtChanged || isRestartStarting) {
      setStreamRuntimeStatus(null);
      streamBufferRef.current = [];
      hasReceivedOutputRef.current = false;
      if (terminalRef.current) {
        terminalRef.current.reset();
      }
      reconnectStream();
    }
  }, [runCount, startedAt, isStarting, reconnectStream]);

  const paneVisible = usePaneVisible();
  // --------------------------------------------------------------------------
  // LEGACY POLLING PATH: 500ms/5m polled capture with SHA-256 diff & term.reset()
  // Cleanly isolated so that removing legacy polling in the future only requires
  // deleting this block and the legacy branches in handleInput / handleResize.
  // --------------------------------------------------------------------------
  const {
    output,
    isLoading,
    isFetching,
    refetch,
  } = useAgentPaneSubscription({
    onPlanLimit: reportPlanLimit,
    agentInstanceId: !planLimit && entitlements.terminal_streaming_enabled && !isStreamingExperimentEnabled ? agentInstanceId : null,
    isExpanded,
    // A tab hidden by the layout (maximised tile, hidden aux dock) is not on screen:
    // the 500 ms capture pauses and resumes with a refetch when it is shown.
    isActiveTab: isActiveTab && paneVisible,
    runtimeStatus,
    width: terminalDimensions.cols,
    lineLimit: 120,
  });

  const [sendAgentPaneInput] = useSendAgentPaneInputMutation();
  const [sendAgentPaneResize] = useSendAgentPaneResizeMutation();

  const terminalContainerRef = useRef<HTMLDivElement | null>(null);
  const terminalRef = useRef<TerminalType | null>(null);
  const fitAddonRef = useRef<FitAddonType | null>(null);
  const preRef = useRef<HTMLPreElement | null>(null);
  const userScrolledUpRef = useRef<boolean>(false);
  const lastWrittenOutputRef = useRef<string>('');
  const agentInstanceIdRef = useRef(agentInstanceId);
  const refetchRef = useRef(refetch);
  const keystrokeDebounceTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    agentInstanceIdRef.current = agentInstanceId;
  }, [agentInstanceId]);

  useEffect(() => {
    refetchRef.current = refetch;
  }, [refetch]);

  // Unified input handler cleanly routing between streaming and legacy polling
  const handleInput = useCallback(
    (data: string) => {
      if (readOnlyRef.current) return;
      // T10: input is refused while the bridge vault is locked — the overlay says so.
      if (vaultLockedRef.current) return;
      if (isStreamTransportReady) {
        // STREAMING: Send keystrokes directly over WebSocket without debounce (<10ms latency)
        sendStreamInput(data);
      } else {
        // LEGACY POLLING: HTTP POST with 50ms debounced capture refetch
        const targetId = agentInstanceIdRef.current;
        if (targetId) {
          // A 423 from this POST is announced to the pane by the mutation itself.
          sendAgentPaneInput({ agentInstanceId: targetId, data }).catch(() => {});
        }
        if (keystrokeDebounceTimerRef.current) {
          clearTimeout(keystrokeDebounceTimerRef.current);
        }
        keystrokeDebounceTimerRef.current = setTimeout(() => {
          refetchRef.current?.();
        }, 50);
      }
    },
    [isStreamTransportReady, sendStreamInput, sendAgentPaneInput]
  );

  // Unified resize handler routing between streaming and legacy polling
  const handleResize = useCallback(
    (rows: number, cols: number) => {
      const effectiveCols = Math.max(cols, 80);
      const effectiveRows = Math.max(rows, 1);
      if (readOnlyRef.current) {
        setTerminalDimensions({ cols: effectiveCols, rows: effectiveRows });
        return;
      }
      if (isStreamTransportReady) {
        sendStreamResize(effectiveRows, effectiveCols);
      } else {
        const targetId = agentInstanceIdRef.current;
        if (targetId) {
          sendAgentPaneResize({ agentInstanceId: targetId, rows: effectiveRows, cols: effectiveCols }).catch(() => {});
        }
      }
      setTerminalDimensions({ cols: effectiveCols, rows: effectiveRows });
    },
    [isStreamTransportReady, sendStreamResize, sendAgentPaneResize]
  );

  const handleInputRef = useRef(handleInput);
  useEffect(() => {
    handleInputRef.current = handleInput;
  }, [handleInput]);

  const handleResizeRef = useRef(handleResize);
  useEffect(() => {
    handleResizeRef.current = handleResize;
  }, [handleResize]);

  // Detect manual scroll up on accessible fallback pre
  const handleScroll = useCallback(() => {
    const node = preRef.current;
    if (!node) return;
    const isAtBottom = node.scrollHeight - node.scrollTop - node.clientHeight <= 25;
    userScrolledUpRef.current = !isAtBottom;
  }, []);

  // Dispatch terminal fit and dimension synchronization (REQ-WINSIZE-3, REQ-STREAM-UI-POLISH-1)
  const dispatchResize = useCallback(() => {
    const container = terminalContainerRef.current;
    const term = terminalRef.current;
    const fitAddon = fitAddonRef.current;
    if (!container || !term || !fitAddon) return;
    try {
      if (container.clientWidth > 0 && container.clientHeight > 0) {
        // Mobile 80-column auto-fit (REQ-PANE-MOBILE-2)
        if (container.clientWidth < 500) {
          const fittedSize = computeFittedFontSize(container.clientWidth);
          if (term.options.fontSize !== fittedSize) {
            term.options.fontSize = fittedSize;
          }
        } else if (term.options.fontSize !== 12) {
          term.options.fontSize = 12;
        }
        fitAddon.fit();
        // If on a narrow viewport and measured cols is still under 80, decrement font size and re-fit
        if (container.clientWidth < 500 && term.cols < 80 && (term.options.fontSize ?? 12) > 6) {
          term.options.fontSize = Math.max(6, (term.options.fontSize ?? 12) - 1);
          fitAddon.fit();
        }
        // Guarantee minimum usable width while fitting container rows accurately for TUIs
        term.resize(Math.max(term.cols, 80), Math.max(term.rows, 1));
      }
      if (term.rows > 0 && term.cols > 0) {
        handleResizeRef.current(term.rows, term.cols);
      }
    } catch (e) {}
  }, []);

  // Initialize @xterm/xterm Terminal instance when opened/expanded
  useEffect(() => {
    if (!hasBeenExpanded || !terminalContainerRef.current) return;
    const container = terminalContainerRef.current;

    const initialFontSize = typeof container.clientWidth === 'number' && container.clientWidth > 0
      ? computeFittedFontSize(container.clientWidth)
      : 12;

    const term = new Terminal({
      disableStdin: readOnlyRef.current,
      convertEol: !isStreamingActive,
      cursorBlink: false,
      cursorInactiveStyle: 'none',
      cursorStyle: 'bar',
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace',
      fontSize: initialFontSize,
      lineHeight: 1.25,
      scrollback: 1000,
      theme: theme.terminal,
      allowProposedApi: true,
    });

    const fitAddon = new FitAddon();
    term.loadAddon(fitAddon);
    term.open(container);
    // Hide xterm's synthetic cursor layer in legacy polling mode where snapshots don't preserve cursor
    if (!isStreamingActive) {
      term.write('\x1b[?25l');
    }

    terminalRef.current = term;
    fitAddonRef.current = fitAddon;

    // Track scrolling within xterm buffer
    term.onScroll(() => {
      const buffer = term.buffer.active;
      userScrolledUpRef.current = buffer.viewportY < buffer.baseY;
    });

    // Keystroke input hook: dispatch to unified handleInputRef
    const dataDisposable = term.onData((data) => {
      // Suppress synthetic terminal query responses triggered during a repaint write.
      if (pendingReplaysRef.current > 0) return;
      handleInputRef.current(data);
    });

    // Terminal resize hook: dispatch to unified handleResizeRef
    const resizeDisposable = term.onResize(({ cols, rows }) => {
      handleResizeRef.current(rows, cols);
    });

    // Dispatch initial resize immediately after initial fitAddon.fit() on mount/expansion
    dispatchResize();

    // Initial fit with frame delay for container layout (animation may not be settled yet)
    const timer = setTimeout(() => {
      dispatchResize();
    }, 150);

    const resizeObserver = new ResizeObserver(() => {
      dispatchResize();
    });
    resizeObserver.observe(container);

    const handleWindowResize = () => {
      dispatchResize();
    };
    if (typeof window !== 'undefined') {
      window.addEventListener('resize', handleWindowResize);
    }

    // Initial write if output already present in streaming/legacy mode, or startup indicator
    if (streamBufferRef.current.length > 0) {
      hasReceivedOutputRef.current = true;
      if (term.options.convertEol) {
        term.options.convertEol = false;
      }
      for (const chunk of streamBufferRef.current) {
        term.write(chunk);
      }
      const buffer = term.buffer.active;
      if (!userScrolledUpRef.current && buffer.type !== 'alternate' && buffer.baseY > 0) {
        term.scrollToBottom();
      }
    } else if (!isStreamingActive && output) {
      term.options.convertEol = true;
      term.reset();
      term.write('\x1b[?25l' + output, () => {
        const buffer = term.buffer.active;
        if (!userScrolledUpRef.current && buffer.baseY > 0) {
          term.scrollToBottom();
        }
      });
      lastWrittenOutputRef.current = output;
    } else if (isStarting && !output && streamBufferRef.current.length === 0) {
      term.write('\x1b[90mStarting agent…\x1b[0m');
    } else if (isLoading && !isStreamingActive) {
      term.write('\x1b[90mLoading terminal output…\x1b[0m');
    }

    return () => {
      if (typeof window !== 'undefined') {
        window.removeEventListener('resize', handleWindowResize);
      }
      if (keystrokeDebounceTimerRef.current) {
        clearTimeout(keystrokeDebounceTimerRef.current);
      }
      clearTimeout(timer);
      resizeObserver.disconnect();
      dataDisposable.dispose();
      resizeDisposable.dispose();
      term.dispose();
      terminalRef.current = null;
      fitAddonRef.current = null;
      lastWrittenOutputRef.current = '';
    };
  }, [hasBeenExpanded, dispatchResize]);

  // Recalculate terminal dimensions and fitAddon accurately upon expansion / transition completion
  useEffect(() => {
    if (isExpanded && terminalRef.current && fitAddonRef.current) {
      dispatchResize();
      const t1 = setTimeout(() => {
        dispatchResize();
      }, 150);
      const t2 = setTimeout(() => {
        dispatchResize();
      }, 320);
      return () => {
        clearTimeout(t1);
        clearTimeout(t2);
      };
    }
  }, [isExpanded, dispatchResize]);

  // When pane is open but terminal is awaiting initial output during startup, show subtle 'Starting agent…' loading indicator
  useEffect(() => {
    if (isStarting && isExpanded && !hasReceivedOutputRef.current && streamBufferRef.current.length === 0 && !output) {
      const term = terminalRef.current;
      if (term) {
        term.reset();
        term.write('\x1b[90mStarting agent…\x1b[0m');
      }
    }
  }, [isStarting, isExpanded, output]);

  // Expand pane if legacy polling output arrives during startup
  useEffect(() => {
    if (isStarting && output) {
      onStreamOutputRef.current?.();
    }
  }, [isStarting, output]);

  // Update terminal instance with active theme's terminal palette (REQ-THEME-EXTERNALS)
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

  // Feed incoming ANSI output into terminal (LEGACY POLLING PATH)
  useEffect(() => {
    if (isStreamingActive) return; // Prevent clearing/redrawing buffer during active streaming
    const term = terminalRef.current;
    if (!term || output === undefined) return;
    if (output === lastWrittenOutputRef.current) return;

    lastWrittenOutputRef.current = output;
    term.reset();
    term.write('\x1b[?25l' + (output || ''), () => {
      if (!userScrolledUpRef.current) {
        term.scrollToBottom();
      }
    });
  }, [output, isStreamingActive]);

  // Auto-scroll to bottom on update for accessible fallback
  useEffect(() => {
    const node = preRef.current;
    if (!node) return;
    if (!userScrolledUpRef.current) {
      node.scrollTop = node.scrollHeight;
    }
  }, [output]);

  // Reset scroll on expand
  useEffect(() => {
    if (isExpanded) {
      userScrolledUpRef.current = false;
      terminalRef.current?.scrollToBottom();
      const node = preRef.current;
      if (node) {
        node.scrollTop = node.scrollHeight;
      }
    }
  }, [isExpanded]);

  useEffect(() => {
    if (terminalRef.current) terminalRef.current.options.disableStdin = readOnly;
  }, [readOnly]);

  return (
    <div
      data-debug-id="agent-pane-composer-panel"
      aria-hidden={!isExpanded}
      className={`transition-all duration-300 ease-in-out overflow-hidden bg-surface ${
        fillPane ? 'rounded-none' : 'rounded-xl'
      } ${
        isExpanded
          ? fillPane
            ? 'flex-1 min-h-0 h-full flex flex-col opacity-100 transform-none pointer-events-auto'
            : 'max-h-[500px] opacity-100 transform-none pointer-events-auto'
          : 'max-h-0 opacity-0 -translate-y-1 pointer-events-none !mb-0 !p-0'
      } ${className}`}
    >
      {planLimit ? <UpgradePrompt details={planLimit} debugId="agent-pane-plan-limit" onRetry={() => { setPlanLimit(null); reconnectStream(); }} /> : !entitlements.terminal_streaming_enabled ? <UpgradePrompt details={{ limit: 'terminal_streaming_enabled' }} debugId="agent-pane-streaming-upgrade" /> : readOnly ? <UpgradePrompt subtle details={{ limit: 'terminal_input_enabled' }} debugId="agent-pane-read-only" /> : null}
      {streamEnabled && streamDisconnected && (
        <div data-debug-id="agent-pane-stream-disconnected" role="status" className="flex items-center justify-between gap-3 px-3 py-2 text-sm text-muted">
          <span>Stream disconnected</span>
          <button
            type="button"
            data-debug-id="agent-pane-retry-connection-btn"
            onClick={reconnectStream}
            className="rounded px-3 py-1 text-primary hover:bg-surface focus-visible:outline focus-visible:outline-2 focus-visible:outline-accent"
          >
            Retry Connection
          </button>
        </div>
      )}
      <div className={fillPane ? 'relative w-full flex-1 min-h-0 flex flex-col' : 'relative w-full'}>
        {/* Interactive xterm terminal container (REQ-PANE-MOBILE-1, REQ-PANE-MOBILE-2) */}
        <div
          ref={terminalContainerRef}
          data-debug-id="agent-pane-terminal"
          onClick={() => terminalRef.current?.focus()}
          tabIndex={isExpanded ? 0 : -1}
          role="region"
          aria-label="Interactive Terminal"
          style={{ backgroundColor: theme.terminal.background }}
          className={`chat-scrollbar relative w-full overflow-x-auto p-2 font-mono text-xs cursor-text touch-manipulation focus:outline-none ${
            fillPane
              ? 'flex-1 min-h-0 h-full'
              : 'min-h-[140px] h-[140px] max-h-[200px] sm:min-h-[360px] sm:h-[360px] sm:max-h-[420px]'
          }`}
        >
          {isStarting && !hasReceivedOutputRef.current && streamBufferRef.current.length === 0 && !output && (
            <div
              data-debug-id="agent-pane-starting-indicator"
              className="pointer-events-none absolute inset-0 flex items-center justify-center gap-2 font-sans text-xs text-muted"
            >
              <span className="h-2 w-2 rounded-full bg-accent animate-ping" />
              <span>Starting agent…</span>
            </div>
          )}
        </div>

        {/* T10: locked-vault overlay over the terminal; scrollback stays visible beneath. */}
        {vaultLock.locked ? (
          <VaultLockedOverlay bridgeId={vaultLock.bridgeId} onUnsealed={vaultLock.markUnsealed} />
        ) : null}

        {/* Accessible fallback & static verification pre element */}
        <pre
          ref={preRef}
          onScroll={handleScroll}
          data-debug-id="agent-pane-output"
          aria-hidden="true"
          className="sr-only chat-scrollbar overflow-auto whitespace-pre-wrap p-3 font-mono text-xs leading-5 text-primary max-h-[200px] sm:max-h-[420px]"
        >
          {output || (isStarting && !hasReceivedOutputRef.current && streamBufferRef.current.length === 0 ? 'Starting agent…' : isLoading ? 'Loading terminal output…' : '')}
        </pre>
      </div>
    </div>
  );
}

export default AgentPaneComposerPanel;
