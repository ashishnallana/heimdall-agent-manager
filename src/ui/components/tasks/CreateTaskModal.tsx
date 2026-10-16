import React, { useMemo, useState } from 'react';
import { Checkbox, Icon, IconButton, Select, Spinner } from '@ui';
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
    if (briefBuild.errors.length > 0) {
      setErrorMsg(briefBuild.errors[0]);
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

  if (!isOpen) return null;

  return (
    <div
      data-debug-id="create-task-modal-backdrop"
      className="fixed inset-x-0 top-0 app-viewport-height z-50 flex items-center justify-center bg-surface-overlay/80 backdrop-blur-sm p-4 overflow-y-auto"
      onClick={onClose}
    >
      <div
        data-debug-id="create-task-modal"
        className="w-full max-w-lg rounded-xl border border-subtle bg-surface p-5 text-xs text-primary shadow-panel my-8"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between border-b border-subtle pb-3">
          <div>
            <h3 className="text-sm font-bold text-primary">Create New Task</h3>
            <p className="text-caption text-muted mt-0.5">Assign tasks to durable agent roles for automated fleet provisioning.</p>
          </div>
          <IconButton icon="close" label="Close" size="sm" onClick={onClose} />
        </div>

        <form onSubmit={handleSubmit} className="mt-4 space-y-4">
          {/* Title */}
          <div>
            <label className="block font-semibold text-primary mb-1">
              Title <span className="text-danger">*</span>
            </label>
            <input
              type="text"
              data-debug-id="create-task-title-input"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="e.g. Implement user authentication endpoint"
              className="w-full rounded border border-subtle bg-surface-raised p-2 text-primary focus:outline-none focus:border-accent"
              autoFocus
            />
          </div>

          {/* Description */}
          <div>
            <label className="block font-semibold text-primary mb-1">Description (optional)</label>
            <textarea
              data-debug-id="create-task-description-input"
              value={desc}
              onChange={(e) => setDesc(e.target.value)}
              rows={3}
              placeholder="Specify requirements, files, and acceptance criteria..."
              className="w-full rounded border border-subtle bg-surface-raised p-2 text-primary focus:outline-none focus:border-accent"
            />
          </div>

          {/* Brief (Task System v2) — what the hub validates at publish. */}
          <div data-debug-id="create-task-brief" className="rounded-lg border border-subtle bg-surface-raised/40 p-3 space-y-2.5">
            <div>
              <label className="block font-semibold text-primary">Brief</label>
              <p className="text-[11px] text-muted mt-0.5">
                Required to publish: a goal, at least one acceptance criterion, and a verify command.
              </p>
            </div>

            <div>
              <label className="block font-semibold text-primary mb-1">
                Goal <span className="text-danger">*</span>
                <span className="ml-1 font-normal text-faint">({goal.trim().length}/{BRIEF_GOAL_MAX})</span>
              </label>
              <textarea
                data-debug-id="create-task-goal-input"
                value={goal}
                onChange={(e) => setGoal(e.target.value)}
                rows={3}
                maxLength={BRIEF_GOAL_MAX}
                placeholder="What outcome should the agent deliver?"
                className="w-full rounded border border-subtle bg-surface p-2 text-primary focus:outline-none focus:border-accent"
              />
            </div>

            <div>
              <label className="block font-semibold text-primary mb-1">
                Acceptance criteria <span className="text-danger">*</span>
                <span className="ml-1 font-normal text-faint">(one per line, 1–{BRIEF_ACCEPTANCE_MAX} items, ≤{BRIEF_ACCEPTANCE_ITEM_MAX} chars each)</span>
              </label>
              <textarea
                data-debug-id="create-task-acceptance-input"
                value={acceptanceText}
                onChange={(e) => setAcceptanceText(e.target.value)}
                rows={3}
                placeholder={'Endpoint returns 201 on success\nUnit tests cover the error path'}
                className="w-full rounded border border-subtle bg-surface p-2 text-primary font-mono focus:outline-none focus:border-accent"
              />
            </div>

            <div>
              <label className="block font-semibold text-primary mb-1">
                Verify command <span className="text-danger">*</span>
              </label>
              <input
                type="text"
                data-debug-id="create-task-verify-input"
                value={verify}
                onChange={(e) => setVerify(e.target.value)}
                placeholder="e.g. npm test"
                className="w-full rounded border border-subtle bg-surface p-2 text-primary font-mono focus:outline-none focus:border-accent"
              />
              <p className="text-[11px] text-muted mt-1">
                Run by <code>ham-ctl verify</code> in the chain directory; the task cannot be submitted until it passes.
              </p>
            </div>

            <div>
              <label className="block font-semibold text-primary mb-1">Review roles (optional)</label>
              <input
                type="text"
                data-debug-id="create-task-review-roles-input"
                value={reviewRolesText}
                onChange={(e) => setReviewRolesText(e.target.value)}
                placeholder="e.g. reviewer, security"
                className="w-full rounded border border-subtle bg-surface p-2 text-primary focus:outline-none focus:border-accent"
              />
              <p className="text-[11px] text-muted mt-1">
                Comma-separated. Each role needs a fleet row in this chain, or publish is rejected.
              </p>
            </div>
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
          <div className="rounded-lg border border-subtle bg-surface-raised/40 p-3 space-y-2.5">
            <label className="block font-semibold text-primary">Initial Assignee</label>
            <div data-debug-id="create-task-assignee-mode" className="flex gap-1 rounded bg-surface p-1">
              <button
                type="button"
                data-debug-id="create-task-assignee-mode-agent"
                onClick={() => setAssigneeMode('agent')}
                className={`rounded px-2.5 py-1 font-semibold transition-colors cursor-pointer ${
                  assigneeMode === 'agent' ? 'bg-accent text-accent-fg' : 'text-muted hover:text-primary'
                }`}
              >
                Agent Role
              </button>
              <button
                type="button"
                data-debug-id="create-task-assignee-mode-unassigned"
                onClick={() => setAssigneeMode('unassigned')}
                className={`rounded px-2.5 py-1 font-semibold transition-colors cursor-pointer ${
                  assigneeMode === 'unassigned' ? 'bg-accent text-accent-fg' : 'text-muted hover:text-primary'
                }`}
              >
                Unassigned
              </button>
              <button
                type="button"
                data-debug-id="create-task-assignee-mode-user"
                onClick={() => setAssigneeMode('user')}
                className={`rounded px-2.5 py-1 font-semibold transition-colors cursor-pointer ${
                  assigneeMode === 'user' ? 'bg-accent text-accent-fg' : 'text-muted hover:text-primary'
                }`}
              >
                User
              </button>
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
                <input
                  type="text"
                  data-debug-id="create-task-assignee-userid-input"
                  value={assigneeUserId}
                  onChange={(e) => setAssigneeUserId(e.target.value)}
                  placeholder="e.g. user"
                  className="w-full rounded border border-subtle bg-surface-raised p-2 text-primary focus:outline-none focus:border-accent"
                />
              </div>
            )}
          </div>

          {/* Reviewers Section */}
          <div className="rounded-lg border border-subtle bg-surface-raised/40 p-3 space-y-2.5">
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
                      <button
                        type="button"
                        onClick={() => handleRemoveReviewer(idx)}
                        className="text-muted hover:text-danger ml-0.5 cursor-pointer"
                        title="Remove reviewer"
                      >
                        ×
                      </button>
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
                <button
                  type="button"
                  data-debug-id="create-task-add-reviewer-btn"
                  onClick={handleAddReviewer}
                  className="rounded bg-neutral-soft hover:bg-surface-raised px-3 py-1.5 font-semibold text-accent border border-subtle cursor-pointer shrink-0"
                >
                  + Add
                </button>
              </div>
            </div>
          </div>

          {/* Depends On Section */}
          {existingTasks.length > 0 && (
            <div className="rounded-lg border border-subtle bg-surface-raised/40 p-3 space-y-2">
              <label className="block font-semibold text-primary">
                Blocked On (Depends On) {dependsOnIds.length > 0 && `(${dependsOnIds.length})`}
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
                      <span className="font-mono text-muted text-[10px]">{tid}</span>
                      <span className="truncate flex-1 font-medium">{t.title}</span>
                      <span className="text-[10px] text-faint uppercase font-mono">{t.status}</span>
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

          {/* Modal Actions */}
          <div className="flex items-center justify-end gap-2 border-t border-subtle pt-3">
            <button
              type="button"
              onClick={onClose}
              className="rounded bg-neutral-soft px-3 py-1.5 font-semibold text-primary hover:bg-surface-raised cursor-pointer"
            >
              Cancel
            </button>
            <button
              type="submit"
              data-debug-id="create-task-submit-btn"
              disabled={isCreating || !username}
              className="rounded bg-accent px-4 py-1.5 font-semibold text-accent-fg hover:opacity-90 disabled:opacity-50 cursor-pointer flex items-center gap-1.5"
            >
              {isCreating ? <Spinner size="sm" /> : null}
              <span>{isCreating ? 'Creating…' : 'Create Task'}</span>
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};

export default CreateTaskModal;
