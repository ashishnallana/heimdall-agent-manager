import { TaskWire, type TaskLeaseWire } from '../../api/taskWire';
import { EMPTY_TASK_NAMES, GENERIC_AGENT_LABEL, type TaskNames } from './taskNames';

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
  /** What the badge is about, so views can drop ones they show elsewhere. */
  kind?: 'gate' | 'lease' | 'bridge' | 'attempt' | 'review' | 'blocked' | 'verified' | 'merge';
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

export function getTaskBadges(task: TaskWire, _chainFleets?: any[], nowMs: number = Date.now(), names: TaskNames = EMPTY_TASK_NAMES): TaskBadge[] {
  const badges: TaskBadge[] = [];
  const state = normalizeTaskState(task.state);
  const lease = workLease(task);

  if (task.kind === 'gate') {
    badges.push({ kind: 'gate', label: 'gate', tone: 'accent', title: 'Human gate stage' });
  }

  if (state === 'in_progress' && lease) {
    const expiresMs = lease.expires_at ? new Date(lease.expires_at).getTime() : (nowMs + 15 * 60000);
    const leftMins = Math.max(0, Math.round((expiresMs - nowMs) / 60000));
    const holder = (lease.holder_instance_id && names.instance(lease.holder_instance_id)) || GENERIC_AGENT_LABEL;
    const tone = leftMins <= 3 ? 'danger' : leftMins <= 5 ? 'warn' : 'accent';
    badges.push({
      kind: 'lease',
      label: `${holder} · ${leftMins}m left`,
      tone,
      title: `Lease expires in ${leftMins} minutes (held by ${holder})`,
    });
    if (lease.bridge_id || task.bridge_id) {
      badges.push({
        kind: 'bridge',
        label: names.bridge(lease.bridge_id || task.bridge_id),
        tone: 'neutral',
        title: `Bridge: ${names.bridge(lease.bridge_id || task.bridge_id)}`,
      });
    }
  } else if (task.bridge_id) {
    badges.push({
      kind: 'bridge',
      label: names.bridge(task.bridge_id),
      tone: 'neutral',
      title: `Pinned bridge: ${names.bridge(task.bridge_id)}`,
    });
  }

  if (task.attempt_no > 1) {
    badges.push({
      kind: 'attempt',
      label: `attempt ${task.attempt_no}/5`,
      tone: task.attempt_no >= 4 ? 'warn' : 'neutral',
      title: `Attempt ${task.attempt_no} of 5`,
    });
  }

  const reviewRoles = task.brief?.review_roles || [];
  if (state === 'in_review') {
    if (task.requires_user_approval) {
      badges.push({
        kind: 'review',
        label: reviewRoles.length ? `${reviewRoles.length} reviews + you` : 'awaiting you',
        tone: 'accent',
        title: 'Awaiting review decision',
      });
    } else if (reviewRoles.length > 0) {
      badges.push({
        kind: 'review',
        label: `reviews: ${reviewRoles.join(', ')}`,
        tone: 'info',
        title: 'Waiting for reviewer role decisions',
      });
    }
  }

  if (task.blocked_on) {
    // Same rule as taskActions.blockedOnYou(): only a human/user blocker is on you.
    const waitingKind = String((task.blocked_on as any).kind || '');
    const onYou = !waitingKind || waitingKind === 'human' || waitingKind === 'user';
    badges.push({
      kind: 'blocked',
      label: onYou ? 'Blocked on you' : `Blocked: waiting on ${waitingKind.replace(/_/g, ' ')}`,
      tone: onYou ? 'danger' : 'warn',
      title: String(task.blocked_on.reason || (onYou ? 'Waiting for your answer' : 'Waiting on another task or system')),
    });
  }

  if (state === 'done') {
    badges.push({
      kind: 'verified',
      label: 'Verified',
      tone: 'ok',
      title: 'Task completed and verified',
    });
  }

  // Worktree merge-back of a done task (F5). A conflict already shows as blocked.
  const merge = task.merge;
  if (merge && merge.state === 'pending') {
    badges.push({ kind: 'merge', label: 'Merging…', tone: 'info', title: 'The task branch is being merged into its directory' });
  } else if (merge && merge.state === 'failed') {
    badges.push({ kind: 'merge', label: 'Merge failed – retrying', tone: 'warn', title: merge.detail ? `Merge did not run: ${merge.detail}. Retried when the bridge reconnects.` : 'Merge did not run; retried when the bridge reconnects.' });
  } else if (merge && merge.state === 'merged' && merge.head) {
    badges.push({ kind: 'merge', label: `Merged at ${merge.head.slice(0, 7)}`, tone: 'ok', title: `Merged${merge.detail ? ` (${merge.detail})` : ''} at ${merge.head}` });
  }

  return badges;
}

export function getTaskStatusLines(task: TaskWire, _chainFleets?: any[], nowMs: number = Date.now(), names: TaskNames = EMPTY_TASK_NAMES): [string, string] {
  const state = normalizeTaskState(task.state);
  const lease = workLease(task);

  if (state === 'in_progress') {
    if (lease) {
      const expiresMs = lease.expires_at ? new Date(lease.expires_at).getTime() : (nowMs + 15 * 60000);
      const hardMs = lease.hard_deadline_at ? new Date(lease.hard_deadline_at).getTime() : (nowMs + 60 * 60000);
      const leftMins = Math.max(0, Math.round((expiresMs - nowMs) / 60000));
      const hardMins = Math.max(0, Math.round((hardMs - nowMs) / 60000));
      const holder = (lease.holder_instance_id && names.instance(lease.holder_instance_id)) || 'An agent';
      return [
        `${holder} ${inProgressSentenceRest(leftMins)}`,
        `attempt ${task.attempt_no || 1} of 5 · hard limit in ${hardMins}m`,
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
    const depList = deps.map((d) => `"${names.task(d)}"`).join(', ');
    if (String(task.publish_state || '').toLowerCase() === 'draft') {
      return ['Draft, not visible to agents until you publish it', deps.length > 0 ? `then waits for ${depList}` : ''];
    }
    return deps.length > 0 ? ['Waiting for other tasks', `needs ${depList}`] : ['In the backlog', 'not ready to start yet'];
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
  // named: agents named as reviewers of this task (brief.reviewers).
  named: string[];
  // reviewers: named reviewers, then agents holding one of brief.review_roles.
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

/** One changed file of an attempt's VCS facet. */
export interface TaskChangedFile {
  path: string;
  add?: number;
  del?: number;
}

/** The facet's `files`: plain paths or `{path, status, add, del}` objects. */
export function taskChangedFiles(vcs: any): TaskChangedFile[] {
  const files = Array.isArray(vcs?.files) ? vcs.files : [];
  return files
    .map((f: any): TaskChangedFile => (typeof f === 'string' ? { path: f } : { path: String(f?.path || ''), add: f?.add, del: f?.del }))
    .filter((f: TaskChangedFile) => f.path);
}

export function getTaskPeople(task: TaskWire, chainFleets: any[] = []): TaskPeople {
  const assignee = String(task.brief?.assignee || '').trim();
  const fleets = Array.isArray(chainFleets) ? chainFleets : [];
  const fleetAgent = (f: any) => String(f?.agent_id || f?.agentId || '');
  const workers = assignee
    ? [assignee]
    : fleets.filter((f) => fleetRoles(f).includes('worker')).map(fleetAgent).filter(Boolean);
  const roles = task.brief?.review_roles || [];
  const named = Array.from(new Set((task.brief?.reviewers || []).map(String).filter(Boolean)));
  const reviewers = [
    ...named,
    ...fleets
      .filter((f) => fleetRoles(f).some((r) => roles.includes(r)))
      .map(fleetAgent)
      .filter(Boolean),
  ];
  const work = (task.leases || []).find((l: any) => (l?.kind || 'work') === 'work');
  const reviewersByRole = roles.map((role) => ({
    role,
    agents: fleets.filter((f) => fleetRoles(f).includes(role)).map(fleetAgent).filter(Boolean),
  }));
  return {
    assignee,
    workers: Array.from(new Set(workers)),
    named,
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

/** @ui Tone for a task state pill. */
export const TASK_STATE_TONE: Record<TaskStateV2, 'neutral' | 'info' | 'success' | 'warning' | 'danger' | 'pending'> = {
  in_progress: 'info',
  in_review: 'pending',
  ready: 'neutral',
  backlog: 'neutral',
  done: 'success',
  cancelled: 'neutral',
};

/** Maps the local badge tone vocabulary onto the @ui Tone set (plan REQ-UI-2). */
export function uiToneForBadge(tone: TaskBadge['tone']): 'neutral' | 'info' | 'success' | 'warning' | 'danger' | 'pending' {
  switch (tone) {
    case 'ok':
      return 'success';
    case 'accent':
      return 'info';
    case 'warn':
      return 'warning';
    case 'danger':
      return 'danger';
    case 'info':
      return 'info';
    default:
      return 'neutral';
  }
}

/** @ui Tone for a priority badge; the wire sends p0|p1|p2. */
export function uiToneForPriority(priority: string | undefined): 'danger' | 'warning' | 'neutral' {
  const p = String(priority || '').toLowerCase();
  return p === 'p0' || p === 'urgent' ? 'danger' : p === 'p1' || p === 'high' ? 'warning' : 'neutral';
}

/** "is working, 12m left": the in-progress sentence after the holder's name. */
export function inProgressSentenceRest(leftMins: number): string {
  return `is working, ${leftMins}m left`;
}

/**
 * The work-lease holder of an in-progress task and its minutes left, so a view
 * can render the holder with <HolderName> when names.instance() cannot name it.
 */
export function workLeaseHolder(task: TaskWire, nowMs: number = Date.now()): { instanceId: string; leftMins: number } | null {
  if (normalizeTaskState(task.state) !== 'in_progress') return null;
  const lease: any = workLease(task);
  if (!lease?.holder_instance_id) return null;
  const expiresMs = lease.expires_at ? new Date(lease.expires_at).getTime() : nowMs + 15 * 60000;
  return { instanceId: String(lease.holder_instance_id), leftMins: Math.max(0, Math.round((expiresMs - nowMs) / 60000)) };
}

/**
 * The task's work lease (a task can also carry review leases, which may come
 * first), or null. Every holder / time-left reading goes through this.
 */
export function workLease(task: TaskWire): TaskLeaseWire | null {
  return (task.leases || []).find((l) => (l?.kind || 'work') === 'work') || null;
}
