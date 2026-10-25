import React, { useMemo, useState } from 'react';
import { Button, Icon, Select, Text } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import type { TaskChainFleet } from '../../api/endpoints/taskChains';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import {
  useFetchCommitDiffQuery,
  useFetchTaskEventsQuery,
  useFetchTaskFacetQuery,
} from '../../api/endpoints/tasks';
import { getTaskPeople, normalizeTaskState, taskChangedFiles } from './taskV2Types';
import { awaitingYourReview, blockedOnYou, reviewVotes, sameReviewer, voteFor, youApproved, type ReviewVerdict } from './taskActions';
import type { TaskActionsApi } from './useTaskActions';
import { EMPTY_TASK_NAMES, instanceAgentsFromEvents, participantLabel, withInstanceAgents, type TaskNames } from './taskNames';
import { useParticipantLabel } from './ParticipantName';
import { describeTaskEvent, reviewsPostedForAttempt, whoById } from './taskEvents';
import { DecryptedMarkdown, VaultText } from '../vault';
import { HolderName } from './HolderName';
import { ReviewVoteMark } from './ReviewVoteMark';
import { describeEffectivePlacement, taskEffectivePlacement } from './fleetSelection';
import { TaskComposer } from './TaskComposer';
import { TaskCommentsThread } from '../taskchain/TaskCommentsThread';

export interface TaskDetailsProps {
  chainId: string;
  task: TaskWire;
  actions: TaskActionsApi;
  chainFleets?: TaskChainFleet[];
  names?: TaskNames;
  /** Opens another task of the chain (dependency links). */
  onSelectTask?: (taskId: string) => void;
}

const TIMELINE_PREVIEW = 6;

/** What the blocked agent asked: hubs and agents use reason, question or message. */
function blockerQuestion(task: TaskWire): string {
  const b: any = task.blocked_on || {};
  return String(b.question || b.reason || b.message || '').trim();
}

/**
 * Text an agent or person wrote (goal, acceptance, handoff, findings): rendered
 * through the shared safe Markdown renderer so headings, paragraphs, lists and
 * code survive instead of collapsing into one line. Vault tokens are decrypted
 * (or masked) first.
 */
function AuthoredText({ value, debugId }: { value: string; debugId?: string }) {
  return <DecryptedMarkdown source={value} compact copyAll={false} data-debug-id={debugId} />;
}

/**
 * A titled block inside an expanded card: a heading, no border, no nested card.
 * Decisions (Review decision, Answer) stay open; the informational blocks are
 * collapsible and closed by default (plan REQ-UI-8), so an expanded card stays
 * calm until you open what you want to read.
 */
function Block({
  title,
  aside,
  children,
  debugId,
  collapsible = false,
}: {
  title: string;
  aside?: React.ReactNode;
  children: React.ReactNode;
  debugId?: string;
  collapsible?: boolean;
}) {
  if (!collapsible) {
    return (
      <div data-debug-id={debugId} className="space-y-1.5">
        <div className="flex items-center justify-between gap-2">
          <Text as="h4" role="overline" tone="muted">
            {title}
          </Text>
          {aside}
        </div>
        {children}
      </div>
    );
  }
  return (
    <details data-debug-id={debugId} className="group space-y-1.5">
      <summary className="flex cursor-pointer list-none items-center justify-between gap-2 [&::-webkit-details-marker]:hidden">
        <span className="inline-flex items-center gap-1">
          <Icon name="chevron-right" size={12} className="text-muted transition-transform group-open:rotate-90" />
          <Text as="h4" role="overline" tone="muted">
            {title}
          </Text>
        </span>
        {aside}
      </summary>
      <div className="space-y-1.5 pl-4">{children}</div>
    </details>
  );
}

/**
 * A verify result recorded before verification commands were removed (D2).
 * Read-only history: collapsed, neutral (no pass/fail badge), no re-run. Gates,
 * packs and alerts never read it.
 */
export function LegacyVerifyRecord({ facet, skipReason }: { facet: any; skipReason?: unknown }) {
  const command = typeof facet?.command === 'string' ? facet.command : '';
  const exitCode = typeof facet?.exit_code === 'number' ? facet.exit_code : null;
  const output = String(facet?.output || facet?.summary || '');
  const skipped = typeof skipReason === 'string' ? skipReason.trim() : '';
  return (
    <Block title="Legacy verification record" collapsible debugId="task-details-legacy-verify">
      <Text as="p" role="caption" tone="faint">
        Recorded before verification commands were removed. Kept as history only; it does not affect review.
      </Text>
      <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
        {command && (
          <>
            <dt className="text-muted">Command</dt>
            <dd className="min-w-0 break-all font-mono text-[11px] text-primary">{command}</dd>
          </>
        )}
        {exitCode !== null && (
          <>
            <dt className="text-muted">Exit code</dt>
            <dd className="font-mono text-[11px] text-primary">{exitCode}</dd>
          </>
        )}
        {skipped && (
          <>
            <dt className="text-muted">Skipped at submit</dt>
            <dd className="text-primary">
              <VaultText value={skipped} />
            </dd>
          </>
        )}
      </dl>
      {output && (
        <pre className="max-h-48 overflow-auto whitespace-pre-wrap rounded-md bg-canvas p-2 font-mono text-[11px] text-muted">{output}</pre>
      )}
    </Block>
  );
}

/** A reviewer with their verdict on the current attempt: ✓ approved, ✗ changes requested. */
function ReviewerVote({ id, names, label: fixedLabel, verdict }: { id: string; names: TaskNames; label?: string; verdict?: ReviewVerdict }) {
  const resolved = useParticipantLabel(id, names);
  const label = fixedLabel || resolved;
  const title = verdict === 'approve' ? 'approved' : verdict === 'request_changes' ? 'requested changes' : 'waiting for review';
  return (
    <span data-debug-id={`task-detail-reviewer-vote-${id}`} className="inline-flex items-center gap-0.5" title={`${label}: ${title}`}>
      <ReviewVoteMark verdict={verdict} />
      {label}
    </span>
  );
}

function FacetText({ value }: { value: unknown }) {
  if (value == null) return null;
  if (typeof value === 'string') return <AuthoredText value={value} />;
  return (
    <pre className="max-h-48 overflow-auto rounded-md bg-canvas p-2 font-mono text-[11px] leading-relaxed text-primary">
      {JSON.stringify(value, null, 2)}
    </pre>
  );
}

/** Findings are usually a list of strings or {message|text|title} objects. */
function Findings({ value }: { value: any }) {
  const list: unknown[] = Array.isArray(value) ? value : Array.isArray(value?.findings) ? value.findings : [];
  if (list.length === 0) return <FacetText value={value} />;
  return (
    <ul className="list-disc space-y-1 pl-4 text-xs text-primary">
      {list.map((f: any, i) => (
        <li key={i}>
          <AuthoredText value={typeof f === 'string' ? f : String(f?.message || f?.text || f?.title || JSON.stringify(f))} />
        </li>
      ))}
    </ul>
  );
}

/**
 * The expanded body of a task card (plan REQ-UI-8): what to decide, the brief,
 * who works it, and the trail of how it is being done. Read-only except the
 * human verbs. Mounted only while the card is open, so its queries run lazily.
 */
export const TaskDetails: React.FC<TaskDetailsProps> = ({
  chainId,
  task,
  actions,
  chainFleets = [],
  names: chainNames = EMPTY_TASK_NAMES,
  onSelectTask,
}) => {
  const taskId = task.task_id;
  const state = normalizeTaskState(task.state);
  const attemptNo = task.attempt_no || 1;
  const skip = { skip: !chainId || !taskId };

  const { data: vcsData } = useFetchTaskFacetQuery({ chainId, taskId, attemptNo, kind: 'vcs' }, skip);
  const { data: handoffData } = useFetchTaskFacetQuery({ chainId, taskId, attemptNo, kind: 'handoff' }, skip);
  // Legacy only (D2): attempts from before verification commands were removed
  // may carry a verify facet. Nothing writes it any more; it renders read-only.
  const { data: legacyVerifyData } = useFetchTaskFacetQuery({ chainId, taskId, attemptNo, kind: 'verify' }, skip);
  const { data: outputData } = useFetchTaskFacetQuery({ chainId, taskId, attemptNo, kind: 'output' }, skip);
  const { data: eventsData } = useFetchTaskEventsQuery({ chainId, taskId }, skip);
  const { data: bridgesData } = useListBridgesQuery();

  const events: any[] = eventsData?.events || [];
  const names = useMemo(() => withInstanceAgents(chainNames, instanceAgentsFromEvents(events)), [chainNames, events]);
  const people = getTaskPeople(task, chainFleets);

  const vcs = vcsData?.facet;
  const handoff = handoffData?.facet;
  const legacyVerify = legacyVerifyData?.facet;
  const output = outputData?.facet;
  // Review findings ride on review_posted events (there is no findings facet).
  const reviews = useMemo(() => reviewsPostedForAttempt(events, attemptNo), [events, attemptNo]);
  const changedFiles = taskChangedFiles(vcs);

  const [diffFile, setDiffFile] = useState<string | null>(null);
  const { data: diffData } = useFetchCommitDiffQuery(
    { chainId, directoryId: vcs?.directory_id || 'default', base: vcs?.base || '', head: vcs?.head || '', path: diffFile || '' },
    { skip: !diffFile || !vcs?.base || !vcs?.head },
  );

  // TaskCommentsThread reads the legacy camelCase summary shape.
  const commentSummary = task.comment_summary
    ? {
        count: Number(task.comment_summary.count || 0),
        lastCommentAt: String(task.comment_summary.last_comment_at || ''),
        lastCommentAuthorAgentInstanceId: String(task.comment_summary.last_comment_author_agent_instance_id || ''),
        lastCommentPreview: String(task.comment_summary.last_comment_preview || ''),
      }
    : null;
  const [showAllEvents, setShowAllEvents] = useState(false);

  const bridges: any[] = bridgesData?.bridges || [];
  // Unpinned, the task runs where its fleet row resolves; say where (plan REQ-UI-12).
  const unpinned = describeEffectivePlacement(taskEffectivePlacement({ ...task, bridge_id: '' }, chainFleets), names.bridge);
  const bridgeOptions = [
    { value: '', text: unpinned.bridge ? `Fleet default: ${unpinned.bridge}` : "Fleet default: the worker's fleet row decides" },
    ...bridges.map((b: any) => ({
      value: String(b.id || b.bridge_id || ''),
      text: `${b.name || names.bridge(String(b.id || ''))}${b.status === 'online' || b.connected ? '' : ' (offline)'}`,
    })),
  ];

  const workerText = people.assignee
    ? names.agent(people.assignee)
    : people.workers.length
      ? `Any worker: ${people.workers.map(names.agent).join(', ')}`
      : 'No worker in the fleet';
  // Votes and assignments meet on the durable agent id (REQ-TV2-6): a legacy
  // assignment or vote that carries an instance id still lines up.
  const votes = useMemo(() => reviewVotes(task, names), [task, names]);
  // Voters outside the fleet's reviewer list (a coordinator reviewing) still show.
  const extraVoters = Array.from(votes.keys()).filter((key) => key !== 'user' && !people.reviewers.some((id) => sameReviewer(votes, key, id, names)));
  const userApproved = youApproved(task);
  const pendingReviewers = people.reviewers.filter((id) => voteFor(votes, id, names) !== 'approve');
  const vote = (id: string) => <ReviewerVote key={id} id={id} names={names} verdict={voteFor(votes, id, names)} />;
  const reviewerGroups: React.ReactNode[] = [
    ...(people.named.length ? [<span key="named" className="inline-flex flex-wrap gap-x-2">{people.named.map(vote)}</span>] : []),
    ...people.reviewersByRole.map(({ role, agents }) => (
      <span key={`role-${role}`} className="inline-flex flex-wrap items-center gap-x-2">
        <span className="text-muted">{role} role:</span>
        {agents.length ? agents.map(vote) : <span className="text-muted">nobody holds it</span>}
      </span>
    )),
    ...extraVoters.map((id) => <ReviewerVote key={id} id={id} names={names} verdict={voteFor(votes, id, names)} />),
    ...(task.requires_user_approval || votes.has('user') ? [<ReviewerVote key="user" id="user" names={names} label="you" verdict={votes.get('user')} />] : []),
  ];

  const visibleEvents = showAllEvents ? events : events.slice(-TIMELINE_PREVIEW);

  return (
    <div data-debug-id={`task-details-${taskId}`} className="space-y-4 border-t border-subtle pb-4 pl-5 pr-3 pt-3 text-xs">
      {(task.blocked_on?.kind === 'dispatch' || task.blocked_on?.kind === 'agent_not_running') && (
        <Block title="Agent not running">
          <p className="leading-relaxed text-primary">{task.blocked_on.reason}</p>
          <Text as="p" role="body-sm" tone="muted">Check the agent’s bridge, provider, and model settings. Updating its fleet settings retries dispatch.</Text>
        </Block>
      )}
      {(awaitingYourReview(task) || userApproved) && (
        <Block title="Review decision" debugId="your-review-block">
          {handoff?.summary && <AuthoredText value={handoff.summary} debugId="your-review-summary" />}
          {changedFiles.length > 0 && (
            <Text role="caption" tone="muted">
              {changedFiles.length} file{changedFiles.length === 1 ? '' : 's'} changed
            </Text>
          )}
          <TaskComposer
            chainId={chainId}
            taskId={taskId}
            debugId="your-review-composer"
            placeholder="What should change? Needed to request changes."
            requireText
            disabled={actions.busy}
            renderActions={({ body, canSend, reset }) => (
              <>
                {userApproved ? (
                  <Text role="caption" tone="muted" data-debug-id="your-review-approved">
                    You approved
                    {pendingReviewers.length ? ` · waiting on ${pendingReviewers.map((id) => participantLabel(names, id)).join(', ')}` : ''}
                  </Text>
                ) : (
                  <Button size="sm" variant="primary" disabled={actions.busy} onClick={() => void actions.approve()}>
                    Approve
                  </Button>
                )}
                <Button
                  size="sm"
                  variant="secondary"
                  disabled={!canSend}
                  onClick={async () => {
                    if (await actions.requestChanges(body)) reset();
                  }}
                >
                  Request changes
                </Button>
              </>
            )}
          />
        </Block>
      )}

      {blockedOnYou(task) && (
        <Block title="Waiting on your answer" debugId="answer-blocker-block">
          {blockerQuestion(task) ? (
            <blockquote data-debug-id="answer-question" className="rounded-md border-l-2 border-accent bg-accent-soft px-3 py-2 text-body-sm text-primary">
              <AuthoredText value={blockerQuestion(task)} />
            </blockquote>
          ) : (
            <Text as="p" role="body-sm" tone="muted">
              The agent is waiting on you but did not say what it needs. Check the latest comments, or ask it.
            </Text>
          )}
          <TaskComposer
            chainId={chainId}
            taskId={taskId}
            debugId="answer-composer"
            placeholder="Type your answer. You can paste or attach files."
            disabled={actions.busy}
            renderActions={({ body, canSend, reset }) => (
              <Button
                size="sm"
                variant="primary"
                disabled={!canSend}
                onClick={async () => {
                  if (await actions.answer(body)) reset();
                }}
              >
                Send answer
              </Button>
            )}
          />
        </Block>
      )}

      <Block title="Brief" collapsible debugId="task-details-brief">
        {task.brief?.goal || task.description ? (
          <AuthoredText value={String(task.brief?.goal || task.description)} debugId="task-details-goal" />
        ) : (
          <Text role="caption" tone="faint">
            No goal yet.
          </Text>
        )}
        {task.brief?.acceptance && task.brief.acceptance.length > 0 && (
          <ul className="list-disc space-y-0.5 pl-4 text-primary">
            {task.brief.acceptance.map((item, i) => (
              <li key={i}>
                <AuthoredText value={String(item)} />
              </li>
            ))}
          </ul>
        )}
        {task.depends_on && task.depends_on.length > 0 && (
          <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
            <Text role="caption" tone="muted">
              Waits for
            </Text>
            {task.depends_on.map((depId) => (
              <Button key={depId} size="sm" variant="ghost" title={depId} onClick={() => onSelectTask?.(depId)}>
                {names.task(depId)}
              </Button>
            ))}
            {/* The hub puts each one's latest handoff in this task's pack. */}
            <Text as="p" role="caption" tone="faint" className="w-full" data-debug-id="task-details-receives-handoffs">
              The agent receives their handoffs: summary, decisions, dead ends, output and last commit.
            </Text>
          </div>
        )}
      </Block>

      <Block title="Who works on it" collapsible debugId="task-details-people">
        <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
          <dt className="text-muted">Assignee</dt>
          <dd data-debug-id="task-detail-assignee" className="text-primary">
            {workerText}
            {people.holder && (
              <span className="text-muted">
                {' '}
                · now <HolderName instanceId={people.holder} names={names} />
              </span>
            )}
          </dd>
          <dt className="text-muted">Reviewers</dt>
          <dd data-debug-id="task-detail-reviewers" className="flex flex-wrap items-center gap-x-3 gap-y-1 text-primary">
            {reviewerGroups.length ? reviewerGroups : 'None'}
          </dd>
          <dt className="self-center text-muted">Bridge</dt>
          <dd>
            <Select
              size="sm"
              value={task.bridge_id || ''}
              onChange={(v) => void actions.pinBridge(v)}
              options={bridgeOptions}
              disabled={actions.busy || state === 'done' || state === 'cancelled'}
              aria-label="Bridge pin"
            />
          </dd>
        </dl>
      </Block>

      {legacyVerify && <LegacyVerifyRecord facet={legacyVerify} skipReason={handoff?.skip_verify_reason} />}

      {handoff && (handoff.summary || handoff.next_steps) && !awaitingYourReview(task) && !userApproved && (
        <Block title={state === 'done' ? 'Result' : 'Latest handoff'} collapsible debugId="task-details-handoff" aside={<Text role="caption" tone="faint">attempt {handoff.attempt_no || attemptNo}</Text>}>
          {handoff.summary && <AuthoredText value={handoff.summary} debugId="task-details-handoff-summary" />}
          {handoff.next_steps && (
            <div className="space-y-0.5">
              <Text as="p" role="caption" tone="muted">
                Next
              </Text>
              <AuthoredText value={handoff.next_steps} />
            </div>
          )}
        </Block>
      )}

      {changedFiles.length > 0 && (
        <Block title="Changes" collapsible debugId="task-details-changes" aside={<Text role="caption" tone="faint">{changedFiles.length} files</Text>}>
          <div className="flex flex-wrap gap-1">
            {changedFiles.map(({ path, add, del }) => (
              <Button
                key={path}
                size="sm"
                variant={diffFile === path ? 'secondary' : 'ghost'}
                onClick={() => setDiffFile(diffFile === path ? null : path)}
              >
                <span className="font-mono">{path}</span>
                {typeof add === 'number' && typeof del === 'number' && (
                  <span className="ml-1 font-mono text-faint">+{add} -{del}</span>
                )}
              </Button>
            ))}
          </div>
          {diffFile && diffData && (
            <pre className="max-h-72 overflow-auto rounded-md bg-canvas p-2 font-mono text-[11px] leading-relaxed text-primary">
              {diffData.diff || diffData.raw || ''}
              {diffData.truncated ? '\n\n(diff truncated)' : ''}
            </pre>
          )}
        </Block>
      )}

      {output && (
        <Block title="Output" collapsible debugId="task-details-output">
          <FacetText value={output.summary || output.text || output} />
          <Text role="caption" tone="faint">
            CLI: ham-ctl task fetch output:{taskId}
          </Text>
        </Block>
      )}

      {reviews.length > 0 && (
        <Block title="Review findings" collapsible debugId="task-details-findings">
          <div className="space-y-2">
            {reviews.map((r, i) => (
              <div key={i} className="space-y-1">
                <Text role="caption" tone="muted">
                  {whoById(r.reviewer, names)} · {r.verdict === 'approve' ? 'approved' : 'requested changes'}
                </Text>
                {r.summary && <FacetText value={r.summary} />}
                {r.findings != null && <Findings value={r.findings} />}
              </div>
            ))}
          </div>
        </Block>
      )}

      <Block
        title="Timeline"
        collapsible
        debugId="task-details-timeline"
        aside={
          events.length > TIMELINE_PREVIEW ? (
            <Button size="sm" variant="ghost" onClick={() => setShowAllEvents((v) => !v)}>
              {showAllEvents ? 'Show recent' : `Show all ${events.length}`}
            </Button>
          ) : null
        }
      >
        {events.length === 0 ? (
          <Text role="caption" tone="faint">
            Nothing has happened yet.
          </Text>
        ) : (
          <ol className="space-y-1">
            {visibleEvents.map((e, i) => {
              const description = describeTaskEvent(e, names);
              return (
              <li key={e.event_id ?? i} data-debug-id="task-timeline-event" className="flex gap-2">
                <span className="shrink-0 whitespace-nowrap font-mono text-[11px] text-faint">
                  {e.ts_ms ? new Date(e.ts_ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : ''}
                </span>
                <details className="min-w-0 flex-1">
                  <summary className="cursor-pointer list-none text-primary [&::-webkit-details-marker]:hidden">
                    {description.text}
                    <span className="ml-1.5 text-[11px] text-faint underline decoration-dotted">Details</span>
                  </summary>
                    {description.legacyVerify && (
                      <span data-debug-id="task-timeline-legacy-verify" className="mt-1 block text-[11px] text-muted">
                        Legacy verification record: {description.legacyVerify.auto ? 'submitted automatically' : 'skipped at submit'}
                        {description.legacyVerify.skipReason ? (
                          <>
                            {' '}
                            (<VaultText value={description.legacyVerify.skipReason} />)
                          </>
                        ) : null}
                      </span>
                    )}
                  <pre className="mt-1 max-h-40 overflow-auto rounded-md bg-canvas p-2 font-mono text-[11px] text-muted">
                    {JSON.stringify({ kind: e.kind, actor: e.actor_kind, ...(e.payload && typeof e.payload === 'object' ? { payload: e.payload } : {}) }, null, 2)}
                  </pre>
                </details>
              </li>
              );
            })}
          </ol>
        )}
      </Block>

      <Block
        title="Comments"
        collapsible
        debugId="task-details-comments"
        aside={
          task.comment_summary?.count ? (
            <Text role="caption" tone="faint">
              {task.comment_summary.count}
            </Text>
          ) : null
        }
      >
        <TaskCommentsThread chainId={chainId} taskId={taskId} summary={commentSummary} enabled hideHeading />
        <TaskComposer
          chainId={chainId}
          taskId={taskId}
          debugId="comment-composer"
          placeholder="Leave a comment. Paste or attach images and files."
          disabled={actions.busy}
          renderActions={({ body, canSend, reset }) => (
            <Button
              size="sm"
              variant="secondary"
              disabled={!canSend}
              onClick={async () => {
                if (await actions.comment(body)) reset();
              }}
            >
              Post comment
            </Button>
          )}
        />
      </Block>
    </div>
  );
};

export default TaskDetails;
