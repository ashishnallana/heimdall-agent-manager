import { useEffect, useMemo } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { agentsApi, useFetchAgentInstanceQuery } from '../../api/endpoints/agents';
import { GENERIC_AGENT_LABEL, unknownReviewerLabel, withInstanceAgents, type TaskNames } from './taskNames';

function instanceAgentId(inst: any): string {
  return String(inst?.agent_id || inst?.agentId || '').trim();
}

/**
 * `names` extended with the durable agent of every `inst_` id in `ids` that it
 * cannot map yet (REQ-TV2-6). Each such instance is looked up (the same cached
 * RTK query useParticipantLabel uses), so a stopped or historical instance in
 * an assignment matches its agent's vote and is listed once, not only named.
 * Use the result wherever votes are matched or reviewers deduplicated.
 */
export function useLookupNames(names: TaskNames, ids: readonly string[]): TaskNames {
  const dispatch = useDispatch<any>();
  const unmapped = useMemo(() => {
    const out = new Set<string>();
    for (const raw of ids) {
      const id = String(raw || '').trim();
      if (id.startsWith('inst_') && names.durableId(id).startsWith('inst_')) out.add(id);
    }
    return Array.from(out).sort();
  }, [ids, names]);
  const key = unmapped.join(',');

  useEffect(() => {
    if (!key) return undefined;
    const subs = key.split(',').map((instanceId) => dispatch(agentsApi.endpoints.fetchAgentInstance.initiate({ instanceId })));
    return () => subs.forEach((s: any) => s?.unsubscribe?.());
  }, [dispatch, key]);

  // A string selector keeps the snapshot stable across unrelated store updates.
  const factsKey = useSelector((state: any) =>
    unmapped
      .map((instanceId) => {
        const agentId = instanceAgentId(agentsApi.endpoints.fetchAgentInstance.select({ instanceId })(state)?.data?.instance);
        return agentId ? `${instanceId}=${agentId}` : '';
      })
      .filter(Boolean)
      .join(','),
  );

  return useMemo(() => {
    if (!factsKey) return names;
    const facts: Record<string, string> = {};
    for (const pair of factsKey.split(',')) {
      const [inst, agentId] = pair.split('=');
      facts[inst] = agentId;
    }
    return withInstanceAgents(names, facts);
  }, [names, factsKey]);
}

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
    const agentId = instanceAgentId(inst);
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
