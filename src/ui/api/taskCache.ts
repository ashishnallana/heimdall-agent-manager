import { createSelector } from '@reduxjs/toolkit';
import { heimdallApi } from './heimdallApi';

function taskUpdatedAt(task: any): number {
  return Number(task?.updatedAtUnixMs || 0);
}

function taskLogEventKey(event: any): string {
  return String(event?.eventId || `${event?.kind || 'event'}-${event?.createdUnixMs || 0}-${event?.body || ''}`);
}

export function mergeTaskRecord(existing: any, incoming: any) {
  if (!existing) return incoming;
  if (!incoming) return existing;
  if (taskUpdatedAt(incoming) >= taskUpdatedAt(existing)) {
    return { ...existing, ...incoming };
  }
  return { ...incoming, ...existing };
}

export function upsertTaskRecord(tasksById: Record<string, any>, incoming: any) {
  const taskId = String(incoming?.taskId || '');
  if (!taskId) return;
  tasksById[taskId] = mergeTaskRecord(tasksById[taskId], incoming);
}

export function sortTaskIds(taskIds: string[], tasksById: Record<string, any>) {
  return [...new Set(taskIds.filter(Boolean))].sort((left, right) => taskUpdatedAt(tasksById[right]) - taskUpdatedAt(tasksById[left]));
}

export function upsertTaskInList(tasks: any[], incoming: any) {
  const taskId = String(incoming?.taskId || '');
  if (!taskId) return;
  const index = tasks.findIndex((task: any) => task?.taskId === taskId);
  if (index >= 0) {
    tasks[index] = mergeTaskRecord(tasks[index], incoming);
  } else {
    tasks.unshift(incoming);
  }
  tasks.sort((left: any, right: any) => taskUpdatedAt(right) - taskUpdatedAt(left));
}

export function upsertTaskLogEvent(events: any[], incoming: any) {
  const nextKey = taskLogEventKey(incoming);
  const index = events.findIndex((event: any) => taskLogEventKey(event) === nextKey);
  if (index >= 0) {
    events[index] = { ...events[index], ...incoming };
    return false;
  }
  events.push(incoming);
  events.sort((left: any, right: any) => Number(left?.createdUnixMs || 0) - Number(right?.createdUnixMs || 0));
  return true;
}

const selectApiQueries = (state: any) => state?.[heimdallApi.reducerPath]?.queries || {};

export const selectTaskCacheProjection = createSelector([selectApiQueries], (queries) => {
  const tasksById: Record<string, any> = {};
  const chainTaskIds: Record<string, string[]> = {};
  const taskLogsByTaskId: Record<string, any[]> = {};
  const taskLogCursorByTaskId: Record<string, number> = {};
  const taskLogHasMoreByTaskId: Record<string, boolean> = {};
  const taskLogTotalByTaskId: Record<string, number> = {};
  const taskLogLoadingByTaskId: Record<string, boolean> = {};
  const tasksLoadingByChainId: Record<string, boolean> = {};

  Object.values(queries as Record<string, any>).forEach((entry: any) => {
    if (!entry?.endpointName) return;
    switch (entry.endpointName) {
      case 'fetchChainTasks': {
        const chainId = String(entry?.originalArgs?.chainId || entry?.data?.chainId || '');
        const tasks = Array.isArray(entry?.data?.tasks) ? entry.data.tasks : [];
        if (chainId) {
          chainTaskIds[chainId] = sortTaskIds(tasks.map((task: any) => String(task?.taskId || '')).filter(Boolean), tasksById);
          if (entry?.status === 'pending') tasksLoadingByChainId[chainId] = true;
        }
        tasks.forEach((task: any) => upsertTaskRecord(tasksById, task));
        if (chainId) {
          chainTaskIds[chainId] = sortTaskIds(tasks.map((task: any) => String(task?.taskId || '')).filter(Boolean), tasksById);
        }
        break;
      }
      case 'fetchTask': {
        const task = entry?.data?.task;
        if (!task?.taskId) break;
        upsertTaskRecord(tasksById, task);
        const chainId = String(task?.chainId || '');
        if (chainId && chainTaskIds[chainId]?.length) {
          chainTaskIds[chainId] = sortTaskIds([...chainTaskIds[chainId], task.taskId], tasksById);
        }
        break;
      }
      case 'fetchTaskLog': {
        const taskId = String(entry?.originalArgs?.taskId || entry?.data?.taskId || '');
        if (!taskId) break;
        taskLogsByTaskId[taskId] = Array.isArray(entry?.data?.events) ? entry.data.events : [];
        taskLogCursorByTaskId[taskId] = Number(entry?.data?.nextCursor || 0);
        taskLogHasMoreByTaskId[taskId] = Boolean(entry?.data?.hasMore);
        taskLogTotalByTaskId[taskId] = Number(entry?.data?.total || 0);
        if (entry?.status === 'pending') taskLogLoadingByTaskId[taskId] = true;
        break;
      }
      case 'fetchTaskLogPage': {
        const taskId = String(entry?.originalArgs?.taskId || '');
        if (taskId && entry?.status === 'pending') taskLogLoadingByTaskId[taskId] = true;
        break;
      }
      default:
        break;
    }
  });

  Object.keys(chainTaskIds).forEach((chainId) => {
    chainTaskIds[chainId] = sortTaskIds(chainTaskIds[chainId], tasksById);
  });

  return {
    tasksById,
    chainTaskIds,
    taskLogsByTaskId,
    taskLogCursorByTaskId,
    taskLogHasMoreByTaskId,
    taskLogTotalByTaskId,
    taskLogLoadingByTaskId,
    tasksLoadingByChainId,
  };
});

export function selectCachedTaskById(state: any, taskId: string) {
  return taskId ? selectTaskCacheProjection(state).tasksById?.[taskId] || null : null;
}
