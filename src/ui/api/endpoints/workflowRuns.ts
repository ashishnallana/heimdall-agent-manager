import { heimdallApi } from '../heimdallApi';
import { ApiError, cookieJsonFetch } from '../cookieFetch';

export interface WorkflowStageTask {
  task_id: string;
  title: string;
  state: string;
  stage_index: number;
  attempt_no: number;
}

export interface WorkflowRunStage {
  key: string;
  title: string;
  kind: string;
  state: string;
  complete: boolean;
  failed: boolean;
  instance_count: number;
  tasks: WorkflowStageTask[];
}

export interface WorkflowRunView {
  run_id: string;
  chain_id: string;
  title: string;
  status: 'draft' | 'pending' | 'running' | 'succeeded' | 'failed' | 'cancelled';
  execution_no: number;
  current_execution_no: number;
  definition_ref: string;
  workflow_name: string;
  failure_detail: string;
  stages: WorkflowRunStage[];
}

export const workflowRunsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    fetchChainWorkflowRuns: build.query<{ runs: WorkflowRunView[]; work_revision: number }, { chainId: string }>({
      queryFn: async ({ chainId }) => {
        try {
          const data = await cookieJsonFetch(`/task-chains/${encodeURIComponent(chainId)}/workflow-runs`);
          return { data: { runs: Array.isArray(data?.runs) ? data.runs : [], work_revision: data?.work_revision ?? 0 } };
        } catch (error) {
          return { error: { status: error instanceof ApiError && error.status ? String(error.status) : 'CUSTOM_ERROR', error: error instanceof Error ? error.message : String(error) } };
        }
      },
      // Chain:<id> keeps chain-level invalidations (reconnect, chain edits) reaching it;
      // WorkflowRuns:<chain> and WorkflowRuns:<run> are what workflow events target.
      providesTags: (result, _error, { chainId }) => [
        { type: 'Chain', id: chainId },
        { type: 'WorkflowRuns', id: chainId },
        ...(result?.runs || []).map((run: any) => ({ type: 'WorkflowRuns' as const, id: String(run?.run_id || run?.workflow_run_id || '') })).filter((tag) => tag.id),
      ],
    }),
  }),
});

export const { useFetchChainWorkflowRunsQuery } = workflowRunsApi;
