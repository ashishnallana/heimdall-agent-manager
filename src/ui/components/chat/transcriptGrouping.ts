import type { ChatMessage } from './types';

/**
 * Checks whether a message represents an agent start/restart system notice.
 */
export function isAgentStartMessage(message: ChatMessage): boolean {
  if (message.messageType === 'agent_start' || message.messageType === 'agent_start_clubbed') return true;
  // tool_activity bodies are generated counts; never sniff them for "started".
  if (message.messageType === 'tool_activity') return false;
  if (message.messageType === 'system') return true;
  const body = (message.body || '').toLowerCase();
  return (
    body.includes('started') ||
    body.includes('ready') ||
    body.includes('restart') ||
    Boolean(message.metadata?.system_type === 'agent_start' || message.metadata?.system_type === 'startup')
  );
}

/**
 * Groups consecutive shell_run messages (length >= 2) into a clubbed group,
 * and groups consecutive agent start messages (length >= 2) into a clubbed start notice.
 * Filters out runs that are currently pinned above the composer.
 */
export function groupTranscriptMessages(
  messages: ChatMessage[],
  pinnedSessionIds: Set<string> = new Set(),
): ChatMessage[] {
  const unpinned = messages.filter((message) => {
    if (message.messageType !== 'shell_run') return true;
    const sessionId = String(message.metadata?.session_id || message.metadata?.sessionId || '');
    return !pinnedSessionIds.has(sessionId);
  });

  const result: ChatMessage[] = [];
  let i = 0;
  while (i < unpinned.length) {
    const msg = unpinned[i];

    // 1. Consecutive shell_run messages (length >= 2) -> REQ-CLUB-RUN-COMMANDS-13
    if (msg.messageType === 'shell_run') {
      let j = i;
      while (j < unpinned.length && unpinned[j].messageType === 'shell_run') {
        j++;
      }
      const runGroup = unpinned.slice(i, j);
      if (runGroup.length >= 2) {
        const firstRun = runGroup[0];
        const lastRun = runGroup[runGroup.length - 1];
        result.push({
          key: `clubbed_run_${firstRun.messageId}_${lastRun.messageId}`,
          messageId: `clubbed_run_${firstRun.messageId}`,
          body: '',
          isUser: false,
          createdUnixMs: firstRun.createdUnixMs,
          deliveredUnixMs: 0,
          readUnixMs: 0,
          deliveryFailedUnixMs: 0,
          deliveryError: '',
          sending: false,
          authorLabel: '',
          messageType: 'shell_run_group',
          messageStatus: 'complete',
          metadata: {
            clubbedRuns: runGroup,
            count: runGroup.length,
            startUnixMs: firstRun.createdUnixMs,
            endUnixMs: lastRun.createdUnixMs,
          },
        });
        i = j;
        continue;
      } else {
        result.push(msg);
        i++;
        continue;
      }
    }

    // 2. Consecutive agent start/restart system messages (length >= 2) -> REQ-SUBTLE-AGENT-START-14
    if (isAgentStartMessage(msg)) {
      let j = i;
      while (j < unpinned.length && isAgentStartMessage(unpinned[j])) {
        j++;
      }
      const startGroup = unpinned.slice(i, j);
      if (startGroup.length >= 2) {
        const firstStart = startGroup[0];
        const lastStart = startGroup[startGroup.length - 1];
        result.push({
          key: `clubbed_start_${firstStart.messageId}_${lastStart.messageId}`,
          messageId: `clubbed_start_${firstStart.messageId}`,
          body: `agent started ${startGroup.length} times`,
          isUser: false,
          createdUnixMs: firstStart.createdUnixMs,
          deliveredUnixMs: 0,
          readUnixMs: 0,
          deliveryFailedUnixMs: 0,
          deliveryError: '',
          sending: false,
          authorLabel: '',
          messageType: 'agent_start_clubbed',
          messageStatus: 'complete',
          metadata: {
            clubbedStarts: startGroup,
            count: startGroup.length,
            startUnixMs: firstStart.createdUnixMs,
            endUnixMs: lastStart.createdUnixMs,
          },
        });
        i = j;
        continue;
      } else {
        result.push(msg);
        i++;
        continue;
      }
    }

    // Any other message
    result.push(msg);
    i++;
  }

  return result;
}

/**
 * Formats a time range string between two unix timestamps (in ms).
 */
export function formatClubbedTimeRange(
  startUnixMs?: number,
  endUnixMs?: number,
  formatTimestamp?: (unixMs: number) => { label: string },
): string {
  if (!formatTimestamp) return '';
  const startTime = startUnixMs ? formatTimestamp(startUnixMs).label : '';
  const endTime = endUnixMs ? formatTimestamp(endUnixMs).label : '';
  if (startTime && endTime && startTime !== endTime) {
    return `${startTime} \u2013 ${endTime}`;
  }
  return startTime || endTime || '';
}

/**
 * Formats the summary label for a clubbed command group.
 */
export function formatClubbedRunLabel(count: number): string {
  return `Ran ${count} commands`;
}

/**
 * Formats subtle agent start indicator divider label.
 */
export function formatAgentStartDividerText(
  count: number,
  timeStr: string,
): string {
  if (count <= 1) {
    return `agent started (${timeStr})`;
  }
  return `agent started ${count} times (${timeStr})`;
}

/**
 * State container for clubbed command group expansion and individual command expansion.
 */
export interface ClubbedGroupToggleState {
  isGroupExpanded: boolean;
  expandedCommandIds: Set<string>;
}

export function createClubbedGroupState(defaultGroupExpanded = false): ClubbedGroupToggleState {
  return {
    isGroupExpanded: defaultGroupExpanded,
    expandedCommandIds: new Set<string>(),
  };
}

export function toggleClubbedGroup(state: ClubbedGroupToggleState): ClubbedGroupToggleState {
  return {
    ...state,
    isGroupExpanded: !state.isGroupExpanded,
  };
}

export function toggleClubbedCommand(state: ClubbedGroupToggleState, commandId: string): ClubbedGroupToggleState {
  const next = new Set(state.expandedCommandIds);
  if (next.has(commandId)) {
    next.delete(commandId);
  } else {
    next.add(commandId);
  }
  return {
    ...state,
    expandedCommandIds: next,
  };
}

/**
 * Computes whether the terminal capture pane should auto-expand or auto-collapse,
 * while respecting manual user overrides.
 */
export function computeAutoStartupPaneState(params: {
  prevStatus: string;
  runtimeStatus: string;
  userManuallyToggled: boolean;
  currentExpanded: boolean;
  isStarting?: boolean;
  isLive?: boolean;
}): { isPaneExpanded: boolean; userManuallyToggled: boolean } {
  const currentStatusNorm = (params.runtimeStatus || '').toLowerCase();
  const isStarting =
    params.isStarting !== undefined
      ? params.isStarting
      : currentStatusNorm === 'starting' || currentStatusNorm === 'launching' || currentStatusNorm === 'booting';
  const isLive =
    params.isLive !== undefined
      ? params.isLive
      : currentStatusNorm === 'running' || currentStatusNorm === 'live' || currentStatusNorm === 'ready';

  let userManuallyToggled = params.userManuallyToggled;
  let isPaneExpanded = params.currentExpanded;

  if (isStarting) {
    if (params.prevStatus !== params.runtimeStatus) {
      userManuallyToggled = false;
    }
    if (!userManuallyToggled) {
      isPaneExpanded = true;
    }
  } else if (isLive) {
    if (!userManuallyToggled) {
      isPaneExpanded = false;
    }
  }

  return { isPaneExpanded, userManuallyToggled };
}
