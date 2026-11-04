import React, { useEffect, useMemo, useState } from 'react';
import { useSelector } from 'react-redux';
import { Alert, Badge, Button, IconButton, Input, Modal, ModalBody, ModalFooter, Radio, Text, Textarea } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { useAddTaskCommentMutation, useCancelTaskDetailMutation, useCreateTaskMutation, useUpdateTaskDetailMutation } from '../../api/endpoints/tasks';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';
import { containsVaultArmored } from '../../utils/vaultCrypto';
import { VaultText } from '../vault/VaultText';
import { normalizeTaskState } from './taskV2Types';
import { actionErrorMessage } from './useTaskActions';
import type { TaskNames } from './taskNames';
import {
  TICKET_REPLACE_ENABLED,
  diffAcceptance,
  inlineChange,
  keyFor,
  replacedByComment,
  replacesComment,
} from './ticketModel';

const GOAL_MAX_BYTES = 2000;
const ITEM_MAX_BYTES = 200;
const MAX_ITEMS = 20;

const bytes = (s: string) => new TextEncoder().encode(s).length;

/** The hub's answer when the revision moved under the editor. */
export function isRequirementsConflict(message: string): boolean {
  return /requirements changed|reload the task/i.test(message || '');
}

export interface RequirementsEditorModalProps {
  open: boolean;
  onClose: () => void;
  chainId: string;
  task: TaskWire;
  keys: Map<string, string>;
  names: TaskNames;
}

type Mode = 'amend' | 'replace';

/**
 * Change requirements (REQ-T5): amend the ticket (goal, acceptance rows and a
 * required reason) or replace it with a new linked ticket. The right side shows
 * the diff and what saving does before anything is sent; the save carries the
 * revision it was based on, and a conflict keeps the draft next to the newer
 * revision instead of retrying (spec: Rules for the implementation).
 */
export const RequirementsEditorModal: React.FC<RequirementsEditorModalProps> = ({ open, onClose, chainId, task, keys, names }) => {
  const vaultUnlocked = useSelector(selectIsVaultUnlocked);
  const [updateTask, updateState] = useUpdateTaskDetailMutation();
  const [createTask, createState] = useCreateTaskMutation();
  const [cancelTask] = useCancelTaskDetailMutation();
  const [addComment] = useAddTaskCommentMutation();

  const currentGoal = String(task.brief?.goal || '');
  const currentItems = useMemo(() => (task.brief?.acceptance || []).map(String), [task.brief?.acceptance]);
  const currentRevision = Number(task.requirements?.revision) || 0;

  const [mode, setMode] = useState<Mode>('amend');
  const [goal, setGoal] = useState(currentGoal);
  const [items, setItems] = useState<string[]>(currentItems);
  const [reason, setReason] = useState('');
  const [newTitle, setNewTitle] = useState('');
  const [baseRevision, setBaseRevision] = useState(currentRevision);
  const [base, setBase] = useState({ goal: currentGoal, items: currentItems });
  const [error, setError] = useState('');
  const [conflict, setConflict] = useState(false);

  // A fresh draft each time the editor opens.
  useEffect(() => {
    if (!open) return;
    setMode('amend');
    setGoal(currentGoal);
    setItems(currentItems.length ? currentItems : ['']);
    setReason('');
    setNewTitle(String(task.title || ''));
    setBaseRevision(currentRevision);
    setBase({ goal: currentGoal, items: currentItems });
    setError('');
    setConflict(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, task.task_id]);

  const key = keyFor(keys, task.task_id);
  const state = normalizeTaskState(task.state);
  const cleanItems = items.map((i) => i.trim()).filter(Boolean);
  const diff = useMemo(() => diffAcceptance(base.items, cleanItems), [base.items, cleanItems.join('\n')]);
  const goalChanged = goal.trim() !== base.goal.trim();
  const edited = diff.items.filter((i) => i.tag === 'edited').length;
  const added = diff.items.filter((i) => i.tag === 'new').length;
  const removed = diff.removed.length;
  const changed = goalChanged || edited + added + removed > 0;
  const locked = !vaultUnlocked;
  const newerRevision = conflict && currentRevision > baseRevision;

  const holders = (task.leases || []).filter((l) => (l?.kind || 'work') === 'work' && l.holder_instance_id);
  const reviewerNames = Array.from(new Set((task.brief?.reviewers || []).map((r) => names.agent(String(r)))));

  const problems: string[] = [];
  if (!goal.trim()) problems.push('Add a goal.');
  if (bytes(goal) > GOAL_MAX_BYTES) problems.push('Keep the goal under 2,000 bytes.');
  if (!cleanItems.length) problems.push('Add at least one acceptance criterion.');
  if (cleanItems.length > MAX_ITEMS) problems.push('Use at most 20 acceptance criteria.');
  if (cleanItems.some((i) => bytes(i) > ITEM_MAX_BYTES)) problems.push('Keep each criterion under 200 bytes.');
  if (!reason.trim()) problems.push('Say why it changed.');
  if (mode === 'amend' && !changed) problems.push('Change the goal or acceptance first.');
  if (mode === 'replace' && !newTitle.trim()) problems.push('Name the new ticket.');
  const busy = updateState.isLoading || createState.isLoading;

  const save = async () => {
    // Ctrl+Enter must not send a second save while one is in flight.
    if (busy) return;
    if (locked || problems.length) {
      setError(problems.join(' '));
      return;
    }
    setError('');
    try {
      if (mode === 'amend') {
        await updateTask({
          chainId,
          taskId: task.task_id,
          brief: { ...(goalChanged ? { goal: goal.trim() } : {}), acceptance: cleanItems },
          expectedRequirementsRevision: baseRevision,
          requirementsReason: reason.trim(),
        }).unwrap();
      } else {
        // Replace (gap G2): a new ticket with the same people, then the link is
        // written as a comment on both tickets and the original is cancelled.
        const created: any = await createTask({
          chainId,
          title: newTitle.trim(),
          brief: {
            goal: goal.trim(),
            acceptance: cleanItems,
            ...(task.brief?.assignee ? { assignee: task.brief.assignee } : {}),
            ...(task.brief?.reviewers?.length ? { reviewers: task.brief.reviewers } : {}),
            ...(task.brief?.review_roles?.length ? { review_roles: task.brief.review_roles } : {}),
          },
          requiresUserApproval: Boolean(task.requires_user_approval),
          dependsOn: task.depends_on || [],
        }).unwrap();
        const newId = String(created?.task_id || created?.data?.task_id || created?.task?.task_id || '');
        if (newId) {
          await addComment({ chainId, taskId: task.task_id, body: `${replacedByComment(newId, 'new ticket')} ${reason.trim()}` }).unwrap();
          await addComment({ chainId, taskId: newId, body: replacesComment(task.task_id, key) }).unwrap();
        }
        await cancelTask({ chainId, taskId: task.task_id }).unwrap();
      }
      onClose();
    } catch (err) {
      const message = actionErrorMessage(err);
      if (isRequirementsConflict(message)) {
        // Keep the draft; the refetched task shows the newer revision beside it.
        setConflict(true);
        setError('Someone changed these requirements while you were editing. Compare your draft with the newer revision, then save again.');
      } else {
        setError(message);
      }
    }
  };

  const rebaseOnNewer = () => {
    setBaseRevision(currentRevision);
    setBase({ goal: currentGoal, items: currentItems });
    setConflict(false);
    setError('');
  };

  const onKeyDown = (e: React.KeyboardEvent) => {
    if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
      e.preventDefault();
      void save();
    }
  };

  return (
    <Modal open={open} onOpenChange={(o) => !o && onClose()} title={`Change requirements · ${key}`} size="lg" data-debug-id="task-requirements-modal">
      <ModalBody className="text-body-sm">
        <div onKeyDown={onKeyDown} data-debug-id="task-requirements-editor" className="grid gap-5 md:grid-cols-[minmax(0,1fr)_minmax(0,0.85fr)]">
          <div className="flex min-w-0 flex-col gap-4">
            {locked && (
              <Alert tone="warning" title="Unlock your vault to edit">
                Requirements are sealed with your vault key.
              </Alert>
            )}
            {TICKET_REPLACE_ENABLED && (
              <fieldset className="flex flex-col gap-2">
                <legend className="mb-1 text-label text-muted">What kind of change is this?</legend>
                <Radio
                  name="req-mode"
                  checked={mode === 'amend'}
                  onChange={() => setMode('amend')}
                  data-debug-id="task-requirements-mode-amend"
                  label={<span><span className="font-semibold text-primary">Amend this ticket</span><span className="block text-caption text-muted">Same objective; history and approvals carry over.</span></span>}
                />
                <Radio
                  name="req-mode"
                  checked={mode === 'replace'}
                  onChange={() => setMode('replace')}
                  data-debug-id="task-requirements-mode-replace"
                  label={<span><span className="font-semibold text-primary">Replace with a new ticket</span><span className="block text-caption text-muted">The objective changes. This ticket is closed and linked to the new one.</span></span>}
                />
              </fieldset>
            )}
            {mode === 'replace' && (
              <label className="flex flex-col gap-1">
                <span className="text-label text-muted">New ticket title</span>
                <Input value={newTitle} onChange={setNewTitle} width="full" aria-label="New ticket title" data-debug-id="task-requirements-new-title" />
              </label>
            )}
            <label className="flex flex-col gap-1">
              <span className="text-label text-muted">Goal</span>
              <Textarea aria-label="Task goal" data-debug-id="task-requirements-goal" value={goal} onChange={setGoal} rows={4} width="full" disabled={locked} />
              <span className={`text-caption ${bytes(goal) > GOAL_MAX_BYTES ? 'text-danger' : 'text-faint'}`}>up to 2,000 bytes</span>
            </label>
            <div className="flex flex-col gap-1.5" data-debug-id="task-requirements-acceptance">
              <span className="text-label text-muted">Acceptance criteria</span>
              {items.map((item, i) => {
                const tag = diff.items[cleanItems.indexOf(item.trim())]?.tag;
                return (
                  <div key={i} className="flex items-center gap-2">
                    <Input
                      value={item}
                      onChange={(v) => setItems((list) => list.map((x, j) => (j === i ? v : x)))}
                      width="full"
                      aria-label={`Acceptance criterion ${i + 1}`}
                      data-debug-id={`task-requirements-acceptance-${i}`}
                      disabled={locked}
                    />
                    {item.trim() && tag === 'edited' && <Badge tone="info">Edited</Badge>}
                    {item.trim() && tag === 'new' && <Badge tone="success">New</Badge>}
                    <IconButton
                      icon="close"
                      label={`Remove criterion ${i + 1}`}
                      size="sm"
                      variant="ghost"
                      disabled={locked}
                      data-debug-id={`task-requirements-acceptance-remove-${i}`}
                      onClick={() => setItems((list) => list.filter((_, j) => j !== i))}
                    />
                  </div>
                );
              })}
              <div className="flex items-center justify-between gap-2">
                <Button size="sm" variant="ghost" disabled={locked || items.length >= MAX_ITEMS} onClick={() => setItems((l) => [...l, ''])} data-debug-id="task-requirements-acceptance-add">
                  Add criterion
                </Button>
                <span className="text-caption text-faint">{cleanItems.length} of 20 · each up to 200 bytes</span>
              </div>
            </div>
            <label className="flex flex-col gap-1">
              <span className="text-label text-muted">
                Reason for the change <span className="text-warning">required</span>
              </span>
              <Textarea aria-label="Reason for the change" data-debug-id="task-requirements-reason" value={reason} onChange={setReason} rows={2} width="full" disabled={locked} />
            </label>
          </div>

          <aside className="flex min-w-0 flex-col gap-3 rounded-lg border border-subtle bg-surface-raised p-3" data-debug-id="task-requirements-preview">
            <Text as="h3" role="overline" tone="faint">What happens when you save</Text>
            {mode === 'amend' ? (
              <>
                <div className="flex flex-wrap items-center gap-1.5 text-caption text-muted">
                  <Badge tone="neutral">Rev {baseRevision}</Badge>
                  <span aria-hidden="true">›</span>
                  <Badge tone="warning">Rev {baseRevision + 1}</Badge>
                  <span>{[goalChanged ? 'goal changed' : '', edited ? `${edited} edited` : '', added ? `${added} added` : '', removed ? `${removed} removed` : ''].filter(Boolean).join(' · ') || 'no changes yet'}</span>
                </div>
                <ul className="flex flex-col gap-1.5">
                  {goalChanged && (
                    <li className="flex gap-2">
                      <Badge tone="info">Goal</Badge>
                      <span className="min-w-0 break-words text-primary"><VaultText value={goal.trim()} /></span>
                    </li>
                  )}
                  {diff.items.filter((i) => i.tag).map((i, n) => (
                    <li key={`d${n}`} className="flex gap-2">
                      <Badge tone={i.tag === 'new' ? 'success' : 'info'}>{i.tag === 'new' ? 'Add' : 'Edit'}</Badge>
                      <span className="min-w-0 break-words">
                        {i.previous && <span className="block text-faint line-through"><VaultText value={i.previous} /></span>}
                        <span className="text-primary"><VaultText value={i.text} /></span>
                      </span>
                    </li>
                  ))}
                  {diff.removed.map((r, n) => (
                    <li key={`r${n}`} className="flex gap-2">
                      <Badge tone="danger">Remove</Badge>
                      <span className="min-w-0 break-words text-faint line-through"><VaultText value={r} /></span>
                    </li>
                  ))}
                </ul>
                <ul className="flex flex-col gap-1.5 text-caption text-muted">
                  {holders.length > 0 ? (
                    holders.map((h) => (
                      <li key={h.lease_id}>
                        <span className="text-primary">{names.instance(h.holder_instance_id) || 'The worker'}</span> is working on it. It is notified now and reads rev {baseRevision + 1} before its next step; its progress stays.
                      </li>
                    ))
                  ) : (
                    <li>No agent holds the lease; the next worker starts from rev {baseRevision + 1}.</li>
                  )}
                  {reviewerNames.length > 0 && <li>{reviewerNames.join(', ')} will review the next submission against rev {baseRevision + 1}.</li>}
                  {state === 'in_review' ? (
                    <li className="text-warning">It is in review: earlier approvals stop counting and the worker reworks it before anyone can approve.</li>
                  ) : (
                    <li>Not in review yet, so no approvals are reset.</li>
                  )}
                </ul>
              </>
            ) : (
              <ul className="flex flex-col gap-2 text-caption text-muted">
                <li>
                  <Badge tone="neutral">{key}</Badge> is cancelled with your reason and linked to the new ticket. Work already done stays in its history.
                </li>
                <li>
                  A new ticket takes this goal and acceptance with the same assignee, reviewers and approval rule, and waits for the same tickets.
                </li>
                <li>Tickets that wait for {key} need to be moved to the new ticket by hand.</li>
              </ul>
            )}
            {newerRevision && (
              <div className="flex flex-col gap-1.5 rounded-md border border-warning/40 bg-warning-soft p-2" data-debug-id="task-requirements-conflict">
                <Text as="p" role="caption" tone="warning">Rev {currentRevision} is newer than your draft (based on rev {baseRevision}):</Text>
                <Text as="p" role="caption" className="break-words text-primary"><VaultText value={currentGoal} /></Text>
                <ul className="list-disc pl-4 text-caption text-primary">
                  {currentItems.map((i, n) => (
                    <li key={n} className="break-words"><VaultText value={i} /></li>
                  ))}
                </ul>
                <div>
                  <Button size="sm" variant="secondary" onClick={rebaseOnNewer} data-debug-id="task-requirements-rebase">
                    Keep my draft on rev {currentRevision}
                  </Button>
                </div>
              </div>
            )}
          </aside>
        </div>
        {error && (
          <Text as="p" role="caption" tone="danger" className="mt-3 whitespace-pre-line break-words" data-debug-id="task-requirements-status">
            {error}
          </Text>
        )}
      </ModalBody>
      <ModalFooter>
        <span className="mr-auto hidden text-caption text-faint sm:inline">Ctrl+Enter to save</span>
        <Button size="sm" variant="ghost" onClick={onClose} data-debug-id="task-requirements-cancel">
          Cancel
        </Button>
        <Button
          size="sm"
          variant="primary"
          data-debug-id="task-requirements-save"
          disabled={locked || !baseRevision || (conflict && newerRevision)}
          loading={busy}
          onClick={() => void save()}
        >
          {mode === 'amend' ? `Save as revision ${baseRevision + 1}` : 'Replace ticket'}
        </Button>
      </ModalFooter>
    </Modal>
  );
};

/** The edit highlight for an acceptance item: "…restarts [and bridge reinstalls]". */
export function EditedText({ previous, text }: { previous?: string; text: string }) {
  if (!previous || containsVaultArmored(previous) || containsVaultArmored(text)) return <VaultText value={text} />;
  const { prefix, changed, suffix } = inlineChange(previous, text);
  return (
    <>
      {prefix}
      {changed && <mark className="rounded-sm bg-success-soft px-0.5 text-primary">{changed}</mark>}
      {suffix}
    </>
  );
}

export default RequirementsEditorModal;
