import React from 'react';
import { Alert, Badge, Button, Text } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { useFetchTaskFacetQuery } from '../../api/endpoints/tasks';
import { DecryptedMarkdown } from '../vault';
import { describeHold, taskChangedFiles, taskHold } from './taskV2Types';
import { awaitingYourReview, blockedOnYou, isSupersededReview, youApproved } from './taskActions';
import type { TaskActionsApi } from './useTaskActions';
import { TaskComposer } from './TaskComposer';
import { TicketAgentAvatar } from './TicketAgentAvatar';
import type { TaskNames } from './taskNames';
import { blockReasonText, isRework, ticketAsk } from './ticketModel';
import { TicketCard } from './TicketCard';

/* Decision block (REQ-T3, REQ-T6) ------------------------------------ */

export function TicketDecisionBlock({ task, chainId, actions, names, now }: { task: TaskWire; chainId: string; actions: TaskActionsApi; names: TaskNames; now: number }) {
  const ask = ticketAsk(task);
  const hold = taskHold(task);
  const userApproved = youApproved(task);
  const reviewing = awaitingYourReview(task) || userApproved;
  const attemptNo = task.attempt_no || 1;
  const { data: handoffData } = useFetchTaskFacetQuery({ chainId, taskId: task.task_id, attemptNo, kind: 'handoff' }, { skip: !reviewing });
  const { data: vcsData } = useFetchTaskFacetQuery({ chainId, taskId: task.task_id, attemptNo, kind: 'vcs' }, { skip: !reviewing });
  const b: any = task.blocked_on || {};

  if (hold && !(b.kind === 'agent_not_running' || b.kind === 'dispatch')) {
    return (
      <TicketCard title={hold.checkpoint_requested ? 'Held · checkpoint requested' : 'Held'} debugId="task-hold-block" className="border-warning/40">
        {hold.reason ? <DecryptedMarkdown source={hold.reason} compact copyAll={false} data-debug-id="task-hold-reason" /> : null}
        <Text as="p" role="body-sm" tone="muted" data-debug-id="task-hold-meta">
          {[describeHold(hold, now, names), hold.checkpoint_requested ? 'the current holder was asked to hand off' : '', 'no new lease until released'].filter(Boolean).join(' · ')}
        </Text>
        <div className="mt-3">
          <Button size="sm" variant="secondary" disabled={actions.busy} data-debug-id="task-hold-release-btn" onClick={() => void actions.release()}>
            Release hold
          </Button>
        </div>
      </TicketCard>
    );
  }
  if (ask === 'agent_down') {
    return (
      <TicketCard title="Agent not running" debugId="ticket-view-agent-down" className="border-danger/40">
        <Text as="p" role="body-sm" className="text-primary">{String(b.reason || 'The agent could not start.')}</Text>
        <Text as="p" role="caption" tone="muted">Check the agent's bridge, provider and model. Updating its fleet settings retries the start.</Text>
      </TicketCard>
    );
  }
  if (ask === 'publish') {
    return (
      <TicketCard title="Not published" debugId="ticket-view-draft">
        <Text as="p" role="body-sm" tone="muted">Agents can't see this ticket until you publish it.</Text>
        <div className="mt-3">
          <Button size="sm" variant="primary" disabled={actions.busy} onClick={() => void actions.publish()} data-debug-id="ticket-view-publish-btn">
            Publish
          </Button>
        </div>
      </TicketCard>
    );
  }
  if (blockedOnYou(task) && !hold) {
    const question = String(b.question || blockReasonText(b.reason) || b.message || '').trim();
    return (
      <TicketCard title="Your answer" debugId="answer-blocker-block" className="border-warning/40">
        {question ? (
          <blockquote data-debug-id="answer-question" className="mb-3 border-l-2 border-warning pl-3 text-body-sm text-primary">
            <DecryptedMarkdown source={question} compact copyAll={false} />
          </blockquote>
        ) : (
          <Text as="p" role="body-sm" tone="muted">The agent is waiting on you but did not say what it needs. Check the latest comments, or ask it.</Text>
        )}
        <TaskComposer
          chainId={chainId}
          taskId={task.task_id}
          debugId="answer-composer"
          placeholder="Type your answer. You can paste or attach files."
          disabled={actions.busy}
          renderActions={({ body, canSend, reset }) => (
            <Button size="sm" variant="primary" disabled={!canSend} onClick={async () => { if (await actions.answer(body)) reset(); }} data-debug-id="answer-send-btn">
              Send answer
            </Button>
          )}
        />
      </TicketCard>
    );
  }
  if (!reviewing) return null;

  const rework = isRework(task);
  const req = task.requirements;
  const submitted = Number(req?.submitted_revision) || 0;
  const current = Number(req?.revision) || 0;
  const handoff = handoffData?.facet;
  const files = taskChangedFiles(vcsData?.facet);
  const votes = (task.reviews || []).filter((r) => !isSupersededReview(r) && r.reviewer !== 'user');
  const worker = task.brief?.assignee ? names.agent(String(task.brief.assignee)) : 'The worker';
  return (
    <TicketCard title="Your review" aside={rework ? <Badge tone="warning">Waiting for rework</Badge> : undefined} debugId="your-review-block" className="border-warning/40">
      <div className="flex flex-col gap-3">
        {rework && (
          <div data-debug-id="ticket-view-rework-notice">
            <Alert tone="warning" title="The requirements changed after this was submitted.">
              {worker} submitted attempt {task.attempt_no || 1} against rev {submitted || current - 1}; the requirements are now rev {current}, so this submission can't be approved. {worker} has been asked to rework it.
            </Alert>
          </div>
        )}
        {handoff?.summary && <DecryptedMarkdown source={String(handoff.summary)} compact copyAll={false} data-debug-id="your-review-summary" />}
        {files.length > 0 && <Text role="caption" tone="muted">{files.length} file{files.length === 1 ? '' : 's'} changed{handoff?.head ? ` · head ${String(handoff.head).slice(0, 7)}` : ''}</Text>}
        {votes.length > 0 && (
          <div className="flex flex-col gap-1" data-debug-id="ticket-view-votes">
            <Text as="span" role="overline" tone="faint">Votes</Text>
            <ul className="flex flex-wrap gap-x-4 gap-y-1">
              {votes.map((v, i) => {
                const label = names.participant(v.reviewer) || names.instance(v.reviewer_instance_id) || 'A reviewer';
                return (
                  <li key={`${v.reviewer}-${v.role}-${i}`} className="inline-flex items-center gap-1.5 text-body-sm">
                    <TicketAgentAvatar name={label} state="idle" />
                    <span className={rework ? 'text-faint line-through' : 'text-primary'}>{label}</span>
                    <span className="text-muted">{v.verdict === 'approve' ? 'approved' : 'requested changes'}</span>
                    {rework && <Badge tone="neutral">for rev {submitted || current - 1} · no longer counts</Badge>}
                  </li>
                );
              })}
            </ul>
          </div>
        )}
        <TaskComposer
          chainId={chainId}
          taskId={task.task_id}
          debugId="your-review-composer"
          placeholder={rework ? `Leave a note for the worker about the rework.` : 'What should change? Needed to request changes.'}
          requireText
          disabled={actions.busy}
          renderActions={({ body, canSend, reset }) => (
            <>
              {rework && <Text role="caption" tone="muted">Approve unlocks when the worker resubmits against rev {current}.</Text>}
              {userApproved ? (
                <Text role="caption" tone="muted" data-debug-id="your-review-approved">You approved</Text>
              ) : (
                <Button
                  size="sm"
                  variant="primary"
                  // Approve sends no note, so it waits until a typed one is sent or cleared.
                  disabled={actions.busy || rework || Boolean(body.trim())}
                  title={body.trim() && !rework ? 'Send your note with Request changes, or clear it to approve' : undefined}
                  onClick={() => void actions.approve()}
                  data-debug-id="ticket-view-approve-btn"
                >
                  Approve
                </Button>
              )}
              <Button
                size="sm"
                variant="secondary"
                disabled={!canSend}
                data-debug-id="ticket-view-request-changes-btn"
                onClick={async () => {
                  if (rework ? await actions.comment(body) : await actions.requestChanges(body)) reset();
                }}
              >
                {rework ? 'Post comment' : 'Request changes'}
              </Button>
            </>
          )}
        />
      </div>
    </TicketCard>
  );
}
