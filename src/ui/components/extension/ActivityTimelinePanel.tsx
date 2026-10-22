// Activity timeline aux tab (REQ-EXT-SUB-2, REQ-EXT-FILE-1 UI): the parent
// conversation's tool calls in order, each subagent as a collapsible group
// nested where it started (type, description, running/done, duration, its own
// tool calls and files), and a "Files edited" list with the shared diff viewer.
// Grouping lives in extensionTimelineModel.ts; the data is kept live by the
// realtime 'extension_events' frame (wsInvalidation.ts → 'ExtensionEvents').
import React, { Suspense, useEffect, useMemo, useState } from 'react';
import { Icon, Spinner, StatusPill } from '@ui';
import { apiErrorText } from '../../api/cookieFetch';
import { useGetExtensionTimelineQuery } from '../../api/endpoints/extension';
import {
  buildActivityTimeline,
  diffLineStats,
  fileBaseName,
  formatDuration,
  latestDiffEdit,
  parseUnifiedDiff,
  type TimelineEntry,
  type TimelineFileEdit,
  type TimelineFileEntry,
  type TimelineSubagentGroup,
  type TimelineToolCall,
} from './extensionTimelineModel';

const MonacoDiffViewer = React.lazy(() => import('../chat/MonacoDiffViewer'));

type View = 'timeline' | 'files';

function ToolStatusIcon({ status }: { status: TimelineToolCall['status'] }) {
  if (status === 'running') return <Spinner size="sm" />;
  if (status === 'failed') return <Icon name="alert" size={13} className="text-danger" title="Failed" />;
  return <Icon name="check" size={13} className="text-success" title="Done" />;
}

function ToolRow({ call }: { call: TimelineToolCall }) {
  return (
    <li
      data-debug-id={`activity-tool-${call.id}`}
      data-tool-status={call.status}
      className="flex min-w-0 items-center gap-2 py-1 text-xs"
    >
      <span className="grid h-4 w-4 shrink-0 place-items-center"><ToolStatusIcon status={call.status} /></span>
      <span className="shrink-0 font-mono font-medium text-primary">{call.toolName}</span>
      <span className="min-w-0 flex-1 truncate font-mono text-muted" title={call.summary}>{call.summary}</span>
      {call.durationMs != null ? <span className="shrink-0 text-faint">{formatDuration(call.durationMs)}</span> : null}
    </li>
  );
}

function FileRow({ file, onOpen, agentLabel }: { file: TimelineFileEntry; onOpen: (f: TimelineFileEntry) => void; agentLabel: (id: string) => string }) {
  const latest = latestDiffEdit(file);
  const stats = latest ? diffLineStats(latest.diff) : null;
  return (
    <li>
      <button
        type="button"
        data-debug-id={`activity-file-${file.filePath}`}
        onClick={() => onOpen(file)}
        title={file.filePath}
        className="flex min-h-10 w-full min-w-0 items-center gap-2 rounded-lg px-2 py-1.5 text-left text-xs hover:bg-neutral-soft"
      >
        <Icon name="file" size={13} className="shrink-0 text-muted" />
        <span className="min-w-0 flex-1">
          <span className="block truncate font-medium text-primary">{fileBaseName(file.filePath)}</span>
          <span className="block truncate text-faint">{file.filePath}</span>
        </span>
        {stats ? (
          <span className="shrink-0 font-mono">
            <span className="text-success">+{stats.added}</span> <span className="text-danger">-{stats.removed}</span>
          </span>
        ) : null}
        <span className="shrink-0 text-faint" title={file.agentIds.map(agentLabel).join(', ')}>
          {file.editCount} {file.editCount === 1 ? 'edit' : 'edits'}
        </span>
      </button>
    </li>
  );
}

function SubagentGroup({
  group,
  expanded,
  onToggle,
  onOpenFile,
  agentLabel,
}: {
  group: TimelineSubagentGroup;
  expanded: boolean;
  onToggle: () => void;
  onOpenFile: (f: TimelineFileEntry) => void;
  agentLabel: (id: string) => string;
}) {
  const bodyId = `activity-subagent-body-${group.agentId}`;
  return (
    <li data-debug-id={`activity-subagent-${group.agentId}`} data-subagent-status={group.status} className="my-1 rounded-xl border border-subtle bg-surface-raised/40">
      <button
        type="button"
        data-debug-id={`activity-subagent-toggle-${group.agentId}`}
        aria-expanded={expanded}
        aria-controls={bodyId}
        onClick={onToggle}
        className="flex min-h-10 w-full min-w-0 items-center gap-2 px-2 py-1.5 text-left text-xs"
      >
        <Icon name={expanded ? 'chevron-down' : 'chevron-right'} size={13} className="shrink-0 text-muted" />
        <Icon name="bot" size={13} className="shrink-0 text-accent" />
        <span className="shrink-0 font-medium text-primary">{group.agentType || 'Subagent'}</span>
        <span className="min-w-0 flex-1 truncate text-muted" title={group.description}>{group.description}</span>
        <span className="flex shrink-0 items-center gap-1.5">
          {group.durationMs != null ? <span className="text-faint">{formatDuration(group.durationMs)}</span> : null}
          <StatusPill tone={group.status === 'running' ? 'info' : 'success'}>{group.status === 'running' ? 'Running' : 'Done'}</StatusPill>
        </span>
      </button>
      {expanded ? (
        <div id={bodyId} className="border-t border-subtle px-2 pb-2 pl-6">
          {group.toolCalls.length ? (
            <ul aria-label="Subagent tool calls">{group.toolCalls.map((c) => <ToolRow key={`${c.id}:${c.seq}`} call={c} />)}</ul>
          ) : (
            <p className="py-1 text-xs text-faint">No tool calls recorded.</p>
          )}
          {group.files.length ? (
            <div className="mt-1">
              <div className="text-[11px] font-semibold uppercase tracking-wide text-muted">Files</div>
              <ul>{group.files.map((f) => <FileRow key={f.filePath} file={f} onOpen={onOpenFile} agentLabel={agentLabel} />)}</ul>
            </div>
          ) : null}
        </div>
      ) : null}
    </li>
  );
}

function EntryRow(props: {
  entry: TimelineEntry;
  expanded: Record<string, boolean>;
  toggle: (id: string) => void;
  onOpenFile: (f: TimelineFileEntry) => void;
  agentLabel: (id: string) => string;
}) {
  const { entry } = props;
  if (entry.kind === 'tool') return <ToolRow call={entry} />;
  if (entry.kind === 'subagent') {
    // Running subagents start expanded so their live tool calls are visible.
    const expanded = props.expanded[entry.id] ?? entry.status === 'running';
    return (
      <SubagentGroup
        group={entry}
        expanded={expanded}
        onToggle={() => props.toggle(entry.id)}
        onOpenFile={props.onOpenFile}
        agentLabel={props.agentLabel}
      />
    );
  }
  return (
    <li data-debug-id={`activity-notice-${entry.seq}`} className="flex items-center gap-2 py-1 text-xs text-faint">
      <Icon name="info" size={12} className="shrink-0" />
      <span className="truncate">{entry.text}</span>
    </li>
  );
}

function FileDiff({ file, onBack, agentLabel }: { file: TimelineFileEntry; onBack: () => void; agentLabel: (id: string) => string }) {
  const withDiff = file.edits.filter((e) => e.diff);
  const [selectedSeq, setSelectedSeq] = useState<number>(() => latestDiffEdit(file)?.seq ?? 0);
  const edit: TimelineFileEdit | undefined = withDiff.find((e) => e.seq === selectedSeq) || withDiff[withDiff.length - 1];
  const hunks = useMemo(() => (edit ? parseUnifiedDiff(edit.diff) : []), [edit]);
  return (
    <div data-debug-id="activity-file-diff" className="flex min-h-0 flex-1 flex-col">
      <div className="flex min-w-0 items-center gap-2 border-b border-subtle px-2 py-1.5">
        <button
          type="button"
          data-debug-id="activity-file-diff-back-btn"
          aria-label="Back to files"
          onClick={onBack}
          className="grid h-9 w-9 shrink-0 place-items-center rounded-lg text-muted hover:bg-neutral-soft hover:text-primary"
        >
          <Icon name="arrow-left" size={15} />
        </button>
        <span className="min-w-0 flex-1 truncate font-mono text-xs text-primary" title={file.filePath}>{file.filePath}</span>
        {withDiff.length > 1 ? (
          <select
            data-debug-id="activity-file-diff-edit-select"
            aria-label="Edit"
            value={edit?.seq ?? 0}
            onChange={(event) => setSelectedSeq(Number(event.target.value))}
            className="min-h-9 shrink-0 rounded-lg border border-subtle bg-surface px-2 text-xs text-primary"
          >
            {withDiff.map((e, i) => (
              <option key={e.seq} value={e.seq}>
                Edit {i + 1} · {agentLabel(e.agentId)}
              </option>
            ))}
          </select>
        ) : null}
      </div>
      {edit?.diffTruncated ? (
        <p data-debug-id="activity-file-diff-truncated" className="border-b border-subtle bg-warning-soft px-3 py-1 text-xs text-warning">
          This diff was too large and is truncated.
        </p>
      ) : null}
      {edit ? (
        <Suspense fallback={<div className="p-3 text-center text-xs text-muted">Loading diff…</div>}>
          <MonacoDiffViewer filePath={file.filePath} hunks={hunks as any} className="min-h-0 flex-1" />
        </Suspense>
      ) : (
        <p data-debug-id="activity-file-diff-empty" className="p-4 text-center text-xs text-muted">
          No diff was recorded for this file{file.edits.length === 0 ? ' (older edits were trimmed)' : ''}.
        </p>
      )}
    </div>
  );
}

export interface ActivityTimelinePanelProps {
  instanceId: string;
  isMobile?: boolean;
  /** Transient: open this file's diff (e.g. clicked in a tool_activity message). */
  openFilePath?: string | null;
  /** Called once openFilePath has been applied, so the request is not replayed. */
  onFileOpened?: () => void;
}

export default function ActivityTimelinePanel({ instanceId, isMobile = false, openFilePath = null, onFileOpened }: ActivityTimelinePanelProps) {
  const query = useGetExtensionTimelineQuery(instanceId, { skip: !instanceId });
  const timeline = useMemo(
    () => buildActivityTimeline(query.data?.events || [], query.data?.subagents || [], query.data?.files || []),
    [query.data],
  );
  const [view, setView] = useState<View>('timeline');
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});
  const [openFile, setOpenFile] = useState<string | null>(null);

  useEffect(() => {
    if (!openFilePath) return;
    setView('files');
    setOpenFile(openFilePath);
    onFileOpened?.();
  }, [openFilePath, onFileOpened]);

  const agentTypes = useMemo(() => {
    const map = new Map<string, string>();
    for (const g of timeline.subagents) map.set(g.agentId, g.agentType || 'Subagent');
    return map;
  }, [timeline.subagents]);
  const agentLabel = (id: string) => (id ? agentTypes.get(id) || id.slice(0, 8) : 'Main');

  const toggle = (id: string) =>
    setExpanded((prev) => {
      const group = timeline.subagents.find((g) => g.id === id);
      const current = prev[id] ?? group?.status === 'running';
      return { ...prev, [id]: !current };
    });
  const onOpenFile = (f: TimelineFileEntry) => {
    setView('files');
    setOpenFile(f.filePath);
  };

  if (query.isLoading) {
    return (
      <div data-debug-id="activity-timeline-loading" className="flex h-full min-h-[160px] items-center justify-center gap-2 text-xs text-muted">
        <Spinner size="sm" /> Loading activity…
      </div>
    );
  }
  if (query.isError) {
    return (
      <div role="alert" data-debug-id="activity-timeline-error" className="m-3 rounded-xl border border-danger/30 bg-danger-soft p-3 text-xs text-danger">
        {apiErrorText(query.error, 'Could not load the activity timeline.')}
      </div>
    );
  }

  const empty = timeline.entries.length === 0 && timeline.files.length === 0;
  const selectedFile = openFile ? timeline.files.find((f) => f.filePath === openFile) || null : null;

  return (
    <div data-debug-id="activity-timeline-panel" className="flex h-full min-h-0 w-full flex-col text-left">
      <div className={`flex shrink-0 items-center gap-1 border-b border-subtle ${isMobile ? 'px-3 py-2' : 'px-2 py-1.5'}`} role="tablist" aria-label="Activity views">
        {([
          ['timeline', `Timeline (${timeline.toolCallCount})`],
          ['files', `Files edited (${timeline.files.length})`],
        ] as const).map(([key, label]) => (
          <button
            key={key}
            type="button"
            role="tab"
            aria-selected={view === key}
            data-debug-id={`activity-view-${key}-btn`}
            onClick={() => {
              setView(key);
              if (key === 'files') setOpenFile(null);
            }}
            className={`min-h-9 rounded-lg px-2.5 text-xs font-medium ${view === key ? 'bg-neutral-soft text-primary' : 'text-muted hover:text-primary'}`}
          >
            {label}
          </button>
        ))}
        {timeline.runningSubagents > 0 ? (
          <span data-debug-id="activity-running-subagents" className="ml-auto text-xs text-info">
            {timeline.runningSubagents} subagent{timeline.runningSubagents === 1 ? '' : 's'} running
          </span>
        ) : null}
      </div>

      {empty ? (
        <div data-debug-id="activity-timeline-empty" className="grid flex-1 place-items-center p-6 text-center text-xs text-muted">
          No extension activity yet. Tool calls, subagents and file edits appear here when the provider extension is installed.
        </div>
      ) : view === 'timeline' ? (
        <ul data-debug-id="activity-timeline-list" aria-label="Tool calls" className="min-h-0 flex-1 overflow-y-auto px-3 py-2">
          {timeline.entries.map((entry) => (
            <EntryRow
              key={entry.id + ':' + entry.seq}
              entry={entry}
              expanded={expanded}
              toggle={toggle}
              onOpenFile={onOpenFile}
              agentLabel={agentLabel}
            />
          ))}
        </ul>
      ) : selectedFile ? (
        <FileDiff key={selectedFile.filePath} file={selectedFile} onBack={() => setOpenFile(null)} agentLabel={agentLabel} />
      ) : (
        <ul data-debug-id="activity-files-list" aria-label="Files edited" className="min-h-0 flex-1 overflow-y-auto px-2 py-2">
          {timeline.files.length === 0 ? (
            <li className="p-4 text-center text-xs text-muted">No files edited yet.</li>
          ) : (
            timeline.files.map((f) => <FileRow key={f.filePath} file={f} onOpen={onOpenFile} agentLabel={agentLabel} />)
          )}
        </ul>
      )}
    </div>
  );
}
