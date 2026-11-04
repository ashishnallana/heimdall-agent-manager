// Pure rules for the Create Chain modal, kept out of the component so they can be
// tested without React.
//
// A ticket chain's project is the project of its coordinator instance (the hub
// derives chain project grouping from it). A self-managed chain has no coordinator,
// so it cannot carry a project, and POST /api/v1/task-chains rejects project_id
// without coordinator_agent_id (400). The modal blocks that combination up front.

export type CreateChainKind = 'ticket' | 'workflow';

export const PROJECT_NEEDS_COORDINATOR_MESSAGE =
  'A project is set by the chain coordinator. Choose a coordinator agent, or set Project to Unassigned for a self-managed chain.';

// Returns the reason the form cannot be submitted as is, or '' when it can.
export function createChainFormProblem(
  kind: CreateChainKind,
  projectId: string,
  coordinatorAgentId: string,
): string {
  if (kind === 'ticket' && projectId.trim() !== '' && coordinatorAgentId.trim() === '') {
    return PROJECT_NEEDS_COORDINATOR_MESSAGE;
  }
  return '';
}

// Words a rejected create for the modal. RTK Query mutations here reject with
// { status: 'CUSTOM_ERROR', error: '<hub message>' }; anything else falls back to
// its message or a generic sentence.
export function createChainErrorMessage(err: unknown): string {
  const fallback = 'Could not create the chain.';
  if (!err) return fallback;
  if (typeof err === 'string') return err.trim() || fallback;
  if (typeof err === 'object') {
    const e = err as { error?: unknown; message?: unknown; data?: any };
    if (typeof e.error === 'string' && e.error.trim()) return e.error.trim();
    const dataMsg = e.data?.error?.message ?? e.data?.message;
    if (typeof dataMsg === 'string' && dataMsg.trim()) return dataMsg.trim();
    if (typeof e.message === 'string' && e.message.trim()) return e.message.trim();
  }
  return fallback;
}
