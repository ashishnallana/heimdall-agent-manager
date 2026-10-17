import React, { useEffect, useMemo, useState } from 'react';
import { Badge, Button, Checkbox, Modal, ModalBody, ModalFooter, Select, StatusPill, Text } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { useUpdateTaskDetailMutation } from '../../api/endpoints/tasks';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';
import { TASK_STATE_LABELS, TASK_STATE_TONE, normalizeTaskState } from './taskV2Types';
import { actionErrorMessage } from './useTaskActions';
import { EMPTY_TASK_NAMES, type TaskNames } from './taskNames';

export type TaskEditField = 'assignee' | 'reviewers' | 'deps';

export interface TaskEditModalProps {
  chainId: string;
  task: TaskWire;
  field: TaskEditField | null;
  onClose: () => void;
  /** All tasks of the chain, for the dependency picker. */
  tasks?: TaskWire[];
  chainFleets?: any[];
  names?: TaskNames;
}

const TITLES: Record<TaskEditField, string> = {
  assignee: 'Who works on it',
  reviewers: 'Who must approve it',
  deps: 'What it waits for',
};

/**
 * Change a task's assignee, required reviews or dependencies (plan REQ-UI-11).
 * Agents are picked by name; review roles come from the chain's fleet.
 * Assigning an agent adds it to the chain's fleet, and the hub may start it right
 * away, so the dialog says so.
 */
export const TaskEditModal: React.FC<TaskEditModalProps> = ({
  chainId,
  task,
  field,
  onClose,
  tasks = [],
  chainFleets = [],
  names = EMPTY_TASK_NAMES,
}) => {
  const [updateTask, updateState] = useUpdateTaskDetailMutation();
  const { data: identitiesData } = useListAgentIdentitiesQuery();
  const agents: any[] = identitiesData?.agents || [];

  const currentAssignee = String(task.brief?.assignee || '');
  const currentRoles: string[] = task.brief?.review_roles || [];
  const currentDeps: string[] = task.depends_on || [];

  const [assignee, setAssignee] = useState(currentAssignee);
  const [roles, setRoles] = useState<string[]>(currentRoles);
  const [addReviewer, setAddReviewer] = useState('');
  const [userApproval, setUserApproval] = useState(Boolean(task.requires_user_approval));
  const [deps, setDeps] = useState<string[]>(currentDeps);
  const [error, setError] = useState('');

  // Reset the draft whenever the dialog opens for a field.
  useEffect(() => {
    setAssignee(currentAssignee);
    setRoles(currentRoles);
    setAddReviewer('');
    setUserApproval(Boolean(task.requires_user_approval));
    setDeps(currentDeps);
    setError('');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [field, task.task_id]);

  // Every review role someone in the fleet holds, plus the default "reviewer".
  const fleetRoles = useMemo(() => {
    const set = new Set<string>(['reviewer', ...currentRoles]);
    for (const f of chainFleets) for (const r of f?.roles || []) if (r !== 'worker') set.add(String(r));
    return Array.from(set);
  }, [chainFleets, currentRoles]);
  const holdersOf = (role: string) =>
    chainFleets.filter((f) => (f?.roles || []).includes(role)).map((f) => names.agent(String(f.agent_id)));

  const agentOptions = [
    { value: '', text: 'Any worker in the fleet' },
    ...agents.map((a) => ({ value: String(a.agent_id || a.agentId), text: String(a.name || a.display_name || names.agent(a.agent_id)) })),
  ];
  const reviewerOptions = [
    { value: '', text: 'Add a reviewer agent…' },
    ...agents.map((a) => ({ value: String(a.agent_id || a.agentId), text: String(a.name || a.display_name || names.agent(a.agent_id)) })),
  ];
  const depCandidates = tasks.filter((t) => t.task_id !== task.task_id);

  const save = async () => {
    if (!field) return;
    setError('');
    const args: any = { chainId, taskId: task.task_id };
    if (field === 'assignee') args.assigneeRef = { type: 'agent_id', agent_id: assignee };
    if (field === 'reviewers') {
      args.reviewRoles = roles;
      args.requiresUserApproval = userApproval;
      if (addReviewer) args.reviewerRefs = [{ type: 'agent_id', agent_id: addReviewer }];
    }
    if (field === 'deps') args.dependsOn = deps;
    try {
      await updateTask(args).unwrap();
      onClose();
    } catch (err) {
      setError(actionErrorMessage(err));
    }
  };

  const toggle = (list: string[], value: string, on: boolean) => (on ? [...list, value] : list.filter((v) => v !== value));

  return (
    <Modal open={Boolean(field)} onOpenChange={(open) => !open && onClose()} title={field ? TITLES[field] : ''} size="sm">
      <ModalBody className="space-y-3 text-xs">
        <Text as="p" role="caption" tone="muted">
          {task.title}
        </Text>

        {field === 'assignee' && (
          <>
            <Select value={assignee} onChange={setAssignee} options={agentOptions} width="full" aria-label="Assignee" />
            <Text as="p" role="caption" tone="warning">
              Assigning an agent adds it to this chain's fleet. If the task is ready, the agent may start right away.
            </Text>
          </>
        )}

        {field === 'reviewers' && (
          <>
            <div className="space-y-1.5">
              <Text as="p" role="caption" tone="muted">
                Required reviews (everyone holding a checked role must approve):
              </Text>
              {fleetRoles.map((role) => {
                const holders = holdersOf(role);
                return (
                  <Checkbox
                    key={role}
                    checked={roles.includes(role)}
                    onChange={(on) => setRoles((r) => toggle(r, role, on))}
                    label={
                      <span>
                        {role}{' '}
                        <span className={holders.length ? 'text-muted' : 'text-warning'}>
                          {holders.length ? `(${holders.join(', ')})` : '(nobody in the fleet has this role yet)'}
                        </span>
                      </span>
                    }
                  />
                );
              })}
            </div>
            <Select value={addReviewer} onChange={setAddReviewer} options={reviewerOptions} width="full" aria-label="Add a reviewer agent" />
            <Checkbox checked={userApproval} onChange={setUserApproval} label="I approve it too (final review is mine)" />
          </>
        )}

        {field === 'deps' &&
          (depCandidates.length === 0 ? (
            <Text as="p" role="caption" tone="faint">
              There are no other tasks in this chain.
            </Text>
          ) : (
            <div className="max-h-64 space-y-1 overflow-y-auto">
              {depCandidates.map((t) => {
                const state = normalizeTaskState(t.state);
                return (
                  <div key={t.task_id} className="flex min-w-0 items-center justify-between gap-2">
                    <Checkbox
                      checked={deps.includes(t.task_id)}
                      onChange={(on) => setDeps((d) => toggle(d, t.task_id, on))}
                      label={<span className="truncate">{t.title}</span>}
                    />
                    <StatusPill tone={TASK_STATE_TONE[state]}>{TASK_STATE_LABELS[state]}</StatusPill>
                  </div>
                );
              })}
            </div>
          ))}

        {error && (
          <Text as="p" role="caption" tone="danger" className="whitespace-pre-line break-words">
            {error}
          </Text>
        )}
      </ModalBody>
      <ModalFooter>
        {field === 'assignee' && assignee !== currentAssignee && assignee && <Badge tone="warning">May start now</Badge>}
        <Button size="sm" variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button size="sm" variant="primary" loading={updateState.isLoading} onClick={save}>
          Save
        </Button>
      </ModalFooter>
    </Modal>
  );
};

export default TaskEditModal;
