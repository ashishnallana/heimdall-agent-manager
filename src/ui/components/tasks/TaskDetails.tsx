import React, { useMemo, useState } from 'react';
import { Badge, Button, Select, Text, Textarea } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import type { TaskChainFleet } from '../../api/endpoints/taskChains';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import {
  useFetchCommitDiffQuery,
  useFetchTaskEventsQuery,
  useFetchTaskFacetQuery,
} from '../../api/endpoints/tasks';
import { getTaskPeople, normalizeTaskState } from './taskV2Types';
import { awaitingYourReview, blockedOnYou } from './taskActions';
import type { TaskActionsApi } from './useTaskActions';
import { EMPTY_TASK_NAMES, instanceAgentsFromEvents, withInstanceAgents, type TaskNames } from './taskNames';
import { describeTaskEvent } from './taskEvents';
import { HolderName } from './HolderName';

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

/** A titled block inside an expanded card: a heading, no border, no nested card. */
function Block({ title, aside, children, debugId }: { title: string; aside?: React.ReactNode; children: React.ReactNode; debugId?: string }) {
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

function FacetText({ value }: { value: unknown }) {
  if (value == null) return null;
  if (typeof value === 'string') return <p className="whitespace-pre-wrap text-xs leading-relaxed text-primary">{value}</p>;
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
        <li key={i}>{typeof f === 'string' ? f : f?.message || f?.text || f?.title || JSON.stringify(f)}</li>
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
  const { data: verifyData } = useFetchTaskFacetQuery({ chainId, taskId, attemptNo, kind: 'verify' }, skip);
  const { data: outputData } = useFetchTaskFacetQuery({ chainId, taskId, attemptNo, kind: 'output' }, skip);
  const { data: findingsData } = useFetchTaskFacetQuery({ chainId, taskId, attemptNo, kind: 'findings' }, skip);
  const { data: eventsData } = useFetchTaskEventsQuery({ chainId, taskId }, skip);
  const { data: bridgesData } = useListBridgesQuery();

  const events: any[] = eventsData?.events || [];
  const names = useMemo(() => withInstanceAgents(chainNames, instanceAgentsFromEvents(events)), [chainNames, events]);
  const people = getTaskPeople(task, chainFleets);

  const vcs = vcsData?.facet;
  const handoff = handoffData?.facet;
  const verify = verifyData?.facet;
  const output = outputData?.facet;
  const findings = findingsData?.facet;
  const changedFiles: string[] = Array.isArray(vcs?.files) ? vcs.files : [];

  const [diffFile, setDiffFile] = useState<string | null>(null);
  const { data: diffData } = useFetchCommitDiffQuery(
    { chainId, directoryId: vcs?.directory_id || 'default', base: vcs?.base || '', head: vcs?.head || '', path: diffFile || '' },
    { skip: !diffFile || !vcs?.base || !vcs?.head },
  );

  const [findingsText, setFindingsText] = useState('');
  const [answerText, setAnswerText] = useState('');
  const [commentText, setCommentText] = useState('');
  const [showAllEvents, setShowAllEvents] = useState(false);

  const bridges: any[] = bridgesData?.bridges || [];
  const bridgeOptions = [
    { value: '', text: 'Fleet default' },
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
  const reviewerText = people.reviewersByRole.length
    ? people.reviewersByRole
        .map(({ role, agents }) => `${role}: ${agents.length ? agents.map(names.agent).join(', ') : 'nobody in the fleet'}`)
        .join(' · ')
    : 'None';

  const visibleEvents = showAllEvents ? events : events.slice(-TIMELINE_PREVIEW);

  return (
    <div data-debug-id={`task-details-${taskId}`} className="space-y-4 border-t border-subtle px-3 pb-3 pt-3 text-xs">
      {awaitingYourReview(task) && (
        <Block title="Your review" debugId="your-review-block">
          {handoff?.summary && <p className="leading-relaxed text-primary">{handoff.summary}</p>}
          {changedFiles.length > 0 && (
            <Text role="caption" tone="muted">
              {changedFiles.length} file{changedFiles.length === 1 ? '' : 's'} changed
            </Text>
          )}
          <Textarea
            value={findingsText}
            onChange={setFindingsText}
            placeholder="Findings (needed when you request changes)"
            rows={2}
            size="sm"
          />
          <div className="flex flex-wrap items-center gap-2">
            <Button size="sm" variant="primary" disabled={actions.busy} onClick={() => void actions.approve()}>
              Approve
            </Button>
            <Button
              size="sm"
              variant="secondary"
              disabled={actions.busy}
              onClick={async () => {
                if (await actions.requestChanges(findingsText)) setFindingsText('');
              }}
            >
              Request changes
            </Button>
          </div>
        </Block>
      )}

      {blockedOnYou(task) && (
        <Block title="Waiting on your answer" debugId="answer-blocker-block">
          {(task.blocked_on as any)?.reason && <p className="text-primary">{(task.blocked_on as any).reason}</p>}
          <Textarea value={answerText} onChange={setAnswerText} placeholder="Your answer" rows={2} size="sm" />
          <div>
            <Button
              size="sm"
              variant="primary"
              disabled={actions.busy}
              onClick={async () => {
                if (await actions.answer(answerText)) setAnswerText('');
              }}
            >
              Send answer
            </Button>
          </div>
        </Block>
      )}

      <Block title="Brief">
        {task.brief?.goal || task.description ? (
          <p className="leading-relaxed text-primary">{task.brief?.goal || task.description}</p>
        ) : (
          <Text role="caption" tone="faint">
            No goal yet.
          </Text>
        )}
        {task.brief?.acceptance && task.brief.acceptance.length > 0 && (
          <ul className="list-disc space-y-0.5 pl-4 text-primary">
            {task.brief.acceptance.map((item, i) => (
              <li key={i}>{item}</li>
            ))}
          </ul>
        )}
        {task.brief?.verify && (
          <code className="block rounded-md bg-canvas px-2 py-1 font-mono text-[11px] text-primary">{task.brief.verify}</code>
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
          </div>
        )}
      </Block>

      <Block title="Who works on it">
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
          <dd data-debug-id="task-detail-reviewers" className="text-primary">
            {reviewerText}
            {task.requires_user_approval ? ' + you' : ''}
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

      {verify && (
        <Block
          title="Verify"
          aside={
            <div className="flex items-center gap-2">
              <Badge tone={verify.exit_code === 0 ? 'success' : 'danger'}>
                {verify.exit_code === 0 ? 'Passed' : `Failed (exit ${verify.exit_code})`}
              </Badge>
              <Button size="sm" variant="ghost" disabled={actions.busy} onClick={() => void actions.rerunVerify()}>
                Re-run
              </Button>
            </div>
          }
        >
          {verify.output && (
            <details>
              <summary className="cursor-pointer text-muted hover:text-primary">Output</summary>
              <pre className="mt-1 max-h-48 overflow-auto whitespace-pre-wrap rounded-md bg-canvas p-2 font-mono text-[11px] text-primary">
                {verify.output}
              </pre>
            </details>
          )}
        </Block>
      )}

      {handoff && (handoff.summary || handoff.next_steps) && !awaitingYourReview(task) && (
        <Block title="Latest handoff" aside={<Text role="caption" tone="faint">attempt {handoff.attempt_no || attemptNo}</Text>}>
          {handoff.summary && <p className="leading-relaxed text-primary">{handoff.summary}</p>}
          {handoff.next_steps && <p className="leading-relaxed text-muted">Next: {handoff.next_steps}</p>}
        </Block>
      )}

      {changedFiles.length > 0 && (
        <Block title="Changes" aside={<Text role="caption" tone="faint">{changedFiles.length} files</Text>}>
          <div className="flex flex-wrap gap-1">
            {changedFiles.map((file) => (
              <Button
                key={file}
                size="sm"
                variant={diffFile === file ? 'secondary' : 'ghost'}
                onClick={() => setDiffFile(diffFile === file ? null : file)}
              >
                <span className="font-mono">{file}</span>
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
        <Block title="Output">
          <FacetText value={output.summary || output.text || output} />
          <Text role="caption" tone="faint">
            CLI: ham-ctl task fetch output:{taskId}
          </Text>
        </Block>
      )}

      {findings && (
        <Block title="Review findings">
          <Findings value={findings} />
        </Block>
      )}

      <Block
        title="Timeline"
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
            {visibleEvents.map((e, i) => (
              <li key={e.event_id ?? i} data-debug-id="task-timeline-event" className="flex gap-2">
                <span className="shrink-0 whitespace-nowrap font-mono text-[11px] text-faint">
                  {e.ts_ms ? new Date(e.ts_ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : ''}
                </span>
                <span className="min-w-0 text-primary">{describeTaskEvent(e, names).text}</span>
              </li>
            ))}
          </ol>
        )}
      </Block>

      <Block title="Comment">
        <Textarea value={commentText} onChange={setCommentText} placeholder="Leave a note on this task" rows={2} size="sm" />
        <div>
          <Button
            size="sm"
            variant="secondary"
            disabled={actions.busy || !commentText.trim()}
            onClick={async () => {
              if (await actions.comment(commentText)) setCommentText('');
            }}
          >
            Post comment
          </Button>
        </div>
      </Block>
    </div>
  );
};

export default TaskDetails;
