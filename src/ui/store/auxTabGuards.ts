import type { AuxContent } from './auxTabId';

/**
 * Chain-participant guard for aux tabs that target another agent.
 *
 * - `subagentChat`: only participants of the OWNING (focused) agent's task chain, never the owner itself (it is
 *   already in Main), and only once the participant list is known.
 * - `agentPty`: inside a chain, only participants (not blocked while members
 *   load, matching the pre-existing workbench guard); outside a chain, only
 *   the owner agent.
 * - `files` / `vcs` (the Project Explorer): only when the per-user project_vcs
 *   experiment is enabled; loading, disabled and failed flags all refuse.
 * - Everything else is always allowed.
 */
export interface AuxContentGuardContext {
  ownerAgentId?: string | null;
  chainId?: string | null;
  /** Chain participant agent instance ids; null/empty while not loaded. */
  participantIds?: ReadonlySet<string> | null;
  /** True only when the project_vcs experiment resolved to enabled. */
  explorerEnabled?: boolean;
}

/** Aux tab content types that make up the Project Explorer (REQ-EXP-GATE-2). */
export function isExplorerAuxContent(content: Pick<AuxContent, 'type'>): boolean {
  return content.type === 'files' || content.type === 'vcs';
}

/** Drops restored explorer tabs from a strip unless the explorer is enabled. */
export function filterExplorerAuxTabs<T extends { content: Pick<AuxContent, 'type'> }>(
  tabs: readonly T[],
  explorerEnabled: boolean,
): T[] {
  return explorerEnabled ? [...tabs] : tabs.filter((tab) => !isExplorerAuxContent(tab.content));
}

export function chainParticipantIdsFromMembers(
  members: ReadonlyArray<any> | null | undefined,
): Set<string> {
  const ids = new Set<string>();
  for (const m of members || []) {
    const id = String(m?.agentInstanceId || m?.agent_instance_id || '').trim();
    if (id) ids.add(id);
  }
  return ids;
}

export function isAuxContentAllowed(
  content: AuxContent,
  ctx: AuxContentGuardContext,
): boolean {
  const owner = String(ctx.ownerAgentId || '').trim();
  const chainId = String(ctx.chainId || '').trim();
  const participants = ctx.participantIds && ctx.participantIds.size > 0 ? ctx.participantIds : null;
  if (isExplorerAuxContent(content)) return ctx.explorerEnabled === true;
  if (content.type === 'subagentChat') {
    const target = String(content.agentInstanceId || '').trim();
    if (!target || target === owner || !chainId || !participants) return false;
    return participants.has(target);
  }
  if (content.type === 'agentPty') {
    const target = String(content.agentInstanceId || '').trim();
    if (!target) return false;
    if (!chainId) return target === owner;
    if (!participants) return true;
    return target === owner || participants.has(target);
  }
  return true;
}

/**
 * The active tab a dock may show given explorer access. A chain-less strip seeds
 * Files as its derived (never stored) default; while the explorer is not enabled
 * that seed falls back to the launcher (null). A stored, restored explorer tab
 * stays active so the dock can explain why it is unavailable.
 */
export function explorerSafeActiveTab<T extends { id: string; content: Pick<AuxContent, 'type'> }>(
  active: T | null,
  storedTabs: readonly { id: string }[],
  explorerEnabled: boolean,
): T | null {
  if (!active || explorerEnabled || !isExplorerAuxContent(active.content)) return active;
  return storedTabs.some((tab) => tab.id === active.id) ? active : null;
}
