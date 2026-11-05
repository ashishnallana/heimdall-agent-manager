import { useMemo } from 'react';
import { useFetchTaskChainDetailQuery } from '../../api/endpoints/tasks';
import { useGetTaskChainFleetsQuery } from '../../api/endpoints/taskChains';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';
import { useGetAgentsLiveQuery, type LiveChain } from '../../api/endpoints/agentsLive';
import type { TaskWire } from '../../api/taskWire';
import { buildTaskNames, type TaskNames } from './taskNames';
import { buildFleetMachines, ticketKeys, type FleetMachine } from './ticketModel';

export interface ChainTickets {
  chain: any;
  /** Every task of the chain, workflow stages included. */
  tasks: TaskWire[];
  /** The chain's tickets (no workflow-run stages). */
  tickets: TaskWire[];
  keys: Map<string, string>;
  names: TaskNames;
  fleets: any[];
  bridges: any[];
  machines: FleetMachine[];
  coordinatorInstanceId: string;
  isLoading: boolean;
  error: unknown;
}

/**
 * The chain data both ticket views read (spec "Data: API calls"): chain detail,
 * fleets, live agents, agent names and bridges. All of it is RTK cache kept
 * current by the user WebSocket (wsInvalidation.ts); nothing here polls.
 */
export function useChainTickets(chainId: string): ChainTickets {
  const skip = !chainId;
  const { data: chainData, isLoading, error } = useFetchTaskChainDetailQuery({ chainId }, { skip });
  const { data: fleetsData } = useGetTaskChainFleetsQuery({ chainId }, { skip });
  const { data: bridgesData } = useListBridgesQuery();
  const { data: identitiesData } = useListAgentIdentitiesQuery();
  const { data: liveData } = useGetAgentsLiveQuery();

  const chain: any = chainData?.chain || null;
  const tasks: TaskWire[] = useMemo(() => (Array.isArray(chain?.tasks) ? chain.tasks : []), [chain?.tasks]);
  const fleets: any[] = useMemo(() => (Array.isArray(fleetsData) ? fleetsData : []), [fleetsData]);
  const bridges: any[] = useMemo(() => bridgesData?.bridges || [], [bridgesData]);
  const identities: any[] = useMemo(() => identitiesData?.agents || [], [identitiesData]);
  const members: any[] = useMemo(() => (Array.isArray(chain?.members) ? chain.members : []), [chain?.members]);
  const coordinatorInstanceId = String(chain?.coordinator_agent_instance_id || chain?.coordinatorAgentInstanceId || '');

  const liveChain: LiveChain | null = useMemo(() => {
    for (const p of liveData || []) for (const c of p.chains || []) if (c.chainId === chainId) return c;
    return null;
  }, [liveData, chainId]);

  const tickets = useMemo(() => tasks.filter((t) => !t.workflow_run_id), [tasks]);
  const keys = useMemo(() => ticketKeys(tasks), [tasks]);
  const names = useMemo(() => buildTaskNames({ tasks, members, bridges, identities }), [tasks, members, bridges, identities]);
  const machines = useMemo(
    () =>
      buildFleetMachines({
        tasks,
        members,
        fleets,
        bridges,
        live: liveChain,
        coordinatorInstanceId,
        keys,
        agentName: names.agent,
      }),
    [tasks, members, fleets, bridges, liveChain, coordinatorInstanceId, keys, names],
  );

  return { chain, tasks, tickets, keys, names, fleets, bridges, machines, coordinatorInstanceId, isLoading, error };
}
