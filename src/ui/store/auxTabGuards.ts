import type { AuxContent } from './auxTabId';

/**
 * Chain-participant guard for aux tabs that target another agent.
 *
 * - `subagentChat`: only participants of the OWNING agent's task chain (in
 *   split view the owner is the focused agent), never the owner itself (it is
 *   already in Main), and only once the participant list is known.
 * - `agentPty`: inside a chain, only participants (not blocked while members
 *   load, matching the pre-existing workbench guard); outside a chain, only
 *   the owner agent.
 * - Everything else is always allowed.
 */
export interface AuxContentGuardContext {
  ownerAgentId?: string | null;
  chainId?: string | null;
  /** Chain participant agent instance ids; null/empty while not loaded. */
  participantIds?: ReadonlySet<string> | null;
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
