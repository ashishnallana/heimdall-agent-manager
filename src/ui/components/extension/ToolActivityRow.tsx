// Compact renderer for `tool_activity` conversation messages (REQ-EXT-CONV-1/2).
//
// Collapsed: one muted line ("Edited 3 files · ran 2 commands") with a call-count
// badge. Expanded: the call list, then each subagent group nested under its
// header. A call with a file path opens the Activity timeline's diff viewer.
// Lean like ShellRunRow: no bubble, no card chrome.
import React, { useMemo, useState } from 'react';
import { Icon, Spinner } from '@ui';
import {
  parseToolActivity,
  toolActivityBadge,
  toolActivityCallDuration,
  toolActivityCallFile,
  toolActivityGroupSummary,
  toolActivityHeadline,
  toolActivityOmittedLabel,
  toolActivitySubagentLabel,
  type ToolActivityCall,
} from './toolActivityModel';

export interface ToolActivityRowProps {
  messageId: string;
  body: string;
  metadata: unknown;
  /** Opens the Activity timeline focused on a file's diff. */
  onOpenFile?: (filePath: string) => void;
  /** Opens the Activity timeline (for records the 4KB cap dropped). */
  onOpenActivity?: () => void;
}

function CallStatusIcon({ status }: { status: ToolActivityCall['status'] }) {
  if (status === 'running') return <Spinner size="sm" />;
  if (status === 'error') return <Icon name="alert" size={12} className="text-danger" title="Failed" />;
  return <Icon name="check" size={12} className="text-success" title="Done" />;
}

function CallRow({ call, debugId, onOpenFile }: { call: ToolActivityCall; debugId: string; onOpenFile?: (filePath: string) => void }) {
  const file = toolActivityCallFile(call);
  const summary =
    file && onOpenFile ? (
      <button
        type="button"
        data-debug-id={`${debugId}-file`}
        onClick={() => onOpenFile(file)}
        title={`Open ${file} in the Activity timeline`}
        className="min-w-0 flex-1 truncate text-left font-mono text-accent hover:underline"
      >
        {call.summary}
      </button>
    ) : (
      <span className="min-w-0 flex-1 truncate font-mono text-muted" title={call.summary}>{call.summary}</span>
    );
  const duration = toolActivityCallDuration(call);
  return (
    <li data-debug-id={debugId} data-tool-status={call.status} className="flex min-w-0 items-center gap-2 py-0.5 text-xs">
      <span className="grid h-4 w-4 shrink-0 place-items-center"><CallStatusIcon status={call.status} /></span>
      <span className="shrink-0 font-mono font-medium text-primary">{call.tool}</span>
      {summary}
      {duration ? <span className="shrink-0 text-faint">{duration}</span> : null}
    </li>
  );
}

export default function ToolActivityRow({ messageId, body, metadata, onOpenFile, onOpenActivity }: ToolActivityRowProps) {
  const activity = useMemo(() => parseToolActivity(metadata), [metadata]);
  const [open, setOpen] = useState(false);
  const headline = toolActivityHeadline(body, activity);
  const omitted = toolActivityOmittedLabel(activity);
  const prefix = `conversation-tool-activity-${messageId}`;
  const hasDetail = activity.calls.length > 0 || activity.subagents.length > 0 || Boolean(omitted);

  return (
    <div data-debug-id={prefix} className="w-full min-w-0 text-left">
      <button
        type="button"
        data-debug-id={`${prefix}-toggle`}
        aria-expanded={open}
        disabled={!hasDetail}
        onClick={() => setOpen((v) => !v)}
        className="flex min-h-8 w-full min-w-0 items-center gap-2 rounded-lg px-1 py-1 text-xs text-muted hover:bg-neutral-soft disabled:cursor-default disabled:hover:bg-transparent"
      >
        <Icon name={open ? 'chevron-down' : 'chevron-right'} size={12} className="shrink-0 text-faint" />
        <span className="min-w-0 flex-1 truncate" title={headline}>{headline}</span>
        <span data-debug-id={`${prefix}-badge`} className="shrink-0 text-faint">{toolActivityBadge(activity)}</span>
      </button>
      {open ? (
        <div data-debug-id={`${prefix}-details`} className="ml-5 border-l border-subtle pl-3">
          {activity.calls.length > 0 ? (
            <ul data-debug-id={`${prefix}-calls`} aria-label="Tool calls">
              {activity.calls.map((call, i) => (
                <CallRow key={`${call.useId || call.tool}-${i}`} call={call} debugId={`${prefix}-call-${i}`} onOpenFile={onOpenFile} />
              ))}
            </ul>
          ) : null}
          {activity.subagents.map((group, gi) => (
            <div key={group.agentId || gi} data-debug-id={`${prefix}-subagent-${gi}`} className="mt-1">
              <div className="flex min-w-0 items-center gap-2 py-0.5 text-xs">
                <Icon name="bot" size={12} className="shrink-0 text-info" />
                <span className="min-w-0 flex-1 truncate font-medium text-primary" title={toolActivitySubagentLabel(group)}>
                  {toolActivitySubagentLabel(group)}
                </span>
                <span className="shrink-0 text-faint">
                  {group.status === 'running' ? 'running · ' : ''}
                  {group.total} call{group.total === 1 ? '' : 's'}
                  {group.errors > 0 ? ` · ${group.errors} failed` : ''}
                </span>
              </div>
              {group.calls.length > 0 ? (
                <ul aria-label={`${group.agentType || 'Subagent'} tool calls`} className="ml-2 border-l border-subtle pl-3">
                  {group.calls.map((call, i) => (
                    <CallRow key={`${call.useId || call.tool}-${i}`} call={call} debugId={`${prefix}-subagent-${gi}-call-${i}`} onOpenFile={onOpenFile} />
                  ))}
                </ul>
              ) : null}
            </div>
          ))}
          {omitted ? (
            onOpenActivity ? (
              <button
                type="button"
                data-debug-id={`${prefix}-omitted`}
                onClick={onOpenActivity}
                className="mt-1 text-xs text-accent hover:underline"
              >
                {omitted}
              </button>
            ) : (
              <p data-debug-id={`${prefix}-omitted`} className="mt-1 text-xs text-faint">{omitted}</p>
            )
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

export interface ToolActivityGroupProps {
  messageId: string;
  /** The clubbed tool_activity messages, oldest first. */
  messages: Array<{ messageId: string; body: string; metadata?: unknown }>;
  onOpenFile?: (filePath: string) => void;
  onOpenActivity?: () => void;
}

/** A run of consecutive tool_activity messages, collapsed into one line until opened. */
export function ToolActivityGroup({ messageId, messages, onOpenFile, onOpenActivity }: ToolActivityGroupProps) {
  const [open, setOpen] = useState(false);
  const summary = useMemo(() => toolActivityGroupSummary(messages.map((m) => m.metadata)), [messages]);
  const prefix = `conversation-tool-activity-group-${messageId}`;
  return (
    <div data-debug-id={prefix} className="w-full min-w-0 text-left">
      <button
        type="button"
        data-debug-id={`${prefix}-toggle`}
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
        className="flex min-h-8 w-full min-w-0 items-center gap-2 rounded-lg px-1 py-1 text-xs text-muted hover:bg-neutral-soft"
      >
        <Icon name={open ? 'chevron-down' : 'chevron-right'} size={12} className="shrink-0 text-faint" />
        <span className="min-w-0 flex-1 truncate" title={summary.headline}>{summary.headline}</span>
        {summary.badge ? <span data-debug-id={`${prefix}-badge`} className="shrink-0 text-danger">{summary.badge}</span> : null}
      </button>
      {open ? (
        <div data-debug-id={`${prefix}-items`} className="ml-5 border-l border-subtle pl-2">
          {messages.map((m) => (
            <ToolActivityRow
              key={m.messageId}
              messageId={m.messageId}
              body={m.body}
              metadata={m.metadata}
              onOpenFile={onOpenFile}
              onOpenActivity={onOpenActivity}
            />
          ))}
        </div>
      ) : null}
    </div>
  );
}
