import { useState, useMemo, useEffect } from 'react';
import { useSelector } from 'react-redux';
import type { ChainLike, TaskLike } from './chainTaskInference';
import { taskStatusOf, taskReviewerOf, isUserEffectiveReviewer } from './chainTaskInference';
import { Button, Select, StatusPill, Text, type Tone } from '@ui';
import { VaultText } from '../vault/VaultText';
import {
  isVaultArmored,
  containsVaultArmored,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
} from '../../utils/vaultContent';
import { selectActiveVaultKey } from '../../store/vaultSlice';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';
import { formatFleetRoleName } from '../tasks/FleetManagementDrawer';
import { useAuthUser } from '../auth/AuthUserContext';
import { replaceVaultTokens } from '../../utils/vaultCrypto.ts';

export type CurrentTaskStripProps = {
  task: TaskLike;
  chain?: ChainLike | null;
  agentInstanceId: string;
  role: 'assignee' | 'reviewer' | 'coordinator' | 'assigned' | 'observer';
  debugPrefix: string;
  // Task-comment creation: creates a task comment, NOT a chat message.
  onComment?: (taskId: string, body: string) => void | Promise<void>;
  // Submit the current task for review (assignee action).
  onSubmitForReview?: (taskId: string) => void | Promise<void>;
  // Nudge the assignee (coordinator/user action).
  onNudge?: (taskId: string) => void | Promise<void>;
  // Vote good/not-good (reviewer action).
  onVote?: (taskId: string, approved: boolean) => void | Promise<void>;
  // Open the task detail in the full chain view.
  onOpenTask?: (taskId: string) => void;
  // CT-9: candidate tasks the agent can be switched to (assignee/reviewer of).
  // When provided with onSwitchCurrentTask, renders a manual "switch current task"
  // control (user/coordinator action).
  switchableTasks?: TaskLike[];
  onSwitchCurrentTask?: (taskId: string) => void | Promise<void>;
  // CT-3: change this task's priority (P0/P1/P2) — user/coordinator action.
  onSetPriority?: (taskId: string, priority: string) => void | Promise<void>;
  collapsed?: boolean;
};

// Status -> semantic StatusPill tone (the ~10 raw statuses collapse onto the 6 tones).
function statusTone(status: string): Tone {
  const s = status.toLowerCase();
  if (s === 'in_progress') return 'info';
  if (s === 'review_ready' || s === 'in_validation') return 'info';
  if (s === 'validated_not_good' || s === 'blocked') return 'danger';
  // CT-2: Queued is a distinct held-back state — amber/warning so it reads as "waiting".
  if (s === 'queued') return 'warning';
  return 'neutral';
}

// CT-3: P0/P1/P2 priority indicator. P0 is most urgent (red), P1 amber, P2 muted.
export function priorityOf(task: { priority?: string }): string {
  return String(task?.priority || '').toLowerCase();
}
function priorityTone(priority: string): Tone | null {
  const p = priority.toLowerCase();
  if (p === 'p0') return 'danger';
  if (p === 'p1') return 'warning';
  if (p === 'p2') return 'neutral';
  return null;
}

// R8: the current-task role rendered as an explicit WORK vs REVIEW action label.
function roleActionLabel(role: string): string {
  const r = String(role || '').toLowerCase();
  if (r === 'reviewer') return 'REVIEW';
  if (r === 'assignee' || r === 'assigned') return 'WORK';
  if (r === 'coordinator') return 'COORDINATE';
  return String(role || '').toUpperCase();
}
function roleActionTone(role: string): Tone {
  const r = String(role || '').toLowerCase();
  if (r === 'reviewer') return 'info';
  if (r === 'assignee' || r === 'assigned') return 'success';
  return 'neutral';
}

// Derive the first 1-2 acceptance criteria from the chain description / task description.
function acceptanceSummary(rawText: string): string {
  const raw = String(rawText || '').trim();
  if (!raw) return '';
  // Pull lines that look like acceptance criteria (## Acceptance, - bullet, [ ] checkbox).
  const lines = raw.split('\n');
  const crit: string[] = [];
  let inAcceptance = false;
  for (const line of lines) {
    const trimmed = line.trim();
    if (/^#{1,6}\s*accept/i.test(trimmed) || /acceptance criteria/i.test(trimmed)) {
      inAcceptance = true;
      continue;
    }
    if (inAcceptance && /^#{1,6}/.test(trimmed)) {
      inAcceptance = false;
      continue;
    }
    if (inAcceptance && (trimmed.startsWith('-') || trimmed.startsWith('*') || /^\[[ x]\]/i.test(trimmed))) {
      crit.push(trimmed.replace(/^[-*]\s*(\[[ x]\]\s*)?/, '').slice(0, 80));
    }
  }
  if (crit.length > 0) return crit.slice(0, 2).join(' · ');
  // Fallback: first non-empty line.
  return raw.split('\n').map((l) => l.trim()).filter(Boolean)[0]?.slice(0, 80) || '';
}

export default function CurrentTaskStrip({
  task,
  chain,
  agentInstanceId,
  role,
  debugPrefix,
  onComment,
  onSubmitForReview,
  onNudge,
  onVote,
  onOpenTask,
  switchableTasks,
  onSwitchCurrentTask,
  onSetPriority,
  collapsed = false,
}: CurrentTaskStripProps) {
  const authUser = useAuthUser();
  const username = String(authUser?.user_id || '').trim();
  const [commenting, setCommenting] = useState(false);
  const [commentBody, setCommentBody] = useState('');
  const [collapsedLocal, setCollapsedLocal] = useState(collapsed);

  const taskId = String(task.taskId || task.task_id || '');
  const status = taskStatusOf(task);
  const priority = priorityOf(task as any);
  const title = String(task.title || taskId);
  const reviewer = taskReviewerOf(task);
  const userIsReviewer = isUserEffectiveReviewer(task);

  // Key material lives only as a non-extractable CryptoKey (REQ-VAULT-HARDEN-1), so the
  // decryption gates below test the real key rather than the permanently-null
  // state.vault.rawVaultKeyHex. With no vault configured there is no key and the
  // unarmored plaintext returns through the early returns above each gate.
  const activeKey = useSelector(selectActiveVaultKey);
  const rawDesc = String(task.description || '').trim();
  const [decryptedDesc, setDecryptedDesc] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    if (!rawDesc || (!isVaultArmored(rawDesc) && !containsVaultArmored(rawDesc))) {
      setDecryptedDesc(rawDesc);
      return;
    }
    if (!activeKey) {
      setDecryptedDesc(null);
      return;
    }
    const p = isVaultArmored(rawDesc)
      ? decryptVaultText(rawDesc, activeKey)
      : decryptEmbeddedVaultTokens(rawDesc, activeKey);
    p.then((res) => {
      if (active) setDecryptedDesc(res);
    }).catch(() => {
      if (active) setDecryptedDesc(rawDesc);
    });
    return () => {
      active = false;
    };
  }, [rawDesc, activeKey]);

  const effectiveDesc = decryptedDesc !== null ? decryptedDesc : (isVaultArmored(rawDesc) ? '' : rawDesc);
  const summary = acceptanceSummary(effectiveDesc);

  const [decryptedSwitchableTasks, setDecryptedSwitchableTasks] = useState(switchableTasks || []);

  useEffect(() => {
    let active = true;
    if (!switchableTasks || switchableTasks.length === 0) {
      setDecryptedSwitchableTasks([]);
      return;
    }
    if (!activeKey) {
      setDecryptedSwitchableTasks(
        switchableTasks.map((t) => ({
          ...t,
          title: t.title ? replaceVaultTokens(t.title, '[🔒 Encrypted]') : t.title,
        }))
      );
      return;
    }
    Promise.all(
      switchableTasks.map(async (t) => {
        const rawTitle = String(t.title || '');
        if (!isVaultArmored(rawTitle) && !containsVaultArmored(rawTitle)) return t;
        try {
          const dec = isVaultArmored(rawTitle)
            ? await decryptVaultText(rawTitle, activeKey)
            : await decryptEmbeddedVaultTokens(rawTitle, activeKey);
          return { ...t, title: dec };
        } catch {
          return { ...t, title: replaceVaultTokens(rawTitle, '[🔒 Encrypted]') };
        }
      })
    ).then((res) => {
      if (active) setDecryptedSwitchableTasks(res);
    });
    return () => {
      active = false;
    };
  }, [switchableTasks, activeKey]);

  const { data: identitiesData } = useListAgentIdentitiesQuery();
  const agentIdentities = identitiesData?.agents || (identitiesData as any)?.identities || [];

  const memberNameMap = useMemo(() => {
    const map = new Map<string, string>();
    const members: any[] = (chain as any)?.members || [];
    for (const m of members) {
      const instId = m.agentInstanceId || m.agent_instance_id;
      const agtId = m.agentId || m.agent_id;
      const name = m.displayName || m.display_name || m.name;
      if (instId && name) map.set(instId, name);
      if (agtId && name) map.set(agtId, name);
    }
    return map;
  }, [chain]);

  function resolveDisplayName(id: string, fallbackRef?: any): string {
    if (!id) return '';
    if (fallbackRef?.displayName || fallbackRef?.display_name || fallbackRef?.name) {
      return fallbackRef.displayName || fallbackRef.display_name || fallbackRef.name;
    }
    if (memberNameMap.has(id)) {
      return memberNameMap.get(id)!;
    }
    if (id.startsWith('agt_')) {
      return formatFleetRoleName(id, agentIdentities);
    }
    return id;
  }

  const assigneeRef = (task as any)?.assigneeRef || (task as any)?.assignee_ref;
  const assigneeAgentId = assigneeRef?.agentId || assigneeRef?.agent_id;
  const assigneeDisplayName =
    resolveDisplayName(agentInstanceId, assigneeRef) ||
    (assigneeAgentId ? formatFleetRoleName(assigneeAgentId, agentIdentities) : agentInstanceId);

  const reviewerRef = (task as any)?.reviewerRefs?.[0] || (task as any)?.reviewer_refs?.[0];
  const reviewerDisplayName = userIsReviewer
    ? (username ? `You (@${username})` : 'You')
    : reviewer ? resolveDisplayName(reviewer, reviewerRef) : '';

  if (collapsedLocal) {
    return (
      <div data-debug-id={`${debugPrefix}-current-task-strip`} data-current-task-status={status} className="mb-2 flex items-center justify-between gap-2 rounded-xl border border-subtle bg-surface px-3 py-2 text-[11.5px] text-muted">
        <span className="truncate">Current task: <span className="text-primary"><VaultText value={title} as="span" /></span></span>
        <button type="button" data-debug-id={`${debugPrefix}-current-task-expand`} onClick={() => setCollapsedLocal(false)} className="rounded-full border border-subtle px-2 py-0.5 text-muted hover:bg-neutral-soft hover:text-primary">expand</button>
      </div>
    );
  }

  async function submitComment() {
    const body = commentBody.trim();
    if (!body || !onComment) return;
    setCommentBody('');
    setCommenting(false);
    try {
      await onComment(taskId, body);
    } catch {
      // caller surfaces its own error UI
    }
  }

  return (
    <div data-debug-id={`${debugPrefix}-current-task-strip`} data-current-task-status={status} data-task-comment-mode="true" className="mb-2 rounded-[15px] border border-accent/30 bg-accent/5 px-3 py-2.5 text-[12px] text-primary shadow-panel">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <Text role="overline" tone="accent" className="shrink-0">Current task</Text>
            {onOpenTask ? (
              <a
                data-debug-id={`${debugPrefix}-current-task-link`}
                href={chain?.chainId || (chain as any)?.chain_id ? `#/chains/${encodeURIComponent(String(chain.chainId || (chain as any).chain_id))}` : undefined}
                onClick={(e) => {
                  e.preventDefault();
                  onOpenTask(taskId);
                }}
                className="truncate font-medium text-primary underline decoration-dotted underline-offset-2 hover:text-accent"
                title={title}
              >
                <VaultText value={title} as="span" />
              </a>
            ) : (
              <span className="truncate font-medium text-primary"><VaultText value={title} as="span" /></span>
            )}
          </div>
          <div className="mt-1 flex flex-wrap items-center gap-1.5 text-caption text-muted">
            {/* R8: explicit WORK vs REVIEW action label for the current-task role. */}
            <StatusPill tone={roleActionTone(role)} data-debug-id={`${debugPrefix}-current-task-action`} data-current-task-action={roleActionLabel(role)}>{roleActionLabel(role)}</StatusPill>
            <StatusPill tone={statusTone(status)}>{status}</StatusPill>
            {/* CT-3: P0/P1/P2 priority indicator (hidden when unknown). */}
            {(() => { const pt = priorityTone(priority); return pt ? <StatusPill tone={pt} data-debug-id={`${debugPrefix}-current-task-priority`} data-current-task-priority={priority} className="uppercase">{priority}</StatusPill> : null; })()}
            <span>Assignee: <span className="text-primary">{assigneeDisplayName || agentInstanceId}</span></span>
            {(reviewer || userIsReviewer) ? <span>Reviewer: <span className="text-primary">{reviewerDisplayName || reviewer}</span></span> : null}
          </div>
          {summary ? <div data-debug-id={`${debugPrefix}-current-task-acceptance`} className="mt-1.5 truncate text-caption text-muted">Acceptance: {summary}</div> : null}
        </div>
        <div className="flex shrink-0 items-center gap-1">
          {onOpenTask ? <button type="button" data-debug-id={`${debugPrefix}-current-task-open`} onClick={() => onOpenTask(taskId)} className="rounded-full border border-subtle px-2.5 py-1 text-muted hover:bg-neutral-soft hover:text-primary">Open</button> : null}
          <button type="button" data-debug-id={`${debugPrefix}-current-task-collapse`} onClick={() => setCollapsedLocal(true)} className="rounded-full border border-subtle px-2 py-1 text-muted hover:bg-neutral-soft hover:text-primary">−</button>
        </div>
      </div>

      <div className="mt-2 flex flex-wrap items-center gap-1.5">
        {role === 'assignee' && onSubmitForReview ? (
          <button type="button" data-debug-id={`${debugPrefix}-current-task-submit-review`} onClick={() => void onSubmitForReview(taskId)} className="rounded-full border border-info/30 bg-info-soft px-2.5 py-1 text-info hover:bg-info/20">Submit for review</button>
        ) : null}
        {(role === 'reviewer' || userIsReviewer) && onVote ? (
          <>
            <Button tone="success" size="sm" data-debug-id={`${debugPrefix}-current-task-vote-good`} onClick={() => void onVote(taskId, true)}>Approve</Button>
            <Button tone="danger" size="sm" data-debug-id={`${debugPrefix}-current-task-vote-bad`} onClick={() => void onVote(taskId, false)}>Request changes</Button>
          </>
        ) : null}
        {role === 'coordinator' && onNudge ? (
          <Button tone="warning" size="sm" data-debug-id={`${debugPrefix}-current-task-nudge`} onClick={() => void onNudge(taskId)}>Nudge</Button>
        ) : null}
        {onComment ? (
          <button type="button" data-debug-id={`${debugPrefix}-current-task-comment-btn`} onClick={() => setCommenting((open) => !open)} className="rounded-full border border-subtle px-2.5 py-1 text-muted hover:bg-neutral-soft hover:text-primary">Comment</button>
        ) : null}
        {/* CT-9: manual "switch current task" control (user/coordinator). */}
        {onSwitchCurrentTask && decryptedSwitchableTasks && decryptedSwitchableTasks.length > 0 ? (
          <Select
            data-debug-id={`${debugPrefix}-current-task-switch`}
            value={taskId}
            onChange={(next) => { if (next && next !== taskId) void onSwitchCurrentTask(next); }}
            size="sm"
            title="Switch current task"
          >
            {decryptedSwitchableTasks.map((candidate) => {
              const cid = String(candidate.taskId || candidate.task_id || '');
              return <option key={cid} value={cid}>{String(candidate.title || cid)}</option>;
            })}
          </Select>
        ) : null}
        {/* CT-3: set priority (P0/P1/P2) — user/coordinator. */}
        {onSetPriority ? (
          <Select
            data-debug-id={`${debugPrefix}-current-task-set-priority`}
            value={priority || 'p2'}
            onChange={(next) => { if (next && next !== priority) void onSetPriority(taskId, next); }}
            size="sm"
            title="Set priority"
          >
            <option value="p0">P0</option>
            <option value="p1">P1</option>
            <option value="p2">P2</option>
          </Select>
        ) : null}
      </div>

      {commenting ? (
        <div data-debug-id={`${debugPrefix}-current-task-comment-composer`} className="mt-2 rounded-xl border border-subtle bg-surface-raised p-2">
          <textarea
            data-debug-id={`${debugPrefix}-current-task-comment-input`}
            value={commentBody}
            onChange={(event) => setCommentBody(event.target.value)}
            placeholder="Add a task comment (not a chat message)…"
            rows={2}
            className="w-full resize-none rounded-lg bg-transparent px-2 py-1 text-[12px] text-primary outline-none placeholder:text-muted"
            onKeyDown={(event) => { if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) { event.preventDefault(); void submitComment(); } }}
          />
          <div className="mt-1 flex items-center justify-end gap-1.5">
            <button type="button" data-debug-id={`${debugPrefix}-current-task-comment-cancel`} onClick={() => { setCommenting(false); setCommentBody(''); }} className="rounded-full border border-subtle px-2 py-0.5 text-caption text-muted hover:bg-neutral-soft hover:text-primary">Cancel</button>
            <button type="button" data-debug-id={`${debugPrefix}-current-task-comment-submit`} onClick={() => void submitComment()} disabled={!commentBody.trim()} className="rounded-full border border-accent/30 bg-accent/10 px-2.5 py-0.5 text-caption text-accent hover:bg-accent/20 disabled:opacity-40">Add comment</button>
          </div>
        </div>
      ) : null}
    </div>
  );
}
