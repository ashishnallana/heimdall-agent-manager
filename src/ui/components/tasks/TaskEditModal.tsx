import React, { useEffect, useMemo, useState } from 'react';
import { Badge, Button, Checkbox, Modal, ModalBody, ModalFooter, Select, StatusPill, Text } from '@ui';
import type { TaskWire } from '../../api/taskWire';
import { useUpdateTaskDetailMutation } from '../../api/endpoints/tasks';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';
import { useListChainReviewRolesQuery } from '../../api/endpoints/taskChains';
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
  // Mounted once per TaskCard while closed: only an open assignee/reviewer picker needs
  // the identity catalogue.
  const { data: identitiesData } = useListAgentIdentitiesQuery(undefined, { skip: field !== 'assignee' && field !== 'reviewers' });
  const agents: any[] = identitiesData?.agents || [];

  const currentAssignee = String(task.brief?.assignee || '');
  const currentRoles: string[] = task.brief?.review_roles || [];
  const currentDeps: string[] = task.depends_on || [];

  const [assignee, setAssignee] = useState(currentAssignee);
  const currentNamed: string[] = task.brief?.reviewers || [];
  const [roles, setRoles] = useState<string[]>(currentRoles);
  const [named, setNamed] = useState<string[]>(currentNamed);
  const [userApproval, setUserApproval] = useState(Boolean(task.requires_user_approval));
  const [deps, setDeps] = useState<string[]>(currentDeps);
  const [error, setError] = useState('');

  // Reset the draft whenever the dialog opens for a field.
  useEffect(() => {
    setAssignee(currentAssignee);
    setRoles(currentRoles);
    setNamed(currentNamed);
    setUserApproval(Boolean(task.requires_user_approval));
    setDeps(currentDeps);
    setError('');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [field, task.task_id]);

  // Chain review roles (optional layer) with their descriptions and holders.
  const { data: chainRoles = [] } = useListChainReviewRolesQuery({ chainId }, { skip: field !== 'reviewers' });
  const roleList = useMemo(() => {
    const byName = new Map(chainRoles.map((r) => [r.name, r]));
    for (const r of currentRoles) if (!byName.has(r)) byName.set(r, { name: r, description: '', holders: [], openTaskCount: 0 });
    return Array.from(byName.values());
  }, [chainRoles, currentRoles]);

  const agentOptions = [
    { value: '', text: 'Any worker in the fleet' },
    ...agents.map((a) => ({ value: String(a.agent_id || a.agentId), text: String(a.name || a.display_name || names.agent(a.agent_id)) })),
  ];
  const depCandidates = tasks.filter((t) => t.task_id !== task.task_id);

  const save = async () => {
    if (!field) return;
    setError('');
    const args: any = { chainId, taskId: task.task_id };
    if (field === 'assignee') args.assigneeRef = { type: 'agent_id', agent_id: assignee };
    if (field === 'reviewers') {
      // Replaces the task's named reviewers (an empty list clears them).
      args.reviewerRefs = named.map((agent_id) => ({ type: 'agent_id', agent_id }));
      args.reviewRoles = roles;
      args.requiresUserApproval = userApproval;
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
              Assigning an agent adds it to this chain's fleet. If the ticket is ready, the agent may start right away.
            </Text>
          </>
        )}

        {field === 'reviewers' && (
          <>
            <div className="space-y-1.5">
              <Text as="p" role="caption" tone="muted">
                Reviewers of this ticket (each must approve):
              </Text>
              <div className="max-h-48 space-y-1 overflow-y-auto">
                {agents.map((a) => {
                  const id = String(a.agent_id || a.agentId);
                  const isAssignee = id === currentAssignee;
                  return (
                    <Checkbox
                      key={id}
                      checked={named.includes(id)}
                      disabled={isAssignee}
                      onChange={(on) => setNamed((n) => toggle(n, id, on))}
                      label={
                        <span>
                          {String(a.name || a.display_name || names.agent(id))}
                          {isAssignee && <span className="text-faint"> (assignee, can't review its own work)</span>}
                        </span>
                      }
                    />
                  );
                })}
              </div>
            </div>
            <Checkbox checked={userApproval} onChange={setUserApproval} label="I approve it too (final review is mine)" />
            <details className="space-y-1.5">
              <summary className="cursor-pointer text-muted hover:text-primary">
                Review roles (optional){roles.length ? `: ${roles.join(', ')}` : ''}
              </summary>
              <Text as="p" role="caption" tone="muted">
                A role asks every agent holding it to review. Useful for templates and coordinators. Manage roles from the
                chain's Review roles.
              </Text>
              {roleList.map((role) => (
                <Checkbox
                  key={role.name}
                  checked={roles.includes(role.name)}
                  onChange={(on) => setRoles((r) => toggle(r, role.name, on))}
                  label={
                    <span>
                      {role.name}{' '}
                      <span className={role.holders.length ? 'text-muted' : 'text-warning'}>
                        ({role.holders.length ? role.holders.map(names.agent).join(', ') : 'nobody holds it'})
                      </span>
                      {role.description && <span className="block text-faint">{role.description}</span>}
                    </span>
                  }
                />
              ))}
            </details>
          </>
        )}

        {field === 'deps' &&
          (depCandidates.length === 0 ? (
            <Text as="p" role="caption" tone="faint">
              There are no other tickets in this chain.
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
