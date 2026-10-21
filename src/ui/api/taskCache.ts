
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
