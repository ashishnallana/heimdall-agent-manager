import React, { useState, useEffect } from 'react';
import { Icon } from '@ui';
import { TaskWire } from '../../api/taskWire';
import {
  useFetchTaskEventsQuery,
  useFetchTaskFacetQuery,
  useFetchCommitDiffQuery,
  useUserReviewTaskMutation,
  useReopenTaskMutation,
  useAnswerTaskBlockerMutation,
  useVerifyTaskMutation,
  useCancelTaskDetailMutation,
  useUpdateTaskDetailMutation,
  useAddTaskCommentMutation,
} from '../../api/endpoints/tasks';
import { TaskChainFleet } from '../../api/endpoints/taskChains';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';
import { formatFleetRoleName } from './FleetManagementDrawer';
import {
  TASK_STATE_COLORS,
  TASK_STATE_LABELS,
  getTaskBadges,
  getTaskPeople,
  getTaskStatusLines,
  normalizeTaskState,
} from './taskV2Types';

export interface TaskDetailViewProps {
  chainId: string;
  taskId: string;
  tasks: TaskWire[];
  onClose: () => void;
  onSelectTask: (taskId: string) => void;
  chainFleets?: TaskChainFleet[];
  className?: string;
}

export const TaskDetailView: React.FC<TaskDetailViewProps> = ({
  chainId,
  taskId,
  tasks = [],
  onClose,
  onSelectTask,
  chainFleets = [],
  className = '',
}) => {
  const task = tasks.find((t) => t.task_id === taskId) || ({
    task_id: taskId,
    chain_id: chainId,
    title: taskId,
    state: 'backlog',
    attempt_no: 1,
    priority: 'P1',
    kind: 'task',
    publish_state: 'published',
    ready_since: '',
    requires_user_approval: false,
    brief: null,
    blocked_on: null,
    bridge_id: '',
  } as TaskWire);

  const state = normalizeTaskState(task.state);
  const badges = getTaskBadges(task, chainFleets);
  const [statusLine1, statusLine2] = getTaskStatusLines(task, chainFleets);
  const people = getTaskPeople(task, chainFleets);
  const { data: identitiesData } = useListAgentIdentitiesQuery();
  const agentName = (id: string) => formatFleetRoleName(id, identitiesData?.agents || []);
  const attemptNo = task.attempt_no || 1;

  // Facet queries for attempt
  const { data: vcsFacetData } = useFetchTaskFacetQuery(
    { chainId, taskId, attemptNo, kind: 'vcs' },
    { skip: !chainId || !taskId }
  );
  const { data: handoffFacetData } = useFetchTaskFacetQuery(
    { chainId, taskId, attemptNo, kind: 'handoff' },
    { skip: !chainId || !taskId }
  );
  const { data: verifyFacetData } = useFetchTaskFacetQuery(
    { chainId, taskId, attemptNo, kind: 'verify' },
    { skip: !chainId || !taskId }
  );
  const { data: outputFacetData } = useFetchTaskFacetQuery(
    { chainId, taskId, attemptNo, kind: 'output' },
    { skip: !chainId || !taskId }
  );
  const { data: findingsFacetData } = useFetchTaskFacetQuery(
    { chainId, taskId, attemptNo, kind: 'findings' },
    { skip: !chainId || !taskId }
  );

  // Events query for folded timeline
  const { data: eventsData } = useFetchTaskEventsQuery(
    { chainId, taskId },
    { skip: !chainId || !taskId }
  );

  const { data: bridgesData } = useListBridgesQuery();
  const bridges: any[] = bridgesData?.bridges || [];

  // Mutations
  const [userReviewTask, { isLoading: isReviewing }] = useUserReviewTaskMutation();
  const [reopenTask, { isLoading: isReopening }] = useReopenTaskMutation();
  const [answerTaskBlocker, { isLoading: isAnswering }] = useAnswerTaskBlockerMutation();
  const [verifyTask, { isLoading: isVerifying }] = useVerifyTaskMutation();
  const [cancelTask, { isLoading: isCancelling }] = useCancelTaskDetailMutation();
  const [updateTask] = useUpdateTaskDetailMutation();
  const [addComment] = useAddTaskCommentMutation();

  // Local UI state
  const [yourFindings, setYourFindings] = useState('');
  const [answerNote, setAnswerNote] = useState('');
  const [showAnswerModal, setShowAnswerModal] = useState(false);
  const [commentText, setCommentText] = useState('');
  const [showCommentBox, setShowCommentBox] = useState(false);
  const [showAllEvents, setShowAllEvents] = useState(false);
  const [selectedDiffFile, setSelectedDiffFile] = useState<string | null>(null);

  const vcsFacet = vcsFacetData?.facet;
  const handoffFacet = handoffFacetData?.facet;
  const verifyFacet = verifyFacetData?.facet;
  const outputFacet = outputFacetData?.facet;
  const findingsFacet = findingsFacetData?.facet;
  const events = eventsData?.events || [];

  // Commit diff query when a file is selected
  const baseSha = vcsFacet?.base || '';
  const headSha = vcsFacet?.head || '';
  const dirId = vcsFacet?.directory_id || 'default';
  const { data: diffData } = useFetchCommitDiffQuery(
    {
      chainId,
      directoryId: dirId,
      base: baseSha,
      head: headSha,
      path: selectedDiffFile || '',
    },
    { skip: !selectedDiffFile || !baseSha || !headSha }
  );

  const isAwaitingUser = state === 'in_review' && task.requires_user_approval;
  const isGate = task.kind === 'gate';

  const handleApprove = async () => {
    try {
      await userReviewTask({
        chainId,
        taskId,
        verdict: 'approve',
      }).unwrap();
    } catch (err) {
      console.error('Failed to approve review', err);
    }
  };

  const handleRequestChanges = async () => {
    try {
      const findings = yourFindings.trim() ? [yourFindings.trim()] : ['Please address comments.'];
      await userReviewTask({
        chainId,
        taskId,
        verdict: 'request_changes',
        findings,
      }).unwrap();
      setYourFindings('');
    } catch (err) {
      console.error('Failed to request changes', err);
    }
  };

  const handleAnswerBlocker = async () => {
    try {
      await answerTaskBlocker({
        chainId,
        taskId,
        note: answerNote,
      }).unwrap();
      setShowAnswerModal(false);
      setAnswerNote('');
    } catch (err) {
      console.error('Failed to answer blocker', err);
    }
  };

  const handleReopen = async () => {
    try {
      await reopenTask({ chainId, taskId }).unwrap();
    } catch (err) {
      console.error('Failed to reopen task', err);
    }
  };

  const handleCancel = async () => {
    if (!window.confirm('Cancel this task?')) return;
    try {
      await cancelTask({ chainId, taskId }).unwrap();
    } catch (err) {
      console.error('Failed to cancel task', err);
    }
  };

  const handleRerunVerify = async () => {
    try {
      await verifyTask({ chainId, taskId }).unwrap();
    } catch (err) {
      console.error('Failed to trigger independent verify', err);
    }
  };

  const handlePinBridge = async (newBridgeId: string) => {
    try {
      await updateTask({
        chainId,
        taskId,
        bridgeId: newBridgeId,
      }).unwrap();
    } catch (err) {
      console.error('Failed to update task bridge pin', err);
    }
  };

  const handleSendComment = async () => {
    if (!commentText.trim()) return;
    try {
      await addComment({
        chainId,
        taskId,
        body: commentText.trim(),
      }).unwrap();
      setCommentText('');
      setShowCommentBox(false);
    } catch (err) {
      console.error('Failed to add comment', err);
    }
  };

  const changedFiles: string[] = vcsFacet?.files || [];

  return (
    <div
      data-debug-id="task-detail-view"
      className={`flex flex-col gap-4 text-left p-4 sm:p-6 overflow-y-auto ${className}`}
    >
      {/* Top navigation row */}
      <div className="flex items-center justify-between">
        <button
          type="button"
          data-debug-id="task-detail-back-btn"
          onClick={onClose}
          className="inline-flex items-center gap-1.5 rounded-lg border border-subtle bg-surface px-3 py-1.5 text-xs font-semibold text-primary hover:bg-surface-raised transition-colors"
        >
          <Icon name="arrow-left" size="sm" />
          <span>Tasks</span>
        </button>

        <span
          className="inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-semibold"
          style={{
            backgroundColor: `${TASK_STATE_COLORS[state]}20`,
            color: TASK_STATE_COLORS[state],
          }}
        >
          <span
            className="h-2 w-2 rounded-full shrink-0"
            style={{ backgroundColor: TASK_STATE_COLORS[state] }}
          />
          {TASK_STATE_LABELS[state]}
        </span>
      </div>

      {/* Title & IDs */}
      <div className="flex flex-col gap-1">
        <div className="flex items-center gap-2">
          <span className="font-mono text-xs text-muted">{task.task_id}</span>
          <h1 className="text-base font-bold text-primary flex-1">{task.title}</h1>
          {isGate ? (
            <span className="rounded bg-accent-soft px-2 py-0.5 font-mono text-[10px] font-semibold text-accent uppercase">
              Gate
            </span>
          ) : (
            <span className="rounded bg-neutral-soft px-2 py-0.5 font-mono text-[10px] font-semibold text-muted uppercase">
              {task.priority || 'P1'}
            </span>
          )}
        </div>

        {task.stage_key && (
          <div className="text-xs font-mono text-muted">
            workflow stage: <span className="text-primary font-semibold">{task.stage_key}</span>
            {task.stage_index !== undefined ? ` [${task.stage_index}]` : ''}
          </div>
        )}
      </div>

      {/* Badges row */}
      {badges.length > 0 && (
        <div className="flex flex-wrap items-center gap-1.5">
          {badges.map((b, i) => (
            <span
              key={i}
              title={b.title}
              className="inline-flex items-center rounded border border-subtle bg-surface-raised px-2 py-0.5 font-mono text-[11px] text-primary"
            >
              {b.label}
            </span>
          ))}
        </div>
      )}

      {/* 2-line status sentence */}
      <div className="rounded-xl border border-subtle bg-surface-raised p-3 text-xs leading-relaxed">
        <div className="font-semibold text-primary">{statusLine1}</div>
        <div className="text-muted text-[11px] mt-0.5">{statusLine2}</div>
      </div>

      {/* Human Actions bar */}
      <div className="flex flex-wrap items-center gap-2 border-y border-subtle py-2.5">
        {task.blocked_on && (
          <button
            type="button"
            data-debug-id="act-answer-blocker"
            onClick={() => setShowAnswerModal(true)}
            className="rounded-lg bg-accent px-3 py-1.5 text-xs font-semibold text-accent-fg hover:opacity-90 transition-opacity"
          >
            Answer Blocker
          </button>
        )}

        {(isAwaitingUser || isGate) && state === 'in_review' && (
          <>
            <button
              type="button"
              data-debug-id="act-user-approve"
              onClick={handleApprove}
              disabled={isReviewing}
              className="rounded-lg bg-success px-3 py-1.5 text-xs font-semibold text-white hover:opacity-90 transition-opacity"
            >
              Approve
            </button>
            <button
              type="button"
              data-debug-id="act-user-request-changes"
              onClick={handleRequestChanges}
              disabled={isReviewing}
              className="rounded-lg border border-subtle bg-surface px-3 py-1.5 text-xs font-semibold text-primary hover:bg-surface-raised transition-colors"
            >
              Request Changes
            </button>
          </>
        )}

        {(state === 'done' || state === 'cancelled') && (
          <button
            type="button"
            data-debug-id="act-reopen"
            onClick={handleReopen}
            disabled={isReopening}
            className="rounded-lg border border-subtle bg-surface px-3 py-1.5 text-xs font-semibold text-primary hover:bg-surface-raised transition-colors"
          >
            Reopen Task
          </button>
        )}

        {state !== 'done' && state !== 'cancelled' && (
          <button
            type="button"
            data-debug-id="act-cancel"
            onClick={handleCancel}
            disabled={isCancelling}
            className="rounded-lg border border-danger/40 bg-danger-soft px-3 py-1.5 text-xs font-semibold text-danger hover:bg-danger/20 transition-colors"
          >
            Cancel Task
          </button>
        )}

        <button
          type="button"
          data-debug-id="act-comment"
          onClick={() => setShowCommentBox(!showCommentBox)}
          className="rounded-lg border border-subtle bg-surface px-3 py-1.5 text-xs font-semibold text-primary hover:bg-surface-raised transition-colors"
        >
          Comment
        </button>
      </div>

      {/* Optional Comment Input Box */}
      {showCommentBox && (
        <div className="rounded-xl border border-subtle bg-surface p-3 space-y-2">
          <textarea
            value={commentText}
            onChange={(e) => setCommentText(e.target.value)}
            placeholder="Add an event log comment…"
            rows={2}
            className="w-full rounded-lg border border-subtle bg-canvas p-2.5 text-xs text-primary outline-none focus:border-accent"
          />
          <div className="flex justify-end gap-2">
            <button
              type="button"
              onClick={() => setShowCommentBox(false)}
              className="px-2.5 py-1 text-xs text-muted hover:text-primary"
            >
              Cancel
            </button>
            <button
              type="button"
              onClick={handleSendComment}
              className="rounded-lg bg-accent px-3 py-1 text-xs font-semibold text-accent-fg hover:opacity-90"
            >
              Post Comment
            </button>
          </div>
        </div>
      )}

      {/* YOUR REVIEW BLOCK (when awaiting user approval or gate) */}
      {(isAwaitingUser || isGate) && state === 'in_review' && (
        <div
          data-debug-id="your-review-block"
          className="rounded-xl border border-accent/40 bg-accent-soft/20 p-4 space-y-3"
        >
          <div className="flex items-center justify-between">
            <h3 className="text-xs font-bold uppercase tracking-wider text-accent">
              Your Review
            </h3>
            <span className="text-[11px] text-muted">
              You are the final review gate for this attempt
            </span>
          </div>

          {handoffFacet?.summary && (
            <div className="rounded-lg bg-surface p-3 text-xs leading-relaxed text-primary">
              <span className="font-semibold text-muted block mb-1">Author's Latest Handoff:</span>
              {handoffFacet.summary}
            </div>
          )}

          {changedFiles.length > 0 && (
            <div className="text-xs space-y-1">
              <span className="font-semibold text-muted">Changed Files:</span>
              <div className="font-mono text-[11px] text-primary flex flex-wrap gap-1">
                {changedFiles.map((f) => (
                  <span key={f} className="rounded bg-surface px-1.5 py-0.5 border border-subtle">
                    {f}
                  </span>
                ))}
              </div>
            </div>
          )}

          <textarea
            value={yourFindings}
            onChange={(e) => setYourFindings(e.target.value)}
            placeholder="Findings / feedback (required when requesting changes)…"
            rows={2}
            className="w-full rounded-lg border border-subtle bg-surface p-2.5 text-xs text-primary outline-none focus:border-accent"
          />

          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={handleApprove}
              disabled={isReviewing}
              className="rounded-lg bg-success px-4 py-1.5 text-xs font-semibold text-white hover:opacity-90"
            >
              Approve
            </button>
            <button
              type="button"
              onClick={handleRequestChanges}
              disabled={isReviewing}
              className="rounded-lg border border-subtle bg-surface px-3 py-1.5 text-xs font-semibold text-primary hover:bg-surface-raised"
            >
              Request Changes
            </button>
          </div>
        </div>
      )}

      {/* BRIEF SECTION */}
      <section className="rounded-xl border border-subtle bg-surface p-4 space-y-3">
        <h3 className="text-xs font-bold uppercase tracking-wider text-muted">
          Brief
        </h3>

        {task.brief?.goal ? (
          <div className="text-xs leading-relaxed text-primary font-medium">
            {task.brief.goal}
          </div>
        ) : task.description ? (
          <div className="text-xs leading-relaxed text-primary">
            {task.description}
          </div>
        ) : (
          <div className="text-xs text-muted italic">No goal defined.</div>
        )}

        {/* Acceptance criteria */}
        {task.brief?.acceptance && task.brief.acceptance.length > 0 && (
          <div className="space-y-1.5 pt-1">
            <span className="text-[11px] font-semibold text-muted uppercase tracking-wider">
              Acceptance Criteria
            </span>
            <ul className="space-y-1">
              {task.brief.acceptance.map((crit, idx) => (
                <li key={idx} className="flex items-start gap-2 text-xs text-primary">
                  <Icon
                    name="check"
                    size="sm"
                    className={state === 'done' ? 'text-success' : 'text-faint opacity-40'}
                    title={state === 'done' ? 'Met' : 'Not yet verified'}
                  />
                  <span>{crit}</span>
                </li>
              ))}
            </ul>
          </div>
        )}

        {/* Verify command */}
        {task.brief?.verify && (
          <div className="pt-1">
            <span className="text-[11px] font-semibold text-muted uppercase tracking-wider block mb-1">
              Verify Command
            </span>
            <code className="block rounded bg-canvas p-2 font-mono text-xs text-primary border border-subtle">
              $ {task.brief.verify}
            </code>
          </div>
        )}

        {/* Dependencies */}
        {task.depends_on && task.depends_on.length > 0 && (
          <div className="flex items-center gap-2 pt-1 text-xs">
            <span className="text-muted">Depends on:</span>
            <div className="flex flex-wrap gap-1.5">
              {task.depends_on.map((depId) => (
                <button
                  key={depId}
                  type="button"
                  onClick={() => onSelectTask(depId)}
                  className="font-mono text-info hover:underline"
                >
                  {depId}
                </button>
              ))}
            </div>
          </div>
        )}
      </section>

      {/* PLACEMENT SECTION */}
      <section className="rounded-xl border border-subtle bg-surface p-4 space-y-2.5 text-xs">
        <div className="flex items-center justify-between">
          <h3 className="font-bold uppercase tracking-wider text-muted">
            Placement
          </h3>
          <span className="font-mono text-[11px] text-faint">
            {task.leases?.length ? 'running' : 'next grant'}
          </span>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-2 pt-1">
          <label className="flex flex-col gap-1 text-muted">
            <span>Bridge Pin</span>
            <select
              value={task.bridge_id || ''}
              onChange={(e) => handlePinBridge(e.target.value)}
              className="rounded border border-subtle bg-canvas px-2.5 py-1 text-primary text-xs outline-none focus:border-accent"
            >
              <option value="">— fleet default —</option>
              {bridges.map((b) => (
                <option key={b.id} value={b.id}>
                  {b.name || b.id} {b.status === 'online' || b.connected ? '' : '(offline)'}
                </option>
              ))}
            </select>
          </label>

          <div data-debug-id="task-detail-assignee" className="flex flex-col gap-1 text-muted">
            <span>Assignee</span>
            <span className="text-primary pt-1">
              {people.assignee
                ? agentName(people.assignee)
                : people.workers.length
                  ? `any worker: ${people.workers.map(agentName).join(', ')}`
                  : 'no worker in fleet'}
              {people.holder && (
                <span className="ml-1 font-mono text-[11px] text-faint">· held by {people.holder}</span>
              )}
            </span>
          </div>

          <div data-debug-id="task-detail-reviewers" className="flex flex-col gap-1 text-muted">
            <span>Reviewers</span>
            <span className="text-primary pt-1">
              {people.reviewersByRole.length
                ? people.reviewersByRole
                    .map(({ role, agents }) => `${role}: ${agents.length ? agents.map(agentName).join(', ') : 'no fleet row'}`)
                    .join(' · ')
                : 'none'}
              {task.requires_user_approval ? ' + you' : ''}
            </span>
          </div>
        </div>
      </section>

      {/* CHANGES (DIFF BY REFERENCE) */}
      {changedFiles.length > 0 && (
        <section className="rounded-xl border border-subtle bg-surface p-4 space-y-3">
          <div className="flex items-center justify-between">
            <h3 className="text-xs font-bold uppercase tracking-wider text-muted">
              Changes (Diff by Reference)
            </h3>
            <span className="font-mono text-[11px] text-faint">
              {changedFiles.length} file{changedFiles.length === 1 ? '' : 's'}
            </span>
          </div>

          {baseSha && headSha && (
            <div className="flex items-center gap-2 font-mono text-[11px] text-faint">
              <span>{baseSha.slice(0, 8)}</span>
              <span>to</span>
              <span className="text-primary font-semibold">{headSha.slice(0, 8)}</span>
            </div>
          )}

          <div className="flex flex-wrap gap-1.5">
            {changedFiles.map((file) => (
              <button
                key={file}
                type="button"
                onClick={() => setSelectedDiffFile(selectedDiffFile === file ? null : file)}
                className={`rounded border px-2 py-1 font-mono text-xs transition-colors ${
                  selectedDiffFile === file
                    ? 'border-accent bg-accent-soft text-accent'
                    : 'border-subtle bg-surface-raised text-primary hover:border-accent/40'
                }`}
              >
                {file}
              </button>
            ))}
          </div>

          {selectedDiffFile && diffData && (
            <div className="rounded-lg border border-subtle bg-canvas p-3 font-mono text-xs space-y-2">
              <div className="flex items-center justify-between text-muted border-b border-subtle pb-1">
                <span>{selectedDiffFile}</span>
                {diffData.truncated && (
                  <span className="rounded bg-warning-soft px-1.5 py-0.5 text-[10px] text-warning">
                    diff truncated (exceeds cap)
                  </span>
                )}
              </div>
              <pre className="overflow-x-auto text-[11px] leading-relaxed text-primary">
                {diffData.diff || diffData.raw || JSON.stringify(diffData, null, 2)}
              </pre>
            </div>
          )}
        </section>
      )}

      {/* VERIFY BLOCK */}
      {verifyFacet && (
        <section className="rounded-xl border border-subtle bg-surface p-4 space-y-2.5">
          <div className="flex items-center justify-between">
            <h3 className="text-xs font-bold uppercase tracking-wider text-muted">
              Verify Result
            </h3>
            <div className="flex items-center gap-2">
              <span
                className={`rounded px-2 py-0.5 font-mono text-[10px] font-semibold ${
                  verifyFacet.exit_code === 0
                    ? 'bg-success-soft text-success'
                    : 'bg-danger-soft text-danger'
                }`}
              >
                {verifyFacet.exit_code === 0 ? 'PASS' : `FAIL (${verifyFacet.exit_code})`}
              </span>
              <button
                type="button"
                data-debug-id="act-rerun-verify"
                onClick={handleRerunVerify}
                disabled={isVerifying}
                className="rounded border border-subtle bg-surface-raised px-2 py-0.5 text-[11px] font-semibold text-primary hover:bg-neutral-soft"
              >
                Re-run independent
              </button>
            </div>
          </div>

          {verifyFacet.output && (
            <details className="text-xs">
              <summary className="cursor-pointer text-muted hover:text-primary py-1">
                Show verify console output
              </summary>
              <pre className="mt-2 max-h-48 overflow-auto rounded bg-canvas p-3 font-mono text-[11px] text-primary border border-subtle whitespace-pre-wrap">
                {verifyFacet.output}
              </pre>
            </details>
          )}
        </section>
      )}

      {/* LATEST HANDOFF & OUTPUT */}
      {handoffFacet && (
        <section className="rounded-xl border border-subtle bg-surface p-4 space-y-2">
          <div className="flex items-center justify-between">
            <h3 className="text-xs font-bold uppercase tracking-wider text-muted">
              Latest Handoff
            </h3>
            <span className="font-mono text-[11px] text-faint">
              attempt {handoffFacet.attempt_no || attemptNo}
            </span>
          </div>

          {handoffFacet.summary && (
            <p className="text-xs leading-relaxed text-primary">
              {handoffFacet.summary}
            </p>
          )}

          {handoffFacet.next_steps && (
            <div className="text-xs text-muted pt-1">
              <span className="font-semibold text-primary block mb-0.5">Next Steps:</span>
              {handoffFacet.next_steps}
            </div>
          )}
        </section>
      )}

      {outputFacet && (
        <section className="rounded-xl border border-subtle bg-surface p-4 space-y-2">
          <div className="flex items-center justify-between">
            <h3 className="text-xs font-bold uppercase tracking-wider text-muted">
              Output Facet
            </h3>
            <span className="font-mono text-[11px] text-accent">
              {outputFacet.kind || 'output'}
            </span>
          </div>
          <pre className="max-h-48 overflow-auto rounded bg-canvas p-3 font-mono text-[11px] text-primary border border-subtle">
            {JSON.stringify(outputFacet, null, 2)}
          </pre>
          <div className="text-[11px] font-mono text-faint">
            Fetch via CLI: <span className="text-primary font-semibold">ham-ctl task fetch output:{task.task_id}</span>
          </div>
        </section>
      )}

      {/* REVIEWS & FINDINGS */}
      {findingsFacet && (
        <section className="rounded-xl border border-subtle bg-surface p-4 space-y-2.5">
          <h3 className="text-xs font-bold uppercase tracking-wider text-muted">
            Open Findings
          </h3>
          <pre className="overflow-auto rounded bg-canvas p-3 font-mono text-[11px] text-primary border border-subtle">
            {JSON.stringify(findingsFacet, null, 2)}
          </pre>
        </section>
      )}

      {/* FOLDED EVENT TIMELINE */}
      <section className="rounded-xl border border-subtle bg-surface p-4 space-y-3">
        <div className="flex items-center justify-between">
          <h3 className="text-xs font-bold uppercase tracking-wider text-muted">
            Event Timeline
          </h3>
          <span className="font-mono text-[11px] text-faint">
            {events.length} event{events.length === 1 ? '' : 's'}
          </span>
        </div>

        {events.length === 0 ? (
          <div className="text-xs text-muted italic">No events recorded yet.</div>
        ) : (
          <div className="space-y-2">
            {(showAllEvents ? events : events.slice(-6)).map((e, idx) => {
              const dateStr = e.ts_ms
                ? new Date(e.ts_ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
                : '';
              return (
                <div
                  key={idx}
                  className="flex items-start gap-2.5 text-xs border-b border-subtle/40 pb-2 last:border-0"
                >
                  <span className="h-1.5 w-1.5 rounded-full bg-accent mt-1.5 shrink-0" />
                  <span className="font-mono text-[11px] text-faint shrink-0">{dateStr}</span>
                  <div className="flex-1 min-w-0">
                    <span className="font-mono text-[11px] text-accent font-semibold mr-1.5">
                      {e.kind}
                    </span>
                    <span className="text-primary text-xs">
                      {typeof e.payload === 'string'
                        ? e.payload
                        : e.payload?.text || e.payload?.reason || e.payload?.note || JSON.stringify(e.payload || '')}
                    </span>
                  </div>
                </div>
              );
            })}

            {events.length > 6 && !showAllEvents && (
              <button
                type="button"
                onClick={() => setShowAllEvents(true)}
                className="w-full text-center py-1 text-xs text-accent font-medium hover:underline"
              >
                Show {events.length - 6} older events
              </button>
            )}
          </div>
        )}
      </section>

      {/* Answer Blocker Modal */}
      {showAnswerModal && (
        <div
          data-debug-id="answer-blocker-modal"
          className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
        >
          <div className="w-full max-w-md rounded-2xl border border-subtle bg-surface p-5 space-y-4 shadow-xl">
            <h3 className="text-sm font-bold text-primary">Answer Task Blocker</h3>
            <div className="rounded-lg bg-danger-soft p-3 text-xs text-danger">
              <span className="font-semibold block mb-0.5">Current blocker:</span>
              {task.blocked_on?.reason || 'Agent requested human clarification.'}
            </div>

            <textarea
              value={answerNote}
              onChange={(e) => setAnswerNote(e.target.value)}
              placeholder="Your answer / guidance for the worker agent…"
              rows={3}
              className="w-full rounded-lg border border-subtle bg-canvas p-2.5 text-xs text-primary outline-none focus:border-accent"
            />

            <div className="flex justify-end gap-2 border-t border-subtle pt-3">
              <button
                type="button"
                onClick={() => setShowAnswerModal(false)}
                className="px-3 py-1.5 text-xs text-muted hover:text-primary"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={handleAnswerBlocker}
                disabled={isAnswering}
                className="rounded-lg bg-accent px-4 py-1.5 text-xs font-semibold text-accent-fg hover:opacity-90"
              >
                {isAnswering ? 'Submitting…' : 'Submit Answer'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default TaskDetailView;
