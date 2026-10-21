// Task System v2 UI: per-reviewer verdicts on the current attempt (task.reviews),
// shown as ✓ / ✗ beside each reviewer, and no Approve once you approved.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_task_v2_review_votes_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { awaitingYourReview, getTaskActions, reviewVotes, taskNeedsYou, youApproved } from '../src/ui/components/tasks/taskActions.ts';
import type { TaskReviewWire, TaskWire } from '../src/ui/api/taskWire.ts';

const review = (reviewer: string, verdict: string, role = 'qa'): TaskReviewWire => ({
  reviewer,
  reviewer_kind: reviewer === 'user' ? 'user' : 'agent',
  reviewer_instance_id: '',
  role,
  verdict,
  created_at: '',
});

function task(reviews: TaskReviewWire[], overrides: Record<string, unknown> = {}): TaskWire {
  return {
    task_id: 'task_x',
    chain_id: 'chain_x',
    title: 'T',
    state: 'in_review',
    publish_state: 'published',
    kind: 'task',
    attempt_no: 1,
    priority: 'p2',
    requires_user_approval: true,
    brief: { goal: 'g', review_roles: ['qa'] },
    reviews,
    ...overrides,
  } as unknown as TaskWire;
}

test('votes are keyed by reviewer; an agent with several roles approves only if all did', () => {
  const votes = reviewVotes(task([review('agt_a', 'approve'), review('agt_b', 'approve', 'qa'), review('agt_b', 'request_changes', 'security'), review('user', 'approve')]));
  assert.equal(votes.get('agt_a'), 'approve');
  assert.equal(votes.get('agt_b'), 'request_changes');
  assert.equal(votes.get('user'), 'approve');
  assert.equal(reviewVotes(task([])).size, 0);
});

test('before you approve, the task awaits your review and offers Approve', () => {
  const t = task([review('agt_a', 'approve')]);
  assert.ok(awaitingYourReview(t));
  assert.ok(getTaskActions(t).primary.includes('approve'));
  assert.ok(!youApproved(t));
});

test('after you approve while others still review, Approve is gone and it no longer needs you', () => {
  const t = task([review('user', 'approve')]);
  assert.ok(youApproved(t));
  assert.ok(!awaitingYourReview(t));
  assert.ok(!getTaskActions(t).primary.includes('approve'));
  assert.ok(!taskNeedsYou(t));
});
