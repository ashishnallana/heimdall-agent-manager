/**
 * REQ-FLEET-UI-ACTIONS-1: Action Button Helpers for Role-Assigned Fleet Tasks.
 * REQ-UI-CLI-FINISHING-1, REQ-UI-CLI-PAUSING-1: Support Finishing and Pausing states.
 *
 * Provides predicates and state helpers for task action buttons:
 * 1. Start button: Hide when task assignee ref is a declarative agent_id with no live instance_id bound.
 * 2. Nudge button: Hide when no target instance_id exists to receive the IPC wake notification.
 * 3. Pause & Cancel buttons: Keep accessible for operator control over pending/queued tasks.
 * 4. Unpause action: For role-assigned tasks without a live instance, transition to queued (or assigned)
 *    so the reconcile engine can allocate a fleet slot properly.
 * 5. LGTM & NGTM voting buttons: Keep accessible for operator validation.
 * 6. Complete & Force Finish / Pause & Force Pause: Handle finishing and pausing states.
 */

export function isRoleAssignedWithoutLiveInstance(task: any, allInstances?: any[]): boolean {
  if (!task) return false;
  const assigneeRef = task.assigneeRef || task.assignee_ref;
  const targetAgentId =
    assigneeRef?.agent_id ||
    assigneeRef?.agentId ||
    task.assigneeAgentId ||
    task.assignee_agent_id;
  const boundInstanceId =
    task.assigneeAgentInstanceId ||
    task.assignee_agent_instance_id ||
    assigneeRef?.agent_instance_id ||
    assigneeRef?.agentInstanceId;

  // If not role-targeted (no agent_id), it is not a role-assigned task
  if (!targetAgentId) return false;

  // Declarative role without any bound instance id
  if (!boundInstanceId) return true;

  // If a bound instance id is present, check if it is still live
  if (allInstances && allInstances.length > 0) {
    const inst = allInstances.find(
      (i) => String(i.agent_instance_id || i.agentInstanceId || i.id || '') === String(boundInstanceId)
    );
    if (inst) {
      const s = String(inst.runtime_status || inst.runtimeStatus || inst.status || '').toLowerCase();
      if (s === 'stopped' || s === 'failed' || s === 'terminated') {
        return true;
      }
    }
  }

  return false;
}

export function canStartTask(task: any, allInstances?: any[]): boolean {
  if (!task) return false;
  const actions = task.allowedActions || task.allowed_actions;
  if (Array.isArray(actions) && actions.includes('start')) {
    return true;
  }
  const status = String(task.status || '').toLowerCase();
  if (status === 'pausing') {
    return true;
  }
  return !isRoleAssignedWithoutLiveInstance(task, allInstances);
}

export function canCompleteTask(task: any): boolean {
  if (!task) return false;
  const actions = task.allowedActions || task.allowed_actions;
  if (Array.isArray(actions)) {
    return actions.includes('complete') || actions.includes('force_finish');
  }
  const status = String(task.status || '').toLowerCase();
  return status === 'finishing';
}

export function canPauseTask(task: any): boolean {
  if (!task) return false;
  const actions = task.allowedActions || task.allowed_actions;
  if (Array.isArray(actions)) {
    return actions.includes('pause') || actions.includes('force_pause');
  }
  const status = String(task.status || '').toLowerCase();
  return status === 'in_progress' || status === 'finishing' || status === 'pausing';
}

export function hasLiveNudgeTarget(task: any, allInstances?: any[]): boolean {
  if (!task) return false;
  const status = String(task.status || '').toLowerCase();

  // Queued, completed, and cancelled tasks do not receive nudges
  if (status === 'queued' || status === 'completed' || status === 'cancelled') {
    return false;
  }

  if (status === 'in_validation') {
    const reviewerRefs = (task.reviewerRefs || task.reviewer_refs || []) as any[];
    const reviewerInstanceIds: string[] = [];
    for (const ref of reviewerRefs) {
      const iid = ref.agent_instance_id || ref.agentInstanceId;
      if (iid) reviewerInstanceIds.push(String(iid));
    }
    const singleRev = task.reviewerAgentInstanceId || task.reviewer_agent_instance_id;
    if (singleRev && !reviewerInstanceIds.includes(String(singleRev))) {
      reviewerInstanceIds.push(String(singleRev));
    }

    if (reviewerInstanceIds.length === 0) return false;

    if (allInstances && allInstances.length > 0) {
      return reviewerInstanceIds.some((id) => {
        const inst = allInstances.find(
          (i) => String(i.agent_instance_id || i.agentInstanceId || i.id || '') === id
        );
        if (!inst) return true;
        const s = String(inst.runtime_status || inst.runtimeStatus || inst.status || '').toLowerCase();
        return s !== 'stopped' && s !== 'failed' && s !== 'terminated';
      });
    }
    return true;
  }

  // in_progress, finishing, pausing, assigned, paused, validated_not_good
  const assigneeRef = task.assigneeRef || task.assignee_ref;
  const boundInstanceId =
    task.assigneeAgentInstanceId ||
    task.assignee_agent_instance_id ||
    assigneeRef?.agent_instance_id ||
    assigneeRef?.agentInstanceId;

  if (!boundInstanceId) return false;

  if (allInstances && allInstances.length > 0) {
    const inst = allInstances.find(
      (i) => String(i.agent_instance_id || i.agentInstanceId || i.id || '') === String(boundInstanceId)
    );
    if (inst) {
      const s = String(inst.runtime_status || inst.runtimeStatus || inst.status || '').toLowerCase();
      if (s === 'stopped' || s === 'failed' || s === 'terminated') {
        return false;
      }
    }
  }

  return true;
}

export function getUnpauseStatus(task: any, allInstances?: any[]): 'queued' | 'in_progress' {
  return isRoleAssignedWithoutLiveInstance(task, allInstances) ? 'queued' : 'in_progress';
}
