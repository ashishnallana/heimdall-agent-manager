/**
 * Pure counting rules behind the global status bar's v1 modules (REQ-BAR-2).
 * Kept free of React and RTK Query so tests can execute them directly.
 */
import type { LiveProject } from '../../../api/endpoints/agentsLive';
import type { ShellSession } from '../../../api/endpoints/shells';
import { isLiveRuntimeStatus } from '../../agents/agentModel';

/**
 * Live agent instances across every project. A cross-project chain lists an agent
 * under its own project, so ids are de-duplicated rather than summed per chain.
 */
export function countRunningInstances(projects: readonly LiveProject[] | null | undefined): number {
  const ids = new Set<string>();
  for (const project of projects || []) {
    for (const chain of project.chains || []) {
      for (const agent of chain.liveAgents || []) {
        if (agent.agentInstanceId && isLiveRuntimeStatus(agent.runtimeStatus)) ids.add(agent.agentInstanceId);
      }
    }
  }
  return ids.size;
}

/** A shell that is serving a port the hub can tunnel to the user. */
export function isPreviewSession(session: ShellSession): boolean {
  return session.kind === 'server' && Number(session.server_port) > 0;
}

export type ShellCounts = { shells: number; previews: number; capped: boolean };

/**
 * Counts from one page of LIVE shell sessions. `capped` means the page was full and
 * more exist, so the bar renders "N+" instead of a number it cannot vouch for.
 */
export function countShells(sessions: readonly ShellSession[] | null | undefined, hasMore = false): ShellCounts {
  const list = sessions || [];
  return { shells: list.length, previews: list.filter(isPreviewSession).length, capped: hasMore };
}

export function formatCount(count: number, capped = false): string {
  return capped ? `${count}+` : String(count);
}
