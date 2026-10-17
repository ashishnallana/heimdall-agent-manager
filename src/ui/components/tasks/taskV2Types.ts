import { TaskWire } from '../../api/taskWire';

export type TaskStateV2 = 'in_progress' | 'in_review' | 'ready' | 'backlog' | 'done' | 'cancelled';

export const TASK_STATES_ORDER: TaskStateV2[] = [
  'in_progress',
  'in_review',
  'ready',
  'backlog',
  'done',
  'cancelled',
];

export const TASK_STATE_LABELS: Record<string, string> = {
  backlog: 'Backlog',
  ready: 'Ready',
  in_progress: 'In progress',
  in_review: 'In review',
  done: 'Done',
  cancelled: 'Cancelled',
};

export const TASK_STATE_COLORS: Record<string, string> = {
  backlog: '#555555',
  ready: '#0099ff',
  in_progress: '#d2a965',
  in_review: '#f59e0b',
  done: '#22c55e',
  cancelled: '#333333',
};

export interface TaskBadge {
  label: string;
  tone?: 'accent' | 'ok' | 'warn' | 'danger' | 'info' | 'neutral';
  title?: string;
}

export function normalizeTaskState(raw: string | undefined): TaskStateV2 {
  const s = String(raw || '').toLowerCase().trim();
  if (s === 'in_progress' || s === 'running' || s === 'working') return 'in_progress';
  if (s === 'in_review' || s === 'review' || s === 'under_review') return 'in_review';
  if (s === 'ready' || s === 'published' || s === 'unclaimed') return 'ready';
  if (s === 'done' || s === 'completed' || s === 'complete' || s === 'finished') return 'done';
  if (s === 'cancelled' || s === 'canceled' || s === 'archived') return 'cancelled';
  return 'backlog';
}

export function getTaskBadges(task: TaskWire, _chainFleets?: any[], nowMs: number = Date.now()): TaskBadge[] {
  const badges: TaskBadge[] = [];
  const state = normalizeTaskState(task.state);
  const lease = (task.leases && task.leases.length > 0) ? task.leases[0] : null;

  if (task.kind === 'gate') {
    badges.push({ label: 'gate', tone: 'accent', title: 'Human gate stage' });
  }

  if (state === 'in_progress' && lease) {
    const expiresMs = lease.expires_at ? new Date(lease.expires_at).getTime() : (nowMs + 15 * 60000);
    const leftMins = Math.max(0, Math.round((expiresMs - nowMs) / 60000));
    const holder = lease.holder_instance_id ? lease.holder_instance_id.split('_').slice(-1)[0] : 'agent';
    const tone = leftMins <= 3 ? 'danger' : leftMins <= 5 ? 'warn' : 'accent';
    badges.push({
      label: `${holder} · ${leftMins}m left`,
      tone,
      title: `Lease expires in ${leftMins} minutes (held by ${lease.holder_instance_id})`,
    });
    if (lease.bridge_id || task.bridge_id) {
      badges.push({
        label: `bridge ${lease.bridge_id || task.bridge_id}`,
        tone: 'neutral',
        title: `Bridge: ${lease.bridge_id || task.bridge_id}`,
      });
    }
  } else if (task.bridge_id) {
    badges.push({
      label: `bridge ${task.bridge_id}`,
      tone: 'neutral',
      title: `Pinned bridge: ${task.bridge_id}`,
    });
  }

  if (task.attempt_no > 1) {
    badges.push({
      label: `attempt ${task.attempt_no}/5`,
      tone: task.attempt_no >= 4 ? 'warn' : 'neutral',
      title: `Attempt ${task.attempt_no} of 5`,
    });
  }

  const reviewRoles = task.brief?.review_roles || [];
  if (state === 'in_review') {
    if (task.requires_user_approval) {
      badges.push({
        label: reviewRoles.length ? `${reviewRoles.length} reviews + you` : 'awaiting you',
        tone: 'accent',
        title: 'Awaiting review decision',
      });
    } else if (reviewRoles.length > 0) {
      badges.push({
        label: `reviews: ${reviewRoles.join(', ')}`,
        tone: 'info',
        title: 'Waiting for reviewer role decisions',
      });
    }
  }

  if (task.blocked_on) {
    badges.push({
      label: 'Blocked on you',
      tone: 'danger',
      title: String(task.blocked_on.reason || 'Blocked waiting on human answer'),
    });
  }

  if (state === 'done') {
    badges.push({
      label: 'Verified',
      tone: 'ok',
      title: 'Task completed and verified',
    });
  }

  return badges;
}

export function getTaskStatusLines(task: TaskWire, _chainFleets?: any[], nowMs: number = Date.now()): [string, string] {
  const state = normalizeTaskState(task.state);
  const lease = (task.leases && task.leases.length > 0) ? task.leases[0] : null;

  if (state === 'in_progress') {
    if (lease) {
      const expiresMs = lease.expires_at ? new Date(lease.expires_at).getTime() : (nowMs + 15 * 60000);
      const hardMs = lease.hard_deadline_at ? new Date(lease.hard_deadline_at).getTime() : (nowMs + 60 * 60000);
      const leftMins = Math.max(0, Math.round((expiresMs - nowMs) / 60000));
      const hardMins = Math.max(0, Math.round((hardMs - nowMs) / 60000));
      const holder = lease.holder_instance_id || 'worker';
      return [
        `${holder} is working · attempt ${task.attempt_no || 1}/5 · lease ${leftMins} min left`,
        `hard cap in ${hardMins} min · auto-extends on active agent calls`,
      ];
    }
    return [
      `Worker assigned · attempt ${task.attempt_no || 1}/5`,
      'Agent process is executing the brief',
    ];
  }

  if (state === 'in_review' && task.kind === 'gate') {
    return [
      'Gate — waiting on your decision',
      'Downstream stages stay unmaterialised until approved',
    ];
  }

  if (state === 'in_review') {
    const roles = task.brief?.review_roles || [];
    const rolesStr = roles.join(', ');
    if (task.requires_user_approval) {
      return [
        roles.length > 0
          ? `Waiting on ${rolesStr} and you`
          : 'Waiting on your approval',
        `Attempt ${task.attempt_no || 1} submitted · author stopped, fresh context on changes`,
      ];
    }
    return [
      `Waiting on reviewer roles: ${rolesStr || 'reviewers'}`,
      `Attempt ${task.attempt_no || 1} submitted · review in progress`,
    ];
  }

  if (state === 'ready') {
    const readySinceMs = task.ready_since ? new Date(task.ready_since).getTime() : null;
    const unclaimedMins = readySinceMs ? Math.max(0, Math.round((nowMs - readySinceMs) / 60000)) : 0;
    return [
      'Ready — will be granted to the next free worker',
      unclaimedMins > 0 ? `unclaimed for ${unclaimedMins} min` : 'all dependencies done',
    ];
  }

  if (state === 'backlog') {
    if (task.blocked_on) {
      return [
        `Blocked on you — ${task.blocked_on.reason || 'Waiting for human input'}`,
        'Nothing will move until you answer',
      ];
    }
    const deps = task.depends_on || [];
    return [
      'Waiting for dependencies',
      deps.length > 0 ? `needs ${deps.join(', ')}` : 'draft / awaiting publish',
    ];
  }

  if (state === 'done') {
    return [
      'Done · completed and verified',
      `${task.attempt_no || 1} attempt${task.attempt_no === 1 ? '' : 's'}`,
    ];
  }

  return ['Cancelled', 'Task was cancelled'];
}

export interface TaskPeople {
  // assignee: brief.assignee — the worker agent TEMPLATE the task is pinned to
  // ('' = any worker in the fleet). The matcher resolves it to an instance.
  assignee: string;
  // workers: agent ids that can take the work lease (the assignee alone when
  // pinned, otherwise every fleet row with the worker role).
  workers: string[];
  // reviewers: agent ids of fleet rows holding one of brief.review_roles.
  reviewers: string[];
  // reviewersByRole: brief.review_roles in order → agent ids of the rows holding
  // that role (every one of them must approve; [] = role not covered).
  reviewersByRole: { role: string; agents: string[] }[];
  // holder: instance currently holding the work lease ('' when none).
  holder: string;
  userApproval: boolean;
}

function fleetRoles(f: any): string[] {
  return Array.isArray(f?.roles) ? f.roles.map(String) : [];
}

export function getTaskPeople(task: TaskWire, chainFleets: any[] = []): TaskPeople {
  const assignee = String(task.brief?.assignee || '').trim();
  const fleets = Array.isArray(chainFleets) ? chainFleets : [];
  const fleetAgent = (f: any) => String(f?.agent_id || f?.agentId || '');
  const workers = assignee
    ? [assignee]
    : fleets.filter((f) => fleetRoles(f).includes('worker')).map(fleetAgent).filter(Boolean);
  const roles = task.brief?.review_roles || [];
  const reviewers = fleets
    .filter((f) => fleetRoles(f).some((r) => roles.includes(r)))
    .map(fleetAgent)
    .filter(Boolean);
  const work = (task.leases || []).find((l: any) => (l?.kind || 'work') === 'work');
  const reviewersByRole = roles.map((role) => ({
    role,
    agents: fleets.filter((f) => fleetRoles(f).includes(role)).map(fleetAgent).filter(Boolean),
  }));
  return {
    assignee,
    workers: Array.from(new Set(workers)),
    reviewers: Array.from(new Set(reviewers)),
    reviewersByRole,
    holder: String(work?.holder_instance_id || ''),
    userApproval: Boolean(task.requires_user_approval),
  };
}

// resolveSelectedTaskId: the detail view only opens for a task of THIS chain. A
// selection left over from another chain (or a deleted task) falls back to the
// board instead of rendering a "No goal defined" stub. While the chain's tasks
// are still loading the selection is kept so deep links survive.
export function resolveSelectedTaskId(selectedTaskId: string | null | undefined, tasks: TaskWire[], loaded: boolean): string | null {
  if (!selectedTaskId) return null;
  if (!loaded) return selectedTaskId;
  return tasks.some((t) => t.task_id === selectedTaskId) ? selectedTaskId : null;
}
