import type { TaskWire } from '../../api/taskWire';

/**
 * Human-readable names for the ids a task screen would otherwise print raw
 * (plan REQ-UI-4). Built once per chain view from data it already loads and
 * passed down, so cards, the board, the pipeline and the detail view resolve
 * names the same way.
 *
 * Every method is synchronous. A lease holder that is not a chain member and
 * not otherwise known resolves through <HolderName>, which fetches the instance
 * (a hook, so it cannot live in here).
 */
export interface TaskNames {
  /** Task title, or "Untitled task". */
  task(taskId: string): string;
  /** Agent (template) name, or a readable fallback derived from the slug. */
  agent(agentId: string): string;
  /** Bridge label, or "unknown bridge". */
  bridge(bridgeId: string): string;
  /** Instance display name from chain members or a known agent; null when unknown. */
  instance(instanceId: string): string | null;
  /**
   * The durable id a participant id stands for: an `inst_` id maps to its
   * agent's `agt_` id when known (members, lease_granted facts, instance
   * lookups); `agt_` ids and `user` are returned as they are.
   */
  durableId(id: string): string;
  /**
   * The single reviewer/participant resolver (REQ-TV2-6). Accepts `agt_`,
   * `inst_` and `user` ids and names the durable agent (an instance resolves
   * through chain members → lease_granted facts → known instances to its
   * agent's name). Null when nothing names it, so a caller can still look the
   * instance up; use participantLabel() for the explicit fallback.
   */
  participant(id: string): string | null;
}

export interface TaskNameSources {
  tasks?: Pick<TaskWire, 'task_id' | 'title'>[];
  members?: { agentInstanceId?: string; agent_instance_id?: string; agentId?: string; agent_id?: string; displayName?: string; display_name?: string }[];
  bridges?: { id?: string; bridge_id?: string; bridgeId?: string; label?: string; name?: string; machine_hostname?: string }[];
  identities?: { agent_id?: string; agentId?: string; id?: string; name?: string; display_name?: string }[];
  /** Extra instance → agent_id facts, e.g. from lease_granted event payloads. */
  instanceAgents?: Record<string, string>;
  /** Agent instances (running or stopped) from an agents/instances lookup. */
  instances?: { agent_instance_id?: string; agentInstanceId?: string; instance_id?: string; id?: string; agent_id?: string; agentId?: string }[];
}

export const GENERIC_AGENT_LABEL = 'Agent';

/** The explicit fallback for a participant id nothing can name (REQ-TV2-6). */
export function unknownReviewerLabel(id: string): string {
  const v = str(id);
  return v ? `Unknown reviewer (${v})` : 'Unknown reviewer';
}

/** Label for the user participant. */
export const USER_PARTICIPANT_LABEL = 'you';

function isUserId(id: string): boolean {
  return id.toLowerCase() === 'user';
}

function str(v: unknown): string {
  return typeof v === 'string' ? v.trim() : '';
}

/** "agt_backend-dev" → "Backend dev"; opaque generated ids fall back to "Agent". */
export function readableAgentFallback(agentId: string): string {
  const raw = str(agentId).replace(/^agt_/, '');
  // Generated ids (agt_18df385deeb91f7c) carry no meaning; never show them.
  if (!raw || /^[0-9a-f]{12,}$/i.test(raw)) return GENERIC_AGENT_LABEL;
  const words = raw.replace(/[_-]+/g, ' ').trim();
  return words.charAt(0).toUpperCase() + words.slice(1);
}

export function buildTaskNames(src: TaskNameSources): TaskNames {
  const taskTitles = new Map<string, string>();
  for (const t of src.tasks || []) if (t?.task_id) taskTitles.set(t.task_id, str(t.title));

  const agentNames = new Map<string, string>();
  for (const a of src.identities || []) {
    const id = str(a?.agent_id) || str(a?.agentId) || str(a?.id);
    const name = str(a?.name) || str(a?.display_name);
    if (id && name) agentNames.set(id, name);
  }

  const bridgeLabels = new Map<string, string>();
  for (const b of src.bridges || []) {
    const id = str(b?.bridge_id) || str(b?.bridgeId) || str(b?.id);
    const label = str(b?.label) || str(b?.name) || str(b?.machine_hostname);
    if (id && label) bridgeLabels.set(id, label);
  }

  const instanceNames = new Map<string, string>();
  const instanceAgent = new Map<string, string>(Object.entries(src.instanceAgents || {}));
  for (const i of src.instances || []) {
    const inst = str(i?.agent_instance_id) || str(i?.agentInstanceId) || str(i?.instance_id) || str(i?.id);
    const agentId = str(i?.agent_id) || str(i?.agentId);
    if (inst && agentId && !instanceAgent.has(inst)) instanceAgent.set(inst, agentId);
  }
  for (const m of src.members || []) {
    const inst = str(m?.agentInstanceId) || str(m?.agent_instance_id);
    if (!inst) continue;
    const display = str(m?.displayName) || str(m?.display_name);
    if (display) instanceNames.set(inst, display);
    const agentId = str(m?.agentId) || str(m?.agent_id);
    if (agentId && !instanceAgent.has(inst)) instanceAgent.set(inst, agentId);
  }

  const agent = (agentId: string) => {
    const id = str(agentId);
    if (!id) return GENERIC_AGENT_LABEL;
    return agentNames.get(id) || readableAgentFallback(id);
  };

  const durableId = (raw: string) => {
    const id = str(raw);
    if (!id.startsWith('inst_')) return id;
    return instanceAgent.get(id) || id;
  };

  const names: TaskNames = {
    task: (taskId) => taskTitles.get(str(taskId)) || 'Untitled ticket',
    agent,
    bridge: (bridgeId) => bridgeLabels.get(str(bridgeId)) || 'unknown bridge',
    instance: (instanceId) => {
      const id = str(instanceId);
      if (!id) return null;
      // Holder chain (plan REQ-UI-4): member display name → member/event agent → (HolderName fetch).
      const display = instanceNames.get(id);
      if (display) return display;
      const agentId = instanceAgent.get(id);
      if (agentId && agentNames.has(agentId)) return agentNames.get(agentId)!;
      return null;
    },
    durableId,
    participant: (raw) => participantName(names, raw),
  };
  return names;
}

/**
 * The resolution order behind TaskNames.participant(), shared by every names
 * object (withInstanceAgents included): user → you; an instance → its durable
 * agent's name, else its member display name; an agent → its name or a
 * readable slug. Opaque ids that nothing names resolve to null.
 */
function participantName(names: Pick<TaskNames, 'agent' | 'instance' | 'durableId'>, raw: string): string | null {
  const id = str(raw);
  if (!id) return null;
  if (isUserId(id)) return USER_PARTICIPANT_LABEL;
  const durable = names.durableId(id);
  if (durable && !durable.startsWith('inst_')) {
    const name = names.agent(durable);
    if (name !== GENERIC_AGENT_LABEL) return name;
  }
  if (id.startsWith('inst_')) return names.instance(id);
  return null;
}

/** participant() with the explicit "Unknown reviewer (<id>)" fallback; never blank or "An agent". */
export function participantLabel(names: TaskNames, id: string): string {
  return names.participant(id) || unknownReviewerLabel(id);
}

/** instance_id → agent_id facts carried by lease_granted events (holder chain step 4). */
export function instanceAgentsFromEvents(events: { kind?: string; payload?: any }[] = []): Record<string, string> {
  const out: Record<string, string> = {};
  for (const ev of events) {
    if (ev?.kind !== 'lease_granted') continue;
    const inst = str(ev.payload?.instance_id);
    const agentId = str(ev.payload?.agent_id);
    if (inst && agentId) out[inst] = agentId;
  }
  return out;
}

/** A names object that resolves nothing (tests and screens rendered outside a chain). */
export const EMPTY_TASK_NAMES: TaskNames = buildTaskNames({});

/**
 * Adds instance → agent facts (e.g. from lease_granted events) to an existing
 * names object. An instance still resolves to null when the agent itself has no
 * readable name, so <HolderName> can fetch the instance instead.
 */
export function withInstanceAgents(base: TaskNames, instanceAgents: Record<string, string>): TaskNames {
  if (!instanceAgents || Object.keys(instanceAgents).length === 0) return base;
  const names: TaskNames = {
    ...base,
    instance: (instanceId) => {
      const known = base.instance(instanceId);
      if (known) return known;
      const agentId = instanceAgents[str(instanceId)];
      if (!agentId) return null;
      const name = base.agent(agentId);
      return name === GENERIC_AGENT_LABEL ? null : name;
    },
    durableId: (raw) => {
      const fromBase = base.durableId(raw);
      if (!fromBase.startsWith('inst_')) return fromBase;
      return instanceAgents[str(raw)] || fromBase;
    },
    participant: (raw) => participantName(names, raw),
  };
  return names;
}
