// Task System v2 (M2): the create-task brief payload builder, its client-side
// validation (mirrors the hub's brief_publish_problems), and the wording of a
// 422 brief_incomplete publish error.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_task_brief_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  BRIEF_ACCEPTANCE_ITEM_MAX,
  BRIEF_ACCEPTANCE_MAX,
  BRIEF_GOAL_MAX,
  briefIncompleteMessage,
  buildTaskBrief,
  parseCommaList,
  parseLineList,
  publishErrorMessage,
} from '../src/ui/utils/taskBrief.ts';
import { ApiError, cookieMutation } from '../src/ui/api/cookieFetch.ts';

test('buildTaskBrief produces the hub brief shape from form fields', () => {
  const { brief, errors, missing } = buildTaskBrief({
    goal: '  Ship the endpoint  ',
    acceptanceText: 'returns 201\n\n  covers the error path \n',
    reviewRolesText: 'reviewer, security,reviewer',
    assignee: 'agt_worker',
  });
  assert.deepEqual(errors, []);
  assert.deepEqual(missing, []);
  assert.deepEqual(brief, {
    goal: 'Ship the endpoint',
    acceptance: ['returns 201', 'covers the error path'],
    review_roles: ['reviewer', 'security'],
    assignee: 'agt_worker',
  });
  // JSON-serialisable exactly as the wire body expects.
  assert.equal(JSON.stringify({ brief }), '{"brief":{"goal":"Ship the endpoint","acceptance":["returns 201","covers the error path"],"review_roles":["reviewer","security"],"assignee":"agt_worker"}}');
});

test('buildTaskBrief omits assignee when unset and never emits an output key without one', () => {
  const { brief } = buildTaskBrief({ goal: 'g', acceptanceText: 'a' });
  assert.ok(!('assignee' in brief));
  assert.ok(!('output' in brief));
  assert.deepEqual(brief.review_roles, []);
});

test('buildTaskBrief mirrors the hub publish rules', () => {
  const empty = buildTaskBrief({ goal: '', acceptanceText: '' });
  assert.deepEqual(empty.missing, ['goal', 'acceptance']);
  assert.equal(empty.errors.length, 2);

  const longGoal = buildTaskBrief({ goal: 'x'.repeat(BRIEF_GOAL_MAX + 1), acceptanceText: 'a' });
  assert.deepEqual(longGoal.missing, ['goal']);
  const maxGoal = buildTaskBrief({ goal: 'x'.repeat(BRIEF_GOAL_MAX), acceptanceText: 'a' });
  assert.deepEqual(maxGoal.missing, []);

  const tooMany = buildTaskBrief({ goal: 'g', acceptanceText: Array.from({ length: BRIEF_ACCEPTANCE_MAX + 1 }, (_, i) => `item ${i}`).join('\n') });
  assert.deepEqual(tooMany.missing, ['acceptance']);
  const longItem = buildTaskBrief({ goal: 'g', acceptanceText: `ok\n${'y'.repeat(BRIEF_ACCEPTANCE_ITEM_MAX + 1)}` });
  assert.deepEqual(longItem.missing, ['acceptance']);
  assert.match(longItem.errors[0], /criterion 2/);

  // REQ-TV2-2: goal + ≥1 acceptance item is all a publish needs. A
  // command-free planning ticket publishes with no output contract.
  const planning = buildTaskBrief({ goal: 'Plan the migration', acceptanceText: 'A written plan with risks' });
  assert.deepEqual(planning.missing, []);
  assert.deepEqual(planning.errors, []);
  assert.ok(!('output' in planning.brief));
  // An output contract is still carried when given, never required.
  const withOutput = buildTaskBrief({ goal: 'g', acceptanceText: 'a', output: { schema: 'report/v1' } });
  assert.deepEqual(withOutput.missing, []);
  assert.deepEqual(withOutput.brief.output, { schema: 'report/v1' });
});

test('buildTaskBrief never emits removed verification keys, even from a legacy caller', () => {
  const legacy = buildTaskBrief({ goal: 'g', acceptanceText: 'a', verify: 'npm test', auto_submit: true, require_independent_verify: true } as any);
  assert.deepEqual(legacy.missing, []);
  for (const key of ['verify', 'auto_submit', 'require_independent_verify']) assert.ok(!(key in legacy.brief), key);
});

test('list parsers trim, drop blanks and de-duplicate roles', () => {
  assert.deepEqual(parseLineList(' a \r\n\n b\n'), ['a', 'b']);
  assert.deepEqual(parseLineList(undefined), []);
  assert.deepEqual(parseCommaList('a, b,,a\nc'), ['a', 'b', 'c']);
});

test('briefIncompleteMessage words each task with its title, falling back to the id', () => {
  const details = {
    code: 'brief_incomplete' as const,
    tasks: [
      { task_id: 'tsk_1', missing: ['goal', 'acceptance'] },
      { task_id: 'tsk_2', missing: ['review_role:security'] },
    ],
  };
  assert.equal(
    briefIncompleteMessage(details, { tsk_1: 'Ship endpoint' }),
    'Task Ship endpoint: missing goal, acceptance\nTask tsk_2: missing no fleet row for review role "security"',
  );
});

test('publishErrorMessage uses the 422 details from a real cookieMutation failure', async () => {
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async () => new Response(
    JSON.stringify({
      error: {
        code: 'validation_failed',
        message: 'brief incomplete: every published task needs goal …',
        details: { code: 'brief_incomplete', tasks: [{ task_id: 'tsk_9', missing: ['acceptance'] }] },
      },
      meta: {},
    }),
    { status: 422 },
  )) as typeof fetch;
  try {
    let caught: unknown;
    try {
      await cookieMutation('/task-chains/c/publish', 'POST', {});
    } catch (e) {
      caught = e;
    }
    assert.ok(caught instanceof ApiError);
    assert.equal(caught.status, 422);
    assert.deepEqual(caught.details, { code: 'brief_incomplete', tasks: [{ task_id: 'tsk_9', missing: ['acceptance'] }] });
    assert.equal(publishErrorMessage(caught, { tsk_9: 'Write docs' }), 'Task Write docs: missing acceptance');
    // Non-brief errors keep the hub sentence.
    assert.equal(publishErrorMessage(new ApiError('nope', 409, 'conflict')), 'nope');
  } finally {
    globalThis.fetch = realFetch;
  }
});
