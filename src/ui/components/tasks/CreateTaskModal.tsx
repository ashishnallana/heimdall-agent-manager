import React, { useMemo, useState } from 'react';
import { Button, Checkbox, FormField, Icon, IconButton, Input, Modal, ModalBody, ModalFooter, Select, StatusPill, Textarea } from '@ui';
import { TASK_STATE_LABELS, TASK_STATE_TONE, normalizeTaskState } from './taskV2Types';
import { useCreateTaskMutation } from '../../api/endpoints/tasks';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { taskBridgeOptions } from '../../utils/taskBridgePin';
import { formatFleetRoleName } from './FleetManagementDrawer';
import { useAuthUser } from '../auth/AuthUserContext';
import { BRIEF_ACCEPTANCE_ITEM_MAX, BRIEF_ACCEPTANCE_MAX, BRIEF_GOAL_MAX, buildTaskBrief } from '../../utils/taskBrief';

export interface CreateTaskModalProps {
  chainId: string;
  isOpen: boolean;
  onClose: () => void;
  onSuccess?: () => void;
  existingTasks?: any[];
}

export const CreateTaskModal: React.FC<CreateTaskModalProps> = ({
  chainId,
  isOpen,
  onClose,
  onSuccess,
  existingTasks = [],
}) => {
  const [createTask, { isLoading: isCreating }] = useCreateTaskMutation();
  const authUser = useAuthUser();
  const username = String(authUser?.user_id || '').trim();
  const agentIdentitiesQuery = useListAgentIdentitiesQuery();
  const agentIdentities = agentIdentitiesQuery.data?.agents || [];
  // REQ-TB-5: the owner's bridges for the optional per-task bridge pin. Skipped
  // while the modal is closed.
  const bridgesQuery = useListBridgesQuery(undefined, { skip: !isOpen });
  const bridgeOptions = useMemo(
    () => taskBridgeOptions(bridgesQuery.data?.bridges || []),
    [bridgesQuery.data],
  );

  const [title, setTitle] = useState('');
  const [desc, setDesc] = useState('');
  // Task System v2 (M2): the brief. Validated client-side with the hub's publish
  // rules (utils/taskBrief) so a human-created task is publishable as-is.
  const [goal, setGoal] = useState('');
  const [acceptanceText, setAcceptanceText] = useState('');
  const [verify, setVerify] = useState('');
  const [reviewRolesText, setReviewRolesText] = useState('');
  const [assigneeMode, setAssigneeMode] = useState<'agent' | 'unassigned' | 'user'>('agent');
  // REQ-TB-5: '' = Inherit (coordinator bridge) — the default create pins nothing.
  const [bridgeId, setBridgeId] = useState('');
  // REQ-AUTO-4: no literal placeholder default — the user picks a real durable
  // identity from the catalog, or the actor stays unassigned.
  const [assigneeAgentId, setAssigneeAgentId] = useState('');
  const [assigneeUserId, setAssigneeUserId] = useState('');

  const [stagedReviewers, setStagedReviewers] = useState<any[]>([]);
  const [reviewerAgentId, setReviewerAgentId] = useState('');
  const [requiresUserApproval, setRequiresUserApproval] = useState(false);

  const [dependsOnIds, setDependsOnIds] = useState<string[]>([]);
  const [errorMsg, setErrorMsg] = useState('');

  // Agent identities options with clean display names (no raw IDs). The empty
  // placeholder is always first so no actor is ever pre-selected: with no
  // catalog entries the only choice is to leave the field unassigned.
  const agentOptions = useMemo(() => {
    return [
      { value: '', label: 'Select agent identity…' },
      ...agentIdentities.map((a: any) => {
        const id = String(a.agent_id || a.agentId || a.id || '');
        const displayName = a.name || a.display_name || formatFleetRoleName(id, agentIdentities);
        return { value: id, label: displayName };
      }),
    ];
  }, [agentIdentities]);

  const handleAddReviewer = () => {
    if (!reviewerAgentId) return;
    if (stagedReviewers.some((r) => r.agent_id === reviewerAgentId)) return;
    setStagedReviewers((prev) => [
      ...prev,
      {
        type: 'agent_id',
        agent_id: reviewerAgentId,
        display_name: formatFleetRoleName(reviewerAgentId, agentIdentities),
      },
    ]);
  };

  const handleRemoveReviewer = (index: number) => {
    setStagedReviewers((prev) => prev.filter((_, i) => i !== index));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setErrorMsg('');
    const trimmedTitle = title.trim();
    if (!trimmedTitle) {
      setErrorMsg('Please enter a task title.');
      return;
    }

    let assigneeRef: any = undefined;
    if (assigneeMode === 'agent') {
      if (!assigneeAgentId) {
        setErrorMsg('Please select an agent role.');
        return;
      }
      assigneeRef = {
        type: 'agent_id',
        agent_id: assigneeAgentId,
        display_name: formatFleetRoleName(assigneeAgentId, agentIdentities),
      };
    } else if (assigneeMode === 'user') {
      const uid = assigneeUserId.trim();
      if (!uid) {
        setErrorMsg('Please enter a user ID.');
        return;
      }
      assigneeRef = { type: 'user', user_id: uid };
    }

    const briefBuild = buildTaskBrief({
      goal,
      acceptanceText,
      verify,
      reviewRolesText,
      assignee: assigneeMode === 'agent' ? assigneeAgentId : '',
    });
    // Allow draft creation when brief fields are still being sketched; reject only
    // when provided values exceed hub caps or violate verify:"none" rules.
    const hardBriefError = briefBuild.errors.find(
      (msg) => msg.includes('exceeds') || msg.includes('at most') || msg.includes('output contract'),
    );
    if (hardBriefError) {
      setErrorMsg(hardBriefError);
      return;
    }

    try {
      const payload: any = {
        chainId,
        title: trimmedTitle,
        description: desc.trim(),
        // '' is dropped by the createTask serialization (absent = inherit).
        bridgeId,
        requiresUserApproval,
        brief: briefBuild.brief,
      };
      if (assigneeRef !== undefined) {
        payload.assigneeRef = assigneeRef;
      }
      if (stagedReviewers.length > 0) {
        payload.reviewerRefs = stagedReviewers;
      }
      if (dependsOnIds.length > 0) {
        payload.dependsOn = dependsOnIds;
      }

      await createTask(payload).unwrap();
      // Reset form
      setTitle('');
      setDesc('');
      setGoal('');
      setAcceptanceText('');
      setVerify('');
      setReviewRolesText('');
      setAssigneeMode('agent');
      setAssigneeAgentId('');
      setBridgeId('');
      setStagedReviewers([]);
      setRequiresUserApproval(false);
      setDependsOnIds([]);
      onSuccess?.();
      onClose();
    } catch (err: any) {
      setErrorMsg(String(err?.data?.error?.message || err?.message || 'Failed to create task'));
    }
  };

  // Typed work is never thrown away silently: Esc, the backdrop and the close
  // button all ask first when the form has content (audit finding).
  const dirty = Boolean(title.trim() || desc.trim() || goal.trim() || acceptanceText.trim() || verify.trim() || reviewRolesText.trim());
  const requestClose = (next: boolean) => {
    if (next) return;
    if (dirty && !window.confirm('Discard this new task?')) return;
    onClose();
  };

  return (
    <Modal open={isOpen} onOpenChange={requestClose} title="New task" size="lg" data-debug-id="create-task-modal">
      <ModalBody>
        <p className="mb-4 text-caption text-muted">A goal, acceptance checks and a verify command make it publishable as-is.</p>
        <form id="create-task-form" onSubmit={handleSubmit} className="space-y-4 text-xs">
          {/* Title */}
          <FormField label="Title" required>
            <Input
              data-debug-id="create-task-title-input"
              value={title}
              onChange={setTitle}
              placeholder="e.g. Implement user authentication endpoint"
              width="full"
              autoFocus
            />
          </FormField>

          {/* Description */}
          <FormField label="Description (optional)">
            <Textarea
              data-debug-id="create-task-description-input"
              value={desc}
              onChange={setDesc}
              rows={3}
              placeholder="Context for the agent: requirements, files, constraints"
              width="full"
            />
          </FormField>

          {/* Brief (Task System v2) — what the hub validates at publish. */}
          <div data-debug-id="create-task-brief" className="space-y-2.5 border-t border-subtle pt-3">
            <div>
              <label className="block font-semibold text-primary">Brief</label>
              <p className="text-[11px] text-muted mt-0.5">
                Required to publish: a goal, at least one acceptance criterion, and a verify command.
              </p>
            </div>

            <FormField label="Goal" required hint={`${goal.trim().length} of ${BRIEF_GOAL_MAX} characters`}>
              <Textarea
                data-debug-id="create-task-goal-input"
                value={goal}
                onChange={setGoal}
                rows={3}
                maxLength={BRIEF_GOAL_MAX}
                placeholder="What outcome should the agent deliver?"
                width="full"
              />
            </FormField>

            <FormField
              label="Acceptance criteria"
              required
              hint={`One per line, 1 to ${BRIEF_ACCEPTANCE_MAX} items, up to ${BRIEF_ACCEPTANCE_ITEM_MAX} characters each`}
            >
              <Textarea
                data-debug-id="create-task-acceptance-input"
                value={acceptanceText}
                onChange={setAcceptanceText}
                rows={3}
                placeholder={'Endpoint returns 201 on success\nUnit tests cover the error path'}
                width="full"
              />
            </FormField>

            <FormField
              label="Verify command"
              required
              hint="Runs in the chain directory. The task can't be submitted until it passes."
            >
              <Input
                data-debug-id="create-task-verify-input"
                value={verify}
                onChange={setVerify}
                placeholder="e.g. npm test"
                width="full"
              />
            </FormField>

            <FormField
              label="Review roles (optional)"
              hint="Comma-separated. Each role needs someone in this chain's fleet, or publishing is rejected."
            >
              <Input
                data-debug-id="create-task-review-roles-input"
                value={reviewRolesText}
                onChange={setReviewRolesText}
                placeholder="e.g. reviewer, security"
                width="full"
              />
            </FormField>
          </div>

          {/* Bridge (REQ-TB-5) */}
          <div>
            <label className="block font-semibold text-primary mb-1">Bridge</label>
            <Select
              data-debug-id="create-task-bridge-select"
              width="full"
              value={bridgeId}
              onChange={setBridgeId}
              options={bridgeOptions}
            />
            <p className="text-[11px] text-muted mt-1">
              Pin this task to a specific bridge, or leave it on the coordinator&apos;s bridge.
            </p>
          </div>

          {/* Assignee Section */}
          <div className="space-y-2.5 border-t border-subtle pt-3">
            <label className="block font-semibold text-primary">Initial Assignee</label>
            <div data-debug-id="create-task-assignee-mode" className="flex gap-1 rounded bg-surface p-1">
              <Button
                type="button"
                size="sm"
                variant={assigneeMode === 'agent' ? 'primary' : 'ghost'}
                aria-pressed={assigneeMode === 'agent'}
                data-debug-id="create-task-assignee-mode-agent"
                onClick={() => setAssigneeMode('agent')}
              >
                Agent
              </Button>
              <Button
                type="button"
                size="sm"
                variant={assigneeMode === 'unassigned' ? 'primary' : 'ghost'}
                aria-pressed={assigneeMode === 'unassigned'}
                data-debug-id="create-task-assignee-mode-unassigned"
                onClick={() => setAssigneeMode('unassigned')}
              >
                Unassigned
              </Button>
              <Button
                type="button"
                size="sm"
                variant={assigneeMode === 'user' ? 'primary' : 'ghost'}
                aria-pressed={assigneeMode === 'user'}
                data-debug-id="create-task-assignee-mode-user"
                onClick={() => setAssigneeMode('user')}
              >
                User
              </Button>
            </div>

            {assigneeMode === 'agent' && (
              <div>
                <Select
                  data-debug-id="create-task-assignee-agentid-select"
                  width="full"
                  value={assigneeAgentId}
                  onChange={setAssigneeAgentId}
                  options={agentOptions}
                />
                <p className="text-[11px] text-muted mt-1">
                  The task will automatically dispatch to an idle worker or JIT-provision up to fleet capacity.
                </p>
              </div>
            )}

            {assigneeMode === 'user' && (
              <div>
                <Input
                  data-debug-id="create-task-assignee-userid-input"
                  value={assigneeUserId}
                  onChange={setAssigneeUserId}
                  placeholder="User id"
                  aria-label="Assignee user id"
                  width="full"
                />
              </div>
            )}
          </div>

          {/* Reviewers Section */}
          <div className="space-y-2.5 border-t border-subtle pt-3">
            <div className="flex items-center justify-between">
              <label className="font-semibold text-primary">
                Reviewers ({stagedReviewers.length})
              </label>
            </div>

            <Checkbox
              data-debug-id="create-task-require-user-approval-checkbox"
              checked={requiresUserApproval}
              onChange={setRequiresUserApproval}
              disabled={!username}
              label={username ? `Require approval from You (@${username})` : 'Loading your identity…'}
            />

            {stagedReviewers.length > 0 && (
              <div className="flex flex-wrap gap-1.5 rounded border border-subtle bg-surface p-2">
                {stagedReviewers.map((r, idx) => {
                  const label = r.display_name || r.agent_id || r.user_id;
                  return (
                    <span
                      key={r.agent_id || r.user_id || idx}
                      data-debug-id={`create-task-reviewer-chip-${idx}`}
                      className="inline-flex items-center gap-1.5 rounded-full bg-surface-raised border border-subtle px-2.5 py-0.5 text-xs text-primary"
                    >
                      <Icon name="check" size={11} className="text-accent" />
                      <span>{label}</span>
                      <IconButton
                        icon="close"
                        label="Remove reviewer"
                        variant="ghost"
                        size="sm"
                        onClick={() => handleRemoveReviewer(idx)}
                        className="ml-0.5"
                      />
                    </span>
                  );
                })}
              </div>
            )}

            <div className="border-t border-subtle pt-2 space-y-2">
              <span className="text-caption text-muted">Add Reviewer Role:</span>
              <div className="flex items-center gap-2">
                <Select
                  data-debug-id="create-task-reviewer-agentid-select"
                  width="full"
                  value={reviewerAgentId}
                  onChange={setReviewerAgentId}
                  options={agentOptions}
                />
                <Button
                  type="button"
                  size="sm"
                  variant="secondary"
                  data-debug-id="create-task-add-reviewer-btn"
                  onClick={handleAddReviewer}
                  className="shrink-0"
                >
                  Add reviewer
                </Button>
              </div>
            </div>
          </div>

          {/* Depends On Section */}
          {existingTasks.length > 0 && (
            <div className="space-y-2 border-t border-subtle pt-3">
              <label className="block font-semibold text-primary">
                Waits for {dependsOnIds.length > 0 && `(${dependsOnIds.length})`}
              </label>
              <div className="max-h-36 overflow-y-auto space-y-1 rounded border border-subtle bg-surface p-2">
                {existingTasks.map((t) => {
                  const tid = String(t.taskId || t.id);
                  const isSelected = dependsOnIds.includes(tid);
                  return (
                    <label
                      key={tid}
                      data-debug-id={`create-task-depends-on-${tid}`}
                      className={`flex items-center gap-2 rounded px-2 py-1 cursor-pointer text-xs transition-colors ${
                        isSelected ? 'bg-accent/15 border border-accent/30 text-primary' : 'hover:bg-neutral-soft text-muted'
                      }`}
                    >
                      <Checkbox
                        checked={isSelected}
                        onChange={(checked) => {
                          if (checked) {
                            setDependsOnIds((prev) => [...prev, tid]);
                          } else {
                            setDependsOnIds((prev) => prev.filter((id) => id !== tid));
                          }
                        }}
                      />
                      <span className="truncate flex-1 font-medium">{t.title}</span>
                      <StatusPill tone={TASK_STATE_TONE[normalizeTaskState(t.state || t.status)]}>
                        {TASK_STATE_LABELS[normalizeTaskState(t.state || t.status)]}
                      </StatusPill>
                    </label>
                  );
                })}
              </div>
            </div>
          )}

          {errorMsg && (
            <div data-debug-id="create-task-error" className="text-caption text-danger">
              {errorMsg}
            </div>
          )}

        </form>
      </ModalBody>
      <ModalFooter>
        <Button type="button" size="sm" variant="ghost" onClick={() => requestClose(false)}>
          Cancel
        </Button>
        <Button
          type="submit"
          form="create-task-form"
          size="sm"
          variant="primary"
          data-debug-id="create-task-submit-btn"
          disabled={isCreating || !username}
          loading={isCreating}
        >
          Create task
        </Button>
      </ModalFooter>
    </Modal>
  );
};

export default CreateTaskModal;
