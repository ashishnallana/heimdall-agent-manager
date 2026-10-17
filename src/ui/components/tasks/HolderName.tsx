import React from 'react';
import { useFetchAgentInstanceQuery } from '../../api/endpoints/agents';
import { GENERIC_AGENT_LABEL, type TaskNames } from './taskNames';

/**
 * The name of the agent instance holding a lease, never its raw id.
 *
 * names.instance() covers chain members and agents known from lease events. A
 * fleet-spawned holder that is neither is fetched here (one cached RTK query
 * per distinct instance, the same pattern as InstanceIdLink), then named by its
 * display name or its agent. The id stays available on hover only.
 */
export function HolderName({ instanceId, names, className }: { instanceId: string; names: TaskNames; className?: string }) {
  const id = String(instanceId || '').trim();
  const known = id ? names.instance(id) : null;
  const { data } = useFetchAgentInstanceQuery({ instanceId: id }, { skip: !id || Boolean(known) });
  const inst: any = data?.instance || null;
  const fetchedAgentId = String(inst?.agent_id || inst?.agentId || '');
  const label =
    known ||
    String(inst?.display_name || inst?.displayName || '').trim() ||
    (fetchedAgentId ? names.agent(fetchedAgentId) : '') ||
    GENERIC_AGENT_LABEL;
  return (
    <span className={className} title={id || undefined}>
      {label}
    </span>
  );
}

export default HolderName;
