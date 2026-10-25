import { unknownReviewerLabel, type TaskNames } from './taskNames';

/**
 * One timeline line per task event, in plain words with names instead of ids
 * (plan REQ-UI-4). The kinds and lease-expiry reasons mirror
 * src/hub/service/taskv2/events.odin; a table-driven test parses that file so a
 * new kind without a sentence fails.
 */
export interface TaskEventWire {
  event_id?: number;
  kind?: string;
  actor_kind?: string;
  actor_id?: string;
  ts_ms?: number;
  payload?: any;
}

export interface DescribedEvent {
  text: string;
  /**
   * Set on a submission recorded before verification commands were removed
   * (D2): shown collapsed as a read-only "Legacy verification record".
   */
  legacyVerify?: { auto: boolean; skipReason: string };
  /** false when the kind is unknown and the text is a humanised kind name. */
  known: boolean;
}

/** Why a lease ended (`lease_expired.payload.reason`, EXPIRE_* in events.odin). */
export const EXPIRE_REASON_TEXT: Record<string, string> = {
  ttl: 'the lease timed out',
  hard_cap: 'it hit the hard time limit',
  idle: 'the agent went idle',
  instance_lost: 'the agent stopped unexpectedly',
  grant_unconfirmed: 'the agent never confirmed the assignment',
  replaced: 'its placement changed, so it is restarting',
  dep_added: 'a new dependency was added',
  chain_closed: 'the chain was closed',
  cancelled: 'the ticket was cancelled',
  changes_requested: 'changes were requested',
  hub_restart_no_lease: 'Heimdall restarted',
  user_stopped: 'a person stopped the agent',
};

function s(v: unknown): string {
  return typeof v === 'string' ? v.trim() : '';
}

function humanizeKind(kind: string): string {
  const words = s(kind).replace(/_/g, ' ');
  return words ? words.charAt(0).toUpperCase() + words.slice(1) : 'Event';
}

/** "security" / "reviewer,named" → " (security review)"; a named review has no role suffix. */
function roleSuffix(roleField: unknown): string {
  const roles = String(roleField || '')
    .split(',')
    .map((r) => r.trim())
    .filter((r) => r && r !== 'named');
  return roles.length ? ` (${roles.join(' and ')} review)` : '';
}

function attempt(p: any): string {
  const n = Number(p?.attempt_no || 0);
  return n > 0 ? ` (attempt ${n})` : '';
}

/**
 * Who a reviewer/participant id refers to (`agt_`, `inst_` or `user`), through
 * the single resolver names.participant() (REQ-TV2-6). An id nothing names is
 * "Unknown reviewer (<id>)", never "An agent".
 */
export function whoById(id: string, names: TaskNames): string {
  const v = s(id);
  if (!v) return 'Someone';
  if (v.toLowerCase() === 'user') return 'You';
  return names.participant(v) || unknownReviewerLabel(v);
}

/**
 * The reviewer a review_posted / changes_requested payload names, durable id
 * first: `reviewer_agent_id`, then `reviewer` (an agent id, `user`, or an
 * instance id on legacy rows), then `reviewer_instance_id`.
 */
export function reviewerIdFromPayload(p: any): string {
  return s(p?.reviewer_agent_id) || s(p?.reviewer) || s(p?.reviewer_instance_id);
}

function actorName(ev: TaskEventWire, names: TaskNames): string {
  switch (s(ev.actor_kind)) {
    case 'user':
      return 'You';
    case 'agent':
      return names.instance(s(ev.actor_id)) || 'An agent';
    case 'coordinator':
      return names.instance(s(ev.actor_id)) || 'The coordinator';
    case 'bridge':
      return names.bridge(s(ev.actor_id));
    default:
      return 'Heimdall';
  }
}

function holderName(p: any, names: TaskNames): string {
  const inst = s(p?.instance_id);
  const viaInstance = inst ? names.instance(inst) : null;
  if (viaInstance) return viaInstance;
  if (s(p?.agent_id)) return names.agent(s(p.agent_id));
  return 'an agent';
}

export function describeTaskEvent(ev: TaskEventWire, names: TaskNames): DescribedEvent {
  const p = ev?.payload && typeof ev.payload === 'object' ? ev.payload : {};
  const who = actorName(ev, names);
  const kind = s(ev?.kind);
  const known = (text: string): DescribedEvent => ({ text, known: true });

  switch (kind) {
    case 'migrated':
      return known(`Carried over from the previous task system${s(p.state) ? ` as ${s(p.state).replace(/_/g, ' ')}` : ''}`);
    case 'created':
      return known(`${who} created the task`);
    case 'published':
      return known(`${who} published the task`);
    case 'updated': {
      const fields = Array.isArray(p.fields) ? p.fields.map((f: unknown) => s(f).replace(/_/g, ' ')).filter(Boolean) : [];
      return known(fields.length ? `${who} updated ${fields.join(', ')}` : `${who} updated the task`);
    }
    case 'dep_added':
      return known(`Now waits for "${names.task(s(p.depends_on))}"`);
    case 'dep_removed':
      return known(`No longer waits for "${names.task(s(p.depends_on))}"`);
    case 'lease_granted': {
      const holder = holderName(p, names);
      const where = s(p.bridge_id) ? ` on ${names.bridge(s(p.bridge_id))}` : '';
      if (s(p.kind) === 'review') {
        return known(`${holder} started reviewing${roleSuffix(p.review_role)}${where}${attempt(p)}`);
      }
      return known(`Assigned to ${holder}${where}${attempt(p)}`);
    }
    case 'lease_confirmed':
      return known(`${who} picked up the assignment`);
    case 'lease_resent':
      return known('Assignment sent to the agent again');
    case 'lease_extended':
      return known(`Lease extended${s(p.reason) ? ` (${s(p.reason).replace(/_/g, ' ')})` : ''}`);
    case 'attempt_started':
      return known(`Attempt ${Number(p.attempt_no || 1)} started`);
    case 'heartbeat':
      return known(s(p.note) ? `${who}: ${s(p.note)}` : `${who} is still working`);
    case 'submitted':
      if (p.gate) return known(`Gate is waiting for a decision${attempt(p)}`);
      // Legacy rows may carry auto / skip_verify_reason (D2): history only.
      if (p.auto || s(p.skip_verify_reason)) {
        const text = p.auto ? `The work was submitted for review${attempt(p)}` : `${who} submitted the work for review${attempt(p)}`;
        return {
          ...known(text),
          legacyVerify: { auto: Boolean(p.auto), skipReason: s(p.skip_verify_reason) },
        };
      }
      return known(`${who} submitted the work for review${attempt(p)}`);
    case 'blocked': {
      const w = p.waiting_on || {};
      const on = s(w.kind) === 'human' ? 'you' : s(w.kind) ? s(w.kind).replace(/_/g, ' ') : 'input';
      return known(`Blocked, waiting on ${on}${s(w.reason) ? `: ${s(w.reason)}` : ''}`);
    }
    case 'blocked_realert':
      return known('Still blocked and waiting on you');
    case 'answered':
      // The hub answers a block on another task once that task is done (C3-2).
      if (p.auto) return known(`Unblocked automatically: ${s(p.note) || 'the ticket it waited on is done'}`);
      return known(`${who} answered the blocker`);
    case 'handoff':
      return known(`${who} handed the work off${attempt(p)}`);
    case 'lease_expired': {
      const reason = EXPIRE_REASON_TEXT[s(p.reason)] || (s(p.reason) ? s(p.reason).replace(/_/g, ' ') : 'it expired');
      const what = s(p.kind) === 'review' ? 'Review' : 'Work';
      return known(`${what} stopped because ${reason}${attempt(p)}`);
    }
    case 'review_posted': {
      const reviewer = whoById(reviewerIdFromPayload(p), names);
      const verdict = s(p.verdict) === 'approve' || s(p.verdict) === 'approved' ? 'approved' : 'requested changes';
      return known(`${reviewer} ${verdict}${roleSuffix(p.role)}`);
    }
    case 'changes_requested':
      return known(`${whoById(reviewerIdFromPayload(p), names)} requested changes${roleSuffix(p.role)}${attempt(p)}`);
    case 'approved':
      return known(`Approved${attempt(p)}`);
    case 'cancelled':
      return known(`${who} cancelled the task${s(p.reason) ? `: ${s(p.reason)}` : ''}`);
    case 'reopened':
      return known(`${who} reopened the task`);
    case 'comment':
      return known(`${who} commented`);
    case 'ready_unclaimed':
      return known('Ready, but no worker has picked it up yet');
    case 'summary_overflow':
      return known('Older events were summarised');
    case 'started_workflow':
      return known('Started a workflow run');
    case 'orphaned_work':
      return known('Work from a plan item that no longer exists was set aside');
    case 'carried_forward':
      return known('Carried forward from the previous run, already done');
    case 'merged':
      return known(`Merged into the directory${s(p.mode) ? ` (${s(p.mode).replace(/-/g, ' ')})` : ''}`);
    case 'merge_conflict':
      return known(`The branch did not merge${s(p.files) ? `: conflicts in ${s(p.files)}` : ''}; waiting on you`);
    case 'merge_failed':
      return known(`The merge did not run${s(p.detail) ? `: ${s(p.detail)}` : ''}; it is retried when the bridge reconnects`);
    case 'gate_feedback':
      return known(`The plan was rejected at the gate${s(p.summary) ? `: ${s(p.summary)}` : ''}; planning again`);
    default:
      return { text: humanizeKind(kind), known: false };
  }
}

export interface PostedReview {
  reviewer: string;
  verdict: string;
  findings: unknown;
  summary: string;
}

/**
 * Review findings for one attempt, newest last. The hub keeps them only in
 * `review_posted` event payloads (verbs_m2.odin); there is no `findings` facet, so
 * this is the one place the UI can read them without a request of its own.
 */
export function reviewsPostedForAttempt(events: TaskEventWire[], attemptNo: number): PostedReview[] {
  const out: PostedReview[] = [];
  for (const ev of events) {
    if (ev?.kind !== 'review_posted') continue;
    const p = ev.payload && typeof ev.payload === 'object' ? ev.payload : {};
    if (Number(p.attempt_no || 0) !== attemptNo) continue;
    const findings = p.findings;
    const summary = s(p.summary);
    const empty = findings == null || (Array.isArray(findings) && findings.length === 0);
    if (empty && !summary) continue;
    out.push({ reviewer: reviewerIdFromPayload(p), verdict: s(p.verdict), findings: empty ? null : findings, summary });
  }
  return out;
}
