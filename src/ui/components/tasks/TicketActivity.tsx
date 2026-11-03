import React, { useEffect, useState } from 'react';
import { Badge, Button, Tab, Tabs, TabsList, Text } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { useFetchTaskEventsQuery } from '../../api/endpoints/tasks';
import { TaskCommentsThread } from '../taskchain/TaskCommentsThread';
import { VaultText } from '../vault/VaultText';
import { describeTaskEvent, type TaskEventWire } from './taskEvents';
import type { TaskNames } from './taskNames';
import { TicketAgentAvatar } from './TicketAgentAvatar';
import { diffAcceptance, formatAgo, type RequirementRevisionEntry } from './ticketModel';
import { EditedText } from './RequirementsEditorModal';

export type ActivityTab = 'all' | 'comments' | 'requirements' | 'handoffs' | 'raw';

const HANDOFF_KINDS = new Set(['submitted', 'handoff']);
const PAGE = 50;

export interface TicketActivityProps {
  chainId: string;
  task: TaskWire;
  names: TaskNames;
  now: number;
  /** Parsed requirement history (gap G1); null when it did not parse. */
  history: RequirementRevisionEntry[] | null;
  rawHistory: string;
  tab: ActivityTab;
  onTabChange: (tab: ActivityTab) => void;
  /** The comment composer, shown at the top of the feed on desktop. */
  composer?: React.ReactNode;
}

/**
 * The ticket's Activity (REQ-T7): All, Comments, Requirement changes, Handoffs
 * and Raw events, newest first. Each feed fetches the first time its tab opens
 * (REQ-L1 lazy sections); requirement changes come from the task already loaded.
 */
export const TicketActivity: React.FC<TicketActivityProps> = ({ chainId, task, names, now, history, rawHistory, tab, onTabChange, composer }) => {
  const taskId = task.task_id;
  const [opened, setOpened] = useState<Record<ActivityTab, boolean>>({ all: false, comments: false, requirements: false, handoffs: false, raw: false });
  useEffect(() => {
    setOpened((o) => (o[tab] ? o : { ...o, [tab]: true }));
  }, [tab]);
  const needsEvents = opened.all || opened.handoffs || opened.raw;
  const commentCount = Number(task.comment_summary?.count || 0);
  const changes = history || [];

  return (
    <section aria-label="Activity" data-debug-id="ticket-activity" className="flex flex-col gap-3">
      <Text as="h3" role="title" className="text-primary">Activity</Text>
      <Tabs value={tab} onChange={(v) => onTabChange(v as ActivityTab)} variant="underline">
        <TabsList label="Activity feeds" className="overflow-x-auto">
          <Tab value="all" data-debug-id="ticket-activity-tab-all">All</Tab>
          <Tab value="comments" data-debug-id="ticket-activity-tab-comments">Comments {commentCount ? <span className="tabular-nums text-faint">{commentCount}</span> : null}</Tab>
          <Tab value="requirements" data-debug-id="ticket-activity-tab-requirements">Requirement changes {changes.length ? <span className="tabular-nums text-faint">{changes.length}</span> : null}</Tab>
          <Tab value="handoffs" data-debug-id="ticket-activity-tab-handoffs">Handoffs</Tab>
          <Tab value="raw" data-debug-id="ticket-activity-tab-raw">Raw events</Tab>
        </TabsList>
      </Tabs>
      {composer}
      {tab === 'comments' && (
        <TaskCommentsThread
          chainId={chainId}
          taskId={taskId}
          enabled={opened.comments}
          hideHeading
          summary={
            task.comment_summary
              ? {
                  count: commentCount,
                  lastCommentAt: String(task.comment_summary.last_comment_at || ''),
                  lastCommentAuthorAgentInstanceId: String(task.comment_summary.last_comment_author_agent_instance_id || ''),
                  lastCommentPreview: String(task.comment_summary.last_comment_preview || ''),
                }
              : null
          }
        />
      )}
      {tab === 'requirements' && <RequirementChanges history={history} rawHistory={rawHistory} names={names} now={now} truncated={Boolean(task.requirements?.history_truncated)} />}
      {(tab === 'all' || tab === 'handoffs' || tab === 'raw') && needsEvents && (
        <EventFeed chainId={chainId} taskId={taskId} names={names} now={now} mode={tab} />
      )}
    </section>
  );
};

function actorLabel(names: TaskNames, kind: string, id: string): string {
  if (kind === 'user') return 'You';
  if (kind === 'hub' || kind === 'system') return 'Hub';
  return (id && (names.participant(id) || names.instance(id))) || (kind === 'coordinator' ? 'Coordinator' : 'An agent');
}

/** Requirement revisions, newest first, each with its reason and diff. */
function RequirementChanges({ history, rawHistory, names, now, truncated }: { history: RequirementRevisionEntry[] | null; rawHistory: string; names: TaskNames; now: number; truncated: boolean }) {
  if (history === null) {
    // G1 fallback: the text did not parse, so show it as the hub wrote it.
    return (
      <pre data-debug-id="task-requirements-history" className="max-h-96 overflow-auto whitespace-pre-wrap rounded-md bg-canvas p-3 font-mono text-code-sm text-muted">
        <VaultText value={rawHistory} />
      </pre>
    );
  }
  if (!history.length) return <Text role="caption" tone="faint">The requirements have not changed since the ticket was created.</Text>;
  return (
    <ol data-debug-id="task-requirements-history" className="flex flex-col gap-4">
      {history.map((h) => {
        const diff = diffAcceptance(h.before.acceptance, h.after.acceptance);
        const who = actorLabel(names, h.actorKind, h.actorId);
        return (
          <li key={`${h.revision}-${h.eventId ?? ''}`} data-debug-id={`ticket-requirement-change-${h.revision}`} className="flex flex-col gap-1.5 border-l-2 border-subtle pl-3">
            <span className="flex flex-wrap items-center gap-1.5 text-caption text-muted">
              <Badge tone="neutral">Rev {h.revision}</Badge>
              <span className="font-semibold text-primary">{who}</span> changed requirements
              <span className="text-faint">{formatAgo(h.tsMs, now)}</span>
            </span>
            {h.reason && (
              <blockquote className="border-l-2 border-strong pl-3 text-body-sm text-primary">
                <VaultText value={h.reason} />
              </blockquote>
            )}
            <ul className="flex flex-col gap-1 text-caption">
              {h.before.goal !== h.after.goal && (
                <li className="flex gap-2">
                  <Badge tone="info">Goal</Badge>
                  <span className="min-w-0 break-words">
                    <span className="block text-faint line-through"><VaultText value={h.before.goal} /></span>
                    <span className="text-primary"><VaultText value={h.after.goal} /></span>
                  </span>
                </li>
              )}
              {diff.items.filter((i) => i.tag).map((i, n) => (
                <li key={`i${n}`} className="flex gap-2">
                  <Badge tone={i.tag === 'new' ? 'success' : 'info'}>{i.tag === 'new' ? 'Add' : 'Edit'}</Badge>
                  <span className="min-w-0 break-words text-primary"><EditedText previous={i.previous} text={i.text} /></span>
                </li>
              ))}
              {diff.removed.map((r, n) => (
                <li key={`r${n}`} className="flex gap-2">
                  <Badge tone="danger">Remove</Badge>
                  <span className="min-w-0 break-words text-faint line-through">{r}</span>
                </li>
              ))}
            </ul>
          </li>
        );
      })}
      {truncated && <Text role="caption" tone="faint">Showing recent changes. Older changes remain in the ticket history.</Text>}
    </ol>
  );
}

/** One page of events, newest first; "Show older" fetches the page before it. */
function EventFeed({ chainId, taskId, names, now, mode }: { chainId: string; taskId: string; names: TaskNames; now: number; mode: 'all' | 'handoffs' | 'raw' }) {
  const [pages, setPages] = useState<(number | undefined)[]>([undefined]);
  return (
    <ol data-debug-id={`ticket-activity-feed-${mode}`} className="flex flex-col gap-3">
      {pages.map((beforeId, i) => (
        <EventPage
          key={String(beforeId ?? 'head')}
          chainId={chainId}
          taskId={taskId}
          beforeId={beforeId}
          names={names}
          now={now}
          mode={mode}
          isLast={i === pages.length - 1}
          onOlder={(id) => setPages((p) => (p.includes(id) ? p : [...p, id]))}
        />
      ))}
    </ol>
  );
}

function EventPage({
  chainId,
  taskId,
  beforeId,
  names,
  now,
  mode,
  isLast,
  onOlder,
}: {
  chainId: string;
  taskId: string;
  beforeId?: number;
  names: TaskNames;
  now: number;
  mode: 'all' | 'handoffs' | 'raw';
  isLast: boolean;
  onOlder: (beforeId: number) => void;
}) {
  const { data, isFetching, error } = useFetchTaskEventsQuery({ chainId, taskId, beforeId, limit: PAGE });
  const events: TaskEventWire[] = [...(data?.events || [])].sort((a, b) => (b.event_id ?? 0) - (a.event_id ?? 0));
  const shown = mode === 'handoffs' ? events.filter((e) => HANDOFF_KINDS.has(String(e.kind))) : events;
  const oldest = events.length ? Math.min(...events.map((e) => e.event_id ?? Infinity)) : null;
  if (error) return <Text role="caption" tone="danger">Could not load activity.</Text>;
  if (!data && isFetching) return <Text role="caption" tone="faint">Loading activity…</Text>;
  return (
    <>
      {shown.length === 0 && beforeId === undefined && (
        <Text role="caption" tone="faint">{mode === 'handoffs' ? 'No handoffs yet.' : 'Nothing has happened yet.'}</Text>
      )}
      {shown.map((e, i) =>
        mode === 'raw' ? (
          <li key={e.event_id ?? i} data-debug-id="task-timeline-event">
            <pre className="max-h-48 overflow-auto rounded-md bg-canvas p-2 font-mono text-code-sm text-muted">
              {JSON.stringify(e, null, 2)}
            </pre>
          </li>
        ) : (
          <li key={e.event_id ?? i} data-debug-id="task-timeline-event" className="flex gap-3">
            <TicketAgentAvatar name={actorLabel(names, String(e.actor_kind || ''), String(e.actor_id || ''))} state="idle" />
            <span className="min-w-0 flex-1">
              <span className="block text-body-sm text-primary">
                <span className="font-semibold">{actorLabel(names, String(e.actor_kind || ''), String(e.actor_id || ''))}</span>{' '}
                <span className="text-muted">{describeTaskEvent(e, names).text}</span>
              </span>
              {e.kind === 'submitted' || e.kind === 'handoff' ? (
                e.payload?.summary ? (
                  <span className="mt-1 block border-l-2 border-strong pl-3 text-body-sm text-primary">
                    <VaultText value={String(e.payload.summary)} />
                  </span>
                ) : null
              ) : null}
              <span className="block text-caption text-faint">{e.ts_ms ? formatAgo(e.ts_ms, now) : ''}</span>
            </span>
          </li>
        ),
      )}
      {isLast && events.length >= PAGE && oldest !== null && Number.isFinite(oldest) && (
        <li>
          <Button size="sm" variant="ghost" onClick={() => onOlder(oldest)} data-debug-id="ticket-activity-older-btn">
            Show older
          </Button>
        </li>
      )}
    </>
  );
}

export default TicketActivity;
