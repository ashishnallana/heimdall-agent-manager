import { useState } from 'react';
import {
  useAddTaskCommentMutation,
  useAnswerTaskBlockerMutation,
  useCancelTaskDetailMutation,
  usePublishTaskMutation,
  useRecheckTaskMutation,
  useHoldTaskMutation,
  useReleaseTaskMutation,
  useReopenTaskMutation,
  useUpdateTaskDetailMutation,
  useUserReviewTaskMutation,
} from '../../api/endpoints/tasks';
import type { TaskRecheckResult } from '../../api/endpoints/tasks';

/** Readable text for a failed mutation (RTK error, hub envelope or thrown Error). */
export function actionErrorMessage(err: any): string {
  const raw = err?.data?.error?.message || err?.error?.message || err?.data?.message || err?.error || err?.message;
  const text = typeof raw === 'string' ? raw : '';
  // brief_incomplete lists what each task is missing; keep it short on a card.
  return text.trim() || 'Something went wrong. Try again.';
}

/**
 * Every human action on one task, shared by the card row and its expanded
 * details so both show the same busy state and error.
 */
export function useTaskActions(chainId: string, taskId: string, taskTitle = '') {
  const [userReview, review] = useUserReviewTaskMutation();
  const [answerBlocker, answer] = useAnswerTaskBlockerMutation();
  const [reopenTask, reopen] = useReopenTaskMutation();
  const [cancelTask, cancel] = useCancelTaskDetailMutation();
  const [updateTask, update] = useUpdateTaskDetailMutation();
  const [addComment, comment] = useAddTaskCommentMutation();
  const [publishTask, publish] = usePublishTaskMutation();
  const [recheckTask, recheck] = useRecheckTaskMutation();
  const [holdTask, hold] = useHoldTaskMutation();
  const [releaseTask, release] = useReleaseTaskMutation();
  const [error, setError] = useState('');

  const run = async (fn: () => Promise<unknown>): Promise<boolean> => {
    setError('');
    try {
      await fn();
      return true;
    } catch (err) {
      setError(actionErrorMessage(err));
      return false;
    }
  };

  return {
    error,
    clearError: () => setError(''),
    busy:
      review.isLoading ||
      answer.isLoading ||
      reopen.isLoading ||
      cancel.isLoading ||
      update.isLoading ||
      comment.isLoading ||
      publish.isLoading ||
      recheck.isLoading ||
      hold.isLoading ||
      release.isLoading,
    // Titles let a brief_incomplete error name the task instead of its id.
    publish: () => run(() => publishTask({ chainId, taskId, taskTitles: taskTitle ? { [taskId]: taskTitle } : undefined }).unwrap()),
    approve: () => run(() => userReview({ chainId, taskId, verdict: 'approve' }).unwrap()),
    // The caller must supply findings; an empty request-changes is not sent.
    requestChanges: (findings: string) =>
      !findings.trim()
        ? Promise.resolve(false)
        : run(() =>
            userReview({ chainId, taskId, verdict: 'request_changes', findings: [findings.trim()], summary: findings.trim() }).unwrap(),
          ),
    answer: (note: string) => run(() => answerBlocker({ chainId, taskId, note }).unwrap()),
    reopen: () => run(() => reopenTask({ chainId, taskId }).unwrap()),
    // Resolves to the hub's result (for the toast), or null on failure (error set).
    recheck: async (): Promise<TaskRecheckResult | null> => {
      let result: TaskRecheckResult | null = null;
      const ok = await run(async () => {
        result = await recheckTask({ chainId, taskId }).unwrap();
      });
      return ok ? result : null;
    },
    // A hold needs a reason (the hub refuses an empty one); nothing is sent without it.
    hold: (reason: string) => (!reason.trim() ? Promise.resolve(false) : run(() => holdTask({ chainId, taskId, reason: reason.trim() }).unwrap())),
    release: () => run(() => releaseTask({ chainId, taskId }).unwrap()),
    cancel: () => run(() => cancelTask({ chainId, taskId }).unwrap()),
    pinBridge: (bridgeId: string) => run(() => updateTask({ chainId, taskId, bridgeId }).unwrap()),
    comment: (body: string) => run(() => addComment({ chainId, taskId, body: body.trim() }).unwrap()),
  };
}

export type TaskActionsApi = ReturnType<typeof useTaskActions>;
