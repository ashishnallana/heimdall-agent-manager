import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  installFetchCapture,
  installWindowShim,
  makeVaultStore,
  lockVaultFully,
} from './helpers/vaultEndpointHarness.ts';

const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
const { endpoints } = tasksApi;

test('createTask forwards explicit requires_user_approval boolean and omits when undefined', async () => {
  const cap = installFetchCapture();
  installWindowShim();
  const store = await makeVaultStore();
  try {
    cap.reset();
    cap.setNextResponse({ data: { task_id: 'tsk_1', chain_id: 'chn_1', title: 'Review PR' } });
    const res1 = await store.dispatch(
      endpoints.createTask.initiate({
        chainId: 'chn_1',
        title: 'Review PR',
        requiresUserApproval: true,
      }),
    );
    assert.ok(!res1?.error, `createTask failed: ${JSON.stringify(res1?.error)}`);
    const postTrue = cap.find((r) => r.method === 'POST' && r.url.includes('/task-chains/chn_1/tasks'));
    assert.equal(postTrue.body.requires_user_approval, true);

    cap.reset();
    cap.setNextResponse({ data: { task_id: 'tsk_2', chain_id: 'chn_1', title: 'Auto Task' } });
    await store.dispatch(
      endpoints.createTask.initiate({
        chainId: 'chn_1',
        title: 'Auto Task',
        requiresUserApproval: false,
      }),
    );
    const postFalse = cap.find((r) => r.method === 'POST' && r.url.includes('/task-chains/chn_1/tasks'));
    assert.equal(postFalse.body.requires_user_approval, false);

    cap.reset();
    cap.setNextResponse({ data: { task_id: 'tsk_3', chain_id: 'chn_1', title: 'Default Task' } });
    await store.dispatch(
      endpoints.createTask.initiate({
        chainId: 'chn_1',
        title: 'Default Task',
      }),
    );
    const postOmitted = cap.find((r) => r.method === 'POST' && r.url.includes('/task-chains/chn_1/tasks'));
    assert.equal('requires_user_approval' in postOmitted.body, false);
  } finally {
    await lockVaultFully(store);
  }
});

test('updateTaskDetail patches requires_user_approval only when explicitly provided', async () => {
  const cap = installFetchCapture();
  installWindowShim();
  const store = await makeVaultStore();
  try {
    cap.reset();
    cap.setNextResponse({ data: { task_id: 'tsk_1', requires_user_approval: true } });
    const res1 = await store.dispatch(
      endpoints.updateTaskDetail.initiate({
        chainId: 'chn_1',
        taskId: 'tsk_1',
        requiresUserApproval: true,
      }),
    );
    assert.ok(!res1?.error, `updateTaskDetail failed: ${JSON.stringify(res1?.error)}`);
    const patchTrue = cap.find((r) => r.method === 'PATCH' && r.url.includes('/task-chains/chn_1/tasks/tsk_1'));
    assert.equal(patchTrue.body.requires_user_approval, true);

    cap.reset();
    cap.setNextResponse({ data: { task_id: 'tsk_1', title: 'Renamed' } });
    await store.dispatch(
      endpoints.updateTaskDetail.initiate({
        chainId: 'chn_1',
        taskId: 'tsk_1',
        title: 'Renamed',
      }),
    );
    const patchOmitted = cap.find((r) => r.method === 'PATCH' && r.url.includes('/task-chains/chn_1/tasks/tsk_1'));
    assert.equal('requires_user_approval' in patchOmitted.body, false);
  } finally {
    await lockVaultFully(store);
  }
});

test('fetchTaskChainDetail normalizes requires_user_approval and requiresUserApproval into dual-cased fields', async () => {
  const cap = installFetchCapture();
  installWindowShim();
  const store = await makeVaultStore();
  try {
    cap.reset();
    cap.setNextResponse({
      data: {
        chain_id: 'chn_1',
        title: 'Chain',
        tasks: [
          { task_id: 'tsk_snake', title: 'Snake', requires_user_approval: true },
          { task_id: 'tsk_camel', title: 'Camel', requiresUserApproval: true },
          { task_id: 'tsk_default', title: 'Default' },
        ],
      },
    });
    const res = await store.dispatch(
      endpoints.fetchTaskChainDetail.initiate({ chainId: 'chn_1' }, { subscribe: false, forceRefetch: true }),
    );
    assert.ok(!res?.error, `fetchTaskChainDetail failed: ${JSON.stringify(res?.error)}`);
    const tasks = res.data?.chain?.tasks;
    assert.equal(tasks.length, 3);
    assert.equal(tasks[0].requiresUserApproval, true);
    assert.equal(tasks[0].requires_user_approval, true);
    assert.equal(tasks[1].requiresUserApproval, true);
    assert.equal(tasks[1].requires_user_approval, true);
    assert.equal(tasks[2].requiresUserApproval, false);
    assert.equal(tasks[2].requires_user_approval, false);
  } finally {
    await lockVaultFully(store);
  }
});
