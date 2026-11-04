import React, { useState } from 'react';
import { Icon, Text } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { useFetchCommitDiffQuery, useFetchTaskFacetQuery } from '../../api/endpoints/tasks';
import { DecryptedMarkdown } from '../vault';
import { taskChangedFiles } from './taskV2Types';

/* Changes and output (fetched on first open) ------------------------- */

export function TicketChangesCard({ chainId, task }: { chainId: string; task: TaskWire }) {
  const [open, setOpen] = useState(false);
  const [diffFile, setDiffFile] = useState<string | null>(null);
  const attemptNo = task.attempt_no || 1;
  const skip = !open;
  const { data: vcsData, isFetching } = useFetchTaskFacetQuery({ chainId, taskId: task.task_id, attemptNo, kind: 'vcs' }, { skip });
  const { data: outputData } = useFetchTaskFacetQuery({ chainId, taskId: task.task_id, attemptNo, kind: 'output' }, { skip });
  const vcs = vcsData?.facet;
  const files = taskChangedFiles(vcs);
  const { currentData: diffData, isError: diffFailed } = useFetchCommitDiffQuery(
    { chainId, directoryId: vcs?.directory_id || 'default', base: vcs?.base || '', head: vcs?.head || '', path: diffFile || '' },
    { skip: !diffFile || !vcs?.base || !vcs?.head },
  );
  const output = outputData?.facet;
  return (
    <section data-debug-id="task-details-changes" className="flex flex-col gap-2">
      <button
        type="button"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
        data-debug-id="ticket-view-changes-toggle"
        className="flex min-h-11 items-center gap-2 self-start rounded-sm text-left focus-visible:outline-none focus-visible:shadow-focus"
      >
        <Icon name={open ? 'chevron-down' : 'chevron-right'} size={14} className="text-muted" />
        <Text as="span" role="title" className="text-primary">Changes</Text>
        {open && files.length > 0 && <Text as="span" role="caption" tone="faint">{files.length} files</Text>}
      </button>
      {open && (
        <div className="flex flex-col gap-2">
          {isFetching && !vcsData && <Text role="caption" tone="faint">Loading changes…</Text>}
          {!isFetching && files.length === 0 && <Text role="caption" tone="faint">No file changes recorded for attempt {attemptNo}.</Text>}
          {files.length > 0 && (
            <ul className="divide-y divide-subtle overflow-hidden rounded-lg border border-subtle bg-surface">
              {files.map(({ path, add, del }) => (
                <li key={path}>
                  <button
                    type="button"
                    aria-expanded={diffFile === path}
                    onClick={() => setDiffFile(diffFile === path ? null : path)}
                    data-debug-id={`ticket-view-changed-file-${path}`}
                    className="flex min-h-11 w-full min-w-0 items-center gap-2 px-3 py-2 text-left hover:bg-surface-raised focus-visible:outline-none focus-visible:shadow-focus"
                  >
                    <span className="min-w-0 flex-1 truncate font-mono text-code-sm text-primary">{path}</span>
                    {typeof add === 'number' && typeof del === 'number' && (
                      <span className="shrink-0 font-mono text-code-sm"><span className="text-success">+{add}</span> <span className="text-danger">-{del}</span></span>
                    )}
                  </button>
                  {diffFile === path && (
                    <pre className="max-h-80 overflow-auto bg-canvas p-3 font-mono text-code-sm text-primary">
                      {diffData ? `${diffData.diff || diffData.raw || ''}${diffData.truncated ? '\n\n(diff truncated)' : ''}` : diffFailed ? 'Could not load this diff.' : 'Loading diff…'}
                    </pre>
                  )}
                </li>
              ))}
            </ul>
          )}
          {output && (
            <div data-debug-id="task-details-output" className="flex flex-col gap-1">
              <Text as="span" role="overline" tone="faint">Output</Text>
              {typeof (output.summary || output.text) === 'string' ? (
                <DecryptedMarkdown source={String(output.summary || output.text)} compact copyAll={false} />
              ) : (
                <pre className="max-h-48 overflow-auto rounded-md bg-canvas p-2 font-mono text-code-sm text-primary">{JSON.stringify(output, null, 2)}</pre>
              )}
            </div>
          )}
        </div>
      )}
    </section>
  );
}
