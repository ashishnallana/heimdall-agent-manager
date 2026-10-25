/**
 * Main pane targets (REQ-TV2-7).
 *
 * A Main pane addresses either a concrete agent instance or a task chain's
 * CURRENT coordinator conversation:
 *
 *   { kind: 'agent', agentInstanceId }   -> target id `<inst>` (also `sh_…`, `_new`)
 *   { kind: 'chain_coordinator', chainId } -> target id `chain:<chain_id>`
 *
 * The target id is the pane's identity everywhere a string key is needed: the
 * URL pane set (`#/conversations/chain:<id>+<inst>?focused=chain:<id>`), the
 * leaf dedupe rule (one leaf per TARGET), split-group keys and the aux strip
 * key. A chain target is resolved to its coordinator instance at render time
 * (GET /task-chains/{id}/conversation), so it survives coordinator replacement.
 * Bare instance ids stay valid agent targets, so legacy links keep working.
 */

export const CHAIN_TARGET_PREFIX = 'chain:';

export type PaneTarget =
  | { kind: 'agent'; agentInstanceId: string }
  | { kind: 'chain_coordinator'; chainId: string };

/** The target id for a chain's coordinator conversation, or '' without a chain id. */
export function chainTargetId(chainId: string | null | undefined): string {
  const id = String(chainId || '').trim();
  return id ? `${CHAIN_TARGET_PREFIX}${id}` : '';
}

/**
 * The route of a chain's conversation: `/conversations/chain:<chain_id>`. Every
 * chain-entry link uses it, never the coordinator instance id, so a pane keeps
 * its chain through coordinator replacement and two chains are two panes.
 */
export function chainConversationRoute(chainId: string): string {
  return `/conversations/${chainTargetId(encodeURIComponent(String(chainId || '').trim()))}`;
}

export function isChainTargetId(id: string | null | undefined): id is string {
  return Boolean(id && id.startsWith(CHAIN_TARGET_PREFIX) && id.length > CHAIN_TARGET_PREFIX.length);
}

/** The chain id of a `chain:<id>` target, else ''. */
export function chainIdFromTargetId(id: string | null | undefined): string {
  return isChainTargetId(id) ? id.slice(CHAIN_TARGET_PREFIX.length) : '';
}

export function parsePaneTargetId(id: string): PaneTarget {
  const chainId = chainIdFromTargetId(id);
  return chainId ? { kind: 'chain_coordinator', chainId } : { kind: 'agent', agentInstanceId: id };
}

export function paneTargetId(target: PaneTarget): string {
  return target.kind === 'chain_coordinator' ? chainTargetId(target.chainId) : target.agentInstanceId;
}

/**
 * The agent instance a target shows: itself for an agent target, the resolved
 * coordinator for a chain target ('' until resolved / when the chain has none).
 */
export function resolvePaneTargetAgent(id: string, chainCoordinators: Record<string, string> = {}): string {
  const chainId = chainIdFromTargetId(id);
  if (!chainId) return id;
  return chainCoordinators[chainId] || '';
}
