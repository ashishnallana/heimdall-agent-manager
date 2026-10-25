import { useFetchAgentInstanceQuery } from '../../api/endpoints/agents';
import { GENERIC_AGENT_LABEL, unknownReviewerLabel, type TaskNames } from './taskNames';

/**
 * The display name of a reviewer/participant id (`agt_`, `inst_` or `user`),
 * REQ-TV2-6. names.participant() answers from what the chain view already
 * loaded (members, lease_granted facts, identities). An instance it cannot
 * name is looked up (one cached RTK query per distinct instance, as
 * <HolderName>) and named after its durable agent, so a stopped or historical
 * instance keeps its name. Anything still unnamed is "Unknown reviewer (<id>)",
 * never blank or a generic "An agent".
 */
export function useParticipantLabel(id: string, names: TaskNames): string {
  const v = String(id || '').trim();
  const known = v ? names.participant(v) : null;
  const lookup = !known && v.startsWith('inst_');
  const { data } = useFetchAgentInstanceQuery({ instanceId: v }, { skip: !lookup });
  if (known) return known;
  if (lookup) {
    const inst: any = data?.instance || null;
    const agentId = String(inst?.agent_id || inst?.agentId || '').trim();
    const agentName = agentId ? names.agent(agentId) : '';
    if (agentName && agentName !== GENERIC_AGENT_LABEL) return agentName;
    const display = String(inst?.display_name || inst?.displayName || '').trim();
    if (display) return display;
  }
  return unknownReviewerLabel(v);
}

/** useParticipantLabel() as an inline element, with the raw id on hover only. */
export function ParticipantName({ id, names, className }: { id: string; names: TaskNames; className?: string }) {
  const label = useParticipantLabel(id, names);
  return (
    <span className={className} title={id}>
      {label}
    </span>
  );
}

export default ParticipantName;
