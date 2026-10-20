const DEFAULT_TIMEOUT_MS = 5000;

type RequestOptions = {
  method?: string;
  body?: unknown;
  headers?: Record<string, string>;
  timeoutMs?: number;
};

type SessionRequest = {
  daemonUrl: string;
  userId: string;
  clientInstanceId: string;
  clientToken: string;
};

type AgentRequest = {
  daemonUrl: string;
  clientInstanceId: string;
  clientToken: string;
  agentInstanceId: string;
};

type UserRpcRequest = {
  daemonUrl: string;
  clientInstanceId: string;
  clientToken: string;
};

export type ProjectAnchor = {
  type: string;
  value: string;
  note: string;
};

export type Project = {
  projectId: string;
  name: string;
  description: string;
  anchors: ProjectAnchor[];
  createdUnixMs: number;
  updatedUnixMs: number;
  order: number;
};

type TaskAgentRequest = {
  daemonUrl: string;
  agentToken: string;
};

async function requestJson(url: string, { method = 'GET', body, headers, timeoutMs = DEFAULT_TIMEOUT_MS }: RequestOptions = {}): Promise<any> {

  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      method,
      headers: { 
        'Content-Type': 'application/json',
        ...headers
      },
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal,
    });
    const data = await response.json().catch(() => null);
    if (!response.ok) {
      const details: string[] = [];
      if (data?.error) details.push(`error=${typeof data.error === 'string' ? data.error : (data.error.message || data.error.code || JSON.stringify(data.error))}`);
      if (Array.isArray(data?.blocking_dependents) && data.blocking_dependents.length) details.push(`blocking dependents: ${data.blocking_dependents.join(', ')}`);
      const suffix = details.length ? ` (${details.join('; ')})` : '';
      throw new Error(`${data?.message || data?.error?.message || `Daemon request failed with ${response.status}`}${suffix}`);
    }
    return data;
  } finally {
    window.clearTimeout(timeout);
  }
}

async function requestFormJson(url: string, { method = 'POST', body, headers, timeoutMs = DEFAULT_TIMEOUT_MS }: RequestOptions = {}): Promise<any> {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      method,
      headers: { ...headers },
      body: body as BodyInit,
      signal: controller.signal,
    });
    const data = await response.json().catch(() => null);
    if (!response.ok) {
      throw new Error(`${data?.message || data?.error?.message || `Daemon request failed with ${response.status}`}`);
    }
    return data;
  } finally {
    window.clearTimeout(timeout);
  }
}

function joinUrl(baseUrl: string, path: string) {
  return `${baseUrl.replace(/\/$/, '')}${path}`;
}

function sanitizeProjectId(projectId?: string): string {
  return projectId === 'default' ? '' : (projectId || '');
}

function bearerHeaders(clientToken?: string): Record<string, string> {
  const token = String(clientToken || '').trim();
  return token ? { 'Authorization': `Bearer ${token}` } : {};
}

export async function registerUserClient({ daemonUrl, userId, clientInstanceId, clientToken }: SessionRequest) {
  return requestJson(joinUrl(daemonUrl, '/user-client/register'), {
    method: 'POST',
    body: {
      user_id: userId,
      client_instance_id: clientInstanceId,
      client_token: clientToken || '',
    },
  });
}

export async function listAgentTemplates({ daemonUrl }: { daemonUrl: string }) {
  const data = await requestJson(joinUrl(daemonUrl, '/agents/templates'));
  return data.templates ?? [];
}

export async function showAgentTemplate({ daemonUrl, templateId }: { daemonUrl: string; templateId: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/templates/show'), {
    method: 'POST',
    body: { template_id: templateId },
  });
}

export async function listKnownAgentsCatalog({
  daemonUrl,
  projectId = '',
  includeIdentities = false,
  includeConversations = false,
  limit,
  offset,
  running,
}: {
  daemonUrl: string;
  projectId?: string;
  includeIdentities?: boolean;
  includeConversations?: boolean;
  limit?: number;
  offset?: number;
  running?: boolean;
}) {
  const params = new URLSearchParams();
  const sanitizedProjectId = sanitizeProjectId(projectId);
  if (sanitizedProjectId) params.set('project_id', sanitizedProjectId);
  if (includeIdentities) params.set('include_identities', 'true');
  if (includeConversations) params.set('include_conversations', 'true');
  if (limit !== undefined) params.set('limit', String(limit));
  if (offset !== undefined) params.set('offset', String(offset));
  if (running) params.set('running', 'true');
  const query = params.toString();
  const path = query ? `/agents?${query}` : '/agents';
  const data = await requestJson(joinUrl(daemonUrl, path));
  return {
    agents: data.agents ?? data.records ?? [],
    identities: data.identities ?? [],
    total: Number(data.total || 0),
    limit: Number(data.limit || 0),
    offset: Number(data.offset || 0),
    hasMore: Boolean(data.has_more || data.hasMore),
  };
}

export async function fetchAgentDefaults({ daemonUrl, clientToken }: { daemonUrl: string; clientToken: string }) {
  return requestJson(joinUrl(daemonUrl, `/agents/defaults?agent_token=${encodeURIComponent(clientToken)}`));
}

export async function setAgentDefault({ daemonUrl, clientToken, use, agentId }: { daemonUrl: string; clientToken: string; use: string; agentId: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/defaults'), {
    method: 'POST',
    body: { agent_token: clientToken, use, agent_id: agentId },
  });
}

export async function listAgentProviders({ daemonUrl }: { daemonUrl: string }) {
  const data = await requestJson(joinUrl(daemonUrl, '/agents/providers'));
  return data.providers ?? [];
}

export async function startAgent({ daemonUrl, agentId, agentInstanceId = '', provider, templateId, projectId, projectIdSet, alias, displayName, model }: { daemonUrl: string; agentId?: string; agentInstanceId?: string; provider?: string; templateId?: string; projectId?: string; projectIdSet?: boolean; alias?: string; displayName?: string; model?: string }) {
  const body: any = {
    template_id: templateId || '',
    project_id: sanitizeProjectId(projectId),
    alias: alias || displayName || '',
    display_name: displayName || alias || '',
    agent_instance_id: agentInstanceId || '',
    model: model || '',
    agent_id: agentId || '',
  };
  if (provider !== undefined) {
    body.agent = provider || '';
    body.provider_profile = provider || '';
  }
  if (model !== undefined) body.model = model || '';
  if (agentInstanceId) body.agent_instance_id = agentInstanceId;
  if (agentId) body.agent_id = agentId;
  // Explicit runtime restart project override (incl. clearing to none) so the
  // backend applies an empty project verbatim instead of preserving the stored one.
  if (projectIdSet) body.project_id_set = true;
  return requestJson(joinUrl(daemonUrl, '/agents/start'), {
    method: 'POST',
    body,
    timeoutMs: 10000,
  });
}

export async function showAgent({ daemonUrl, agentRecordId, agentInstanceId }: { daemonUrl: string; agentRecordId?: string; agentInstanceId?: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/show'), {
    method: 'POST',
    body: { agent_record_id: agentRecordId || '', agent_instance_id: agentInstanceId || '' },
  });
}

// UI-11: Settings → Bridges management. All routes are Hub /api/v1 (Bearer).
// Per arch doc §6A: list/detail/rename/revoke exist; enrollments create/list/
// revoke exist. Rotate-token is NOT yet served (documented gap).
export async function fetchBridgeDetail({ daemonUrl, clientToken, bridgeId, expand }: { daemonUrl: string; clientToken: string; bridgeId: string; expand?: string }) {
  const params = new URLSearchParams();
  if (expand) params.set('expand', expand);
  const suffix = params.toString() ? `?${params.toString()}` : '';
  return requestJson(joinUrl(daemonUrl, `/api/v1/bridges/${encodeURIComponent(bridgeId)}${suffix}`), {
    method: 'GET',
    headers: { Authorization: `Bearer ${clientToken}` },
  });
}

// The three bridge-enrollment helpers are DELETED (REQ-ENROLL-9): they wrapped
// POST/GET /api/v1/bridge-enrollments and DELETE /api/v1/bridge-enrollments/<id>,
// which minted, listed and revoked the one-time enrollment token. All three now 404.
// Enrollment is browser-approved and driven by the bridge, so there is nothing for a
// client to mint and no enrollment rows to list.

// Project bridge-paths (per-bridge override + advisory validation).
export async function putProjectBridgePath({ daemonUrl, clientToken, projectId, bridgeId, path }: { daemonUrl: string; clientToken: string; projectId: string; bridgeId: string; path: string }) {
  return requestJson(joinUrl(daemonUrl, `/api/v1/projects/${encodeURIComponent(projectId)}/bridge-paths/${encodeURIComponent(bridgeId)}`), {
    method: 'PUT',
    headers: { Authorization: `Bearer ${clientToken}` },
    body: { path },
  });
}

export async function deleteProjectBridgePath({ daemonUrl, clientToken, projectId, bridgeId }: { daemonUrl: string; clientToken: string; projectId: string; bridgeId: string }) {
  return requestJson(joinUrl(daemonUrl, `/api/v1/projects/${encodeURIComponent(projectId)}/bridge-paths/${encodeURIComponent(bridgeId)}`), {
    method: 'DELETE',
    headers: { Authorization: `Bearer ${clientToken}` },
  });
}

export async function validateProjectBridgePath({ daemonUrl, clientToken, projectId, bridgeId }: { daemonUrl: string; clientToken: string; projectId: string; bridgeId: string }) {
  return requestJson(joinUrl(daemonUrl, `/api/v1/projects/${encodeURIComponent(projectId)}/bridge-paths/${encodeURIComponent(bridgeId)}/validate`), {
    method: 'POST',
    headers: { Authorization: `Bearer ${clientToken}` },
  });
}

export async function stopAgent({ daemonUrl, agentInstanceId, timeInSec }: { daemonUrl: string; agentInstanceId: string; timeInSec?: number }) {
  const body: any = { agent_instance_id: agentInstanceId };
  if (timeInSec !== undefined) body.time_in_sec = timeInSec;
  return requestJson(joinUrl(daemonUrl, '/agents/stop'), {
    method: 'POST',
    body,
  });
}

// Daemon-authoritative conversation list for the sidebar: rows are returned
// most-recent-first with persisted titles and last_message_unix_ms. Used only
// on explicit triggers (open/create/send/refresh) — never passive events.
export async function listConversations({ daemonUrl, clientInstanceId, clientToken, limit, cursor }: UserRpcRequest & { limit?: number; cursor?: string }) {
  const data = await userRpcRequest({
    daemonUrl,
    clientInstanceId,
    clientToken,
    action: 'list_chats',
    body: { limit, cursor }
  });
  return { ...data, chats: data.chats ?? [] };
}

export async function fetchChat({ daemonUrl, clientToken, agentInstanceId, limit = 50, cursor = 0, chainId = '' }: Partial<AgentRequest> & { limit?: number; cursor?: number; chainId?: string }) {
  let path = `/chats/${encodeURIComponent(agentInstanceId || '')}/messages?limit=${limit}`;
  if (cursor > 0) {
    path += `&cursor=${cursor}`;
  }
  if (chainId) {
    path += `&chain_id=${encodeURIComponent(chainId)}`;
  }
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken || ''}` }
  });
}

export async function fetchChatMessage({ daemonUrl, clientToken, messageId }: { daemonUrl: string; clientToken: string; messageId: string }) {
  return requestJson(joinUrl(daemonUrl, `/chats/messages/${encodeURIComponent(messageId)}`), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken || ''}` }
  });
}

export async function sendToAgent({ daemonUrl, clientInstanceId, clientToken, agentInstanceId, body, interrupt, artifactIds }: AgentRequest & { body: string; interrupt?: boolean; artifactIds?: string[] }) {
  const attachments = (artifactIds || []).filter(Boolean);
  return requestJson(joinUrl(daemonUrl, '/user-rpc'), {
    method: 'POST',
    body: {
      action: 'send_to_agent',
      client_instance_id: clientInstanceId,
      client_token: clientToken,
      agent_instance_id: agentInstanceId,
      body,
      interrupt,
      // UI-5 upload-before-send: forward resolved attachment ids as artifact_ids.
      ...(attachments.length > 0 ? { artifact_ids: attachments } : {}),
    },
  });
}

export async function sendToCoordinator({ daemonUrl, clientInstanceId, clientToken, chainId, body, artifactIds }: UserRpcRequest & { chainId: string; body: string; artifactIds?: string[] }) {
  const attachments = (artifactIds || []).filter(Boolean);
  return requestJson(joinUrl(daemonUrl, '/chat/send-to-coordinator'), {
    method: 'POST',
    // UI-5 upload-before-send: forward resolved attachment ids as artifact_ids.
    body: { agent_token: clientToken, chain_id: chainId, body, client_instance_id: clientInstanceId, ...(attachments.length > 0 ? { artifact_ids: attachments } : {}) },
  });
}

export async function markChatRead({ daemonUrl, clientInstanceId, clientToken, agentInstanceId }: AgentRequest) {
  return requestJson(joinUrl(daemonUrl, '/user-rpc'), {
    method: 'POST',
    body: {
      action: 'mark_read',
      client_instance_id: clientInstanceId,
      client_token: clientToken,
      agent_instance_id: agentInstanceId,
    },
  });
}

export async function listTaskChains({ daemonUrl, clientToken, createdAfter, createdBefore, limit = 20, offset = 0, status }: Omit<UserRpcRequest, 'clientInstanceId'> & { createdAfter?: number; createdBefore?: number; limit?: number; offset?: number; status?: string }) {
  let path = `/task-chains?limit=${limit}&offset=${offset}`;
  if (createdAfter && createdAfter > 0) path += `&created_after=${createdAfter}`;
  if (createdBefore && createdBefore > 0) path += `&created_before=${createdBefore}`;
  if (status) path += `&status=${encodeURIComponent(status)}`;
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` }
  });
}

export async function fetchTaskChain({ daemonUrl, clientToken, chainId }: Omit<UserRpcRequest, 'clientInstanceId'> & { chainId: string }) {
  const path = `/task-chains/${encodeURIComponent(chainId)}`;
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` }
  });
}

export async function focusTaskChain({ daemonUrl, clientToken, chainId }: Omit<UserRpcRequest, 'clientInstanceId'> & { chainId: string }) {
  return requestJson(joinUrl(daemonUrl, `/task-chains/${encodeURIComponent(chainId)}/focus`), {
    method: 'POST',
    body: { agent_token: clientToken },
  });
}

export async function fetchWorkspace({ daemonUrl, clientToken, chainId }: Omit<UserRpcRequest, 'clientInstanceId'> & { chainId: string }) {
  return requestJson(joinUrl(daemonUrl, `/chains/${encodeURIComponent(chainId)}/workspace?agent_token=${encodeURIComponent(clientToken)}`));
}

export async function previewWorkspaceMerge({ daemonUrl, clientToken, chainId }: Omit<UserRpcRequest, 'clientInstanceId'> & { chainId: string }) {
  return requestJson(joinUrl(daemonUrl, `/chains/${encodeURIComponent(chainId)}/workspace/merge-preview?agent_token=${encodeURIComponent(clientToken)}`));
}

export async function fetchWorkspaceDiff({ daemonUrl, clientToken, chainId, file = '' }: Omit<UserRpcRequest, 'clientInstanceId'> & { chainId: string; file?: string }) {
  let path = `/chains/${encodeURIComponent(chainId)}/workspace/diff?agent_token=${encodeURIComponent(clientToken)}`;
  if (file) path += `&file=${encodeURIComponent(file)}`;
  return requestJson(joinUrl(daemonUrl, path));
}

export async function listChainTasks({ daemonUrl, clientToken, chainId, limit = 20, offset = 0 }: Omit<UserRpcRequest, 'clientInstanceId'> & { chainId: string; limit?: number; offset?: number }) {
  const params = new URLSearchParams({ limit: String(limit), offset: String(offset) });
  const path = `/task-chains/${encodeURIComponent(chainId)}/tasks?${params.toString()}`;
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` }
  });
}

export async function fetchTask({ daemonUrl, clientToken, taskId }: Omit<UserRpcRequest, 'clientInstanceId'> & { taskId: string }) {
  const path = `/tasks/${encodeURIComponent(taskId)}`;
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` }
  });
}

export async function fetchTaskComments({ daemonUrl, clientToken, taskId, unresolved = false, limit = 20, offset = 0 }: Omit<UserRpcRequest, 'clientInstanceId'> & { taskId: string; unresolved?: boolean; limit?: number; offset?: number }) {
  const params = new URLSearchParams({ unresolved: String(unresolved), limit: String(limit), offset: String(offset) });
  const path = `/tasks/${encodeURIComponent(taskId)}/comments?${params.toString()}`;
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` }
  });
}

export async function fetchTaskComment({ daemonUrl, clientToken, taskId, commentId }: Omit<UserRpcRequest, 'clientInstanceId'> & { taskId: string; commentId: string }) {
  const path = `/tasks/${encodeURIComponent(taskId)}/comments/${encodeURIComponent(commentId)}`;
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` }
  });
}

function extensionFromNameOrMime(name = '', mime = ''): string {
  const cleanName = String(name || '').toLowerCase();
  const dot = cleanName.lastIndexOf('.');
  if (dot >= 0 && dot < cleanName.length - 1) return cleanName.slice(dot + 1).replace(/[^a-z0-9]+/g, '').slice(0, 16);
  const normalized = String(mime || '').toLowerCase();
  if (normalized === 'image/png') return 'png';
  if (normalized === 'image/jpeg') return 'jpg';
  if (normalized === 'image/gif') return 'gif';
  if (normalized === 'image/webp') return 'webp';
  if (normalized === 'text/markdown') return 'md';
  if (normalized === 'text/csv') return 'csv';
  if (normalized === 'text/html') return 'html';
  if (normalized === 'application/json') return 'json';
  if (normalized.startsWith('text/')) return 'txt';
  return '';
}

function blobToBase64(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error || new Error('Unable to read selected file'));
    reader.onload = () => {
      const value = String(reader.result || '');
      const comma = value.indexOf(',');
      resolve(comma >= 0 ? value.slice(comma + 1) : value);
    };
    reader.readAsDataURL(blob);
  });
}

export async function createArtifact({
  daemonUrl,
  clientToken,
  file,
  name,
  kind = '',
  mime = '',
  ext = '',
  projectId = '',
  project_id = '',
  agentId = '',
  agent_id = '',
  agentInstanceId = '',
  agent_instance_id = '',
  chainId = '',
  chain_id = '',
  description = '',
  originKind = '',
  originRef = '',
  contentBase64 = '',
}: {
  daemonUrl: string;
  clientToken: string;
  file?: File | Blob | null;
  name: string;
  kind?: string;
  mime?: string;
  ext?: string;
  projectId?: string;
  project_id?: string;
  agentId?: string;
  agent_id?: string;
  agentInstanceId?: string;
  agent_instance_id?: string;
  chainId?: string;
  chain_id?: string;
  description?: string;
  originKind?: string;
  originRef?: string;
  contentBase64?: string;
}) {
  // Use the JSON/base64 artifact API for browser-selected files. Chromium/Electron
  // may stream multipart FormData with Transfer-Encoding: chunked; the lightweight
  // Hub HTTP server is Content-Length based, so that path can fail at the network
  // layer with an opaque "Load failed" after file selection. JSON keeps uploads
  // fixed-length and works consistently in the browser, dev proxy, and Electron
  // fetch bridge while preserving the same artifact endpoint contract.
  const uploadBase64 = file ? await blobToBase64(file) : contentBase64;
  const resolvedProjectId = sanitizeProjectId(project_id || projectId);
  const resolvedAgentId = agent_id || agentId;
  const resolvedAgentInstanceId = agent_instance_id || agentInstanceId;
  const resolvedChainId = chain_id || chainId;

  const body: any = {
    name,
    kind,
    project_id: resolvedProjectId,
    description,
    content_base64: uploadBase64,
  };
  if (resolvedAgentId) body.agent_id = resolvedAgentId;
  if (resolvedAgentInstanceId) body.agent_instance_id = resolvedAgentInstanceId;
  if (resolvedChainId) body.chain_id = resolvedChainId;

  const finalMime = mime || (file ? String((file as any).type || '') : '');
  const finalExt = ext || extensionFromNameOrMime(name, finalMime);
  if (finalMime) body.mime = finalMime;
  if (finalMime) body.content_type = finalMime;
  if (finalExt) body.ext = finalExt;
  if (originKind) body.origin_kind = originKind;
  if (originRef) body.origin_ref = originRef;
  return requestJson(joinUrl(daemonUrl, '/api/v1/artifacts'), {
    method: 'POST',
    headers: bearerHeaders(clientToken),
    body,
    timeoutMs: 120000,
  });
}

export async function fetchArtifactMeta({ daemonUrl, clientToken, artifactId }: { daemonUrl: string; clientToken: string; artifactId: string }) {
  return requestJson(joinUrl(daemonUrl, `/api/v1/artifacts/${encodeURIComponent(artifactId)}`), {
    method: 'GET',
    headers: bearerHeaders(clientToken),
  });
}

export async function fetchArtifactVersions({ daemonUrl, clientToken, artifactId }: { daemonUrl: string; clientToken: string; artifactId: string }) {
  return requestJson(joinUrl(daemonUrl, `/api/v1/artifacts/${encodeURIComponent(artifactId)}/versions`), {
    method: 'GET',
    headers: bearerHeaders(clientToken),
  });
}

export function artifactContentUrl({ daemonUrl, artifactId, version }: { daemonUrl: string; clientToken?: string; artifactId: string; version?: number | null }) {
  const params = new URLSearchParams();
  if (version != null && Number.isFinite(version)) params.set('version', String(version));
  const suffix = params.toString() ? `?${params.toString()}` : '';
  return joinUrl(daemonUrl, `/api/v1/artifacts/${encodeURIComponent(artifactId)}/content${suffix}`);
}

export async function listArtifacts({
  daemonUrl,
  clientToken,
  projectId = '',
  creatorId = '',
  originRef = '',
  includeDeleted = false,
  limit = 100,
  offset = 0,
  agent_instance_id = '',
  agentInstanceId = '',
  agent_id = '',
  agentId = '',
  chain_id = '',
  chainId = '',
  task_id = '',
  taskId = '',
  kind = '',
  since = '',
  until = '',
  sort = '',
  order = '',
  cursor = '',
}: {
  daemonUrl: string;
  clientToken: string;
  projectId?: string;
  creatorId?: string;
  originRef?: string;
  includeDeleted?: boolean;
  limit?: number;
  offset?: number;
  agent_instance_id?: string;
  agentInstanceId?: string;
  agent_id?: string;
  agentId?: string;
  chain_id?: string;
  chainId?: string;
  task_id?: string;
  taskId?: string;
  kind?: string;
  since?: string;
  until?: string;
  sort?: string;
  order?: string;
  cursor?: string;
}) {
  const params = new URLSearchParams({ limit: String(limit), offset: String(offset) });
  const sanitizedProjectId = sanitizeProjectId(projectId);
  if (sanitizedProjectId) params.set('project_id', sanitizedProjectId);
  if (creatorId) params.set('creator_id', creatorId);
  if (originRef) params.set('origin_ref', originRef);
  if (includeDeleted) params.set('include_deleted', 'true');
  const resolvedAgentInstanceId = agent_instance_id || agentInstanceId;
  if (resolvedAgentInstanceId) params.set('agent_instance_id', resolvedAgentInstanceId);
  const resolvedAgentId = agent_id || agentId;
  if (resolvedAgentId) params.set('agent_id', resolvedAgentId);
  const resolvedChainId = chain_id || chainId;
  if (resolvedChainId) params.set('chain_id', resolvedChainId);
  const resolvedTaskId = task_id || taskId;
  if (resolvedTaskId) params.set('task_id', resolvedTaskId);
  if (kind) params.set('kind', kind);
  if (since) params.set('since', since);
  if (until) params.set('until', until);
  if (sort) params.set('sort', sort);
  if (order) params.set('order', order);
  if (cursor) params.set('cursor', cursor);
  return requestJson(joinUrl(daemonUrl, `/api/v1/artifacts?${params.toString()}`), {
    method: 'GET',
    headers: bearerHeaders(clientToken),
  });
}

export async function updateArtifact({ daemonUrl, clientToken, artifactId, name, kind, projectId, description, originKind, originRef, contentBase64, changeReason }: { daemonUrl: string; clientToken: string; artifactId: string; name?: string; kind?: string; projectId?: string; description?: string; originKind?: string; originRef?: string; contentBase64?: string; changeReason?: string }) {
  // UI-10: PATCH /api/v1/artifacts/{id} is the Hub rewrite route (Bearer auth).
  // The Hub patch_artifact handler only persists `name` + `description`
  // (metadata rename); kind/origin/content/versioning are NOT supported by the
  // /api/v1 PATCH surface and must not be sent as if honored. Legacy
  // POST /artifacts/update is unserved by the Hub.
  const patchBody: any = {};
  if (name !== undefined) patchBody.name = name;
  if (description !== undefined) patchBody.description = description;
  return requestJson(joinUrl(daemonUrl, `/api/v1/artifacts/${encodeURIComponent(artifactId)}`), {
    method: 'PATCH',
    headers: bearerHeaders(clientToken),
    body: patchBody,
  });
}

export async function rollbackArtifact({ daemonUrl, clientToken, artifactId, versionNo, changeReason = '' }: { daemonUrl: string; clientToken: string; artifactId: string; versionNo: number; changeReason?: string }) {
  return requestJson(joinUrl(daemonUrl, '/artifacts/rollback'), {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${clientToken}` },
    body: {
      artifact_id: artifactId,
      version_no: versionNo,
      change_reason: changeReason,
    },
  });
}

export async function fetchArtifactAnnotations({ daemonUrl, clientToken, artifactId, versionNo }: { daemonUrl: string; clientToken: string; artifactId: string; versionNo?: number | null }) {
  const params = new URLSearchParams();
  if (versionNo != null && Number.isFinite(versionNo)) params.set('version', String(versionNo));
  const suffix = params.toString() ? `?${params.toString()}` : '';
  return requestJson(joinUrl(daemonUrl, `/artifacts/${encodeURIComponent(artifactId)}/annotations${suffix}`), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` },
  });
}

export async function createArtifactAnnotation({ daemonUrl, clientToken, artifactId, versionNo, contextType, contextJson, comment }: { daemonUrl: string; clientToken: string; artifactId: string; versionNo?: number | null; contextType: string; contextJson: unknown; comment: string }) {
  const body: any = {
    artifact_id: artifactId,
    context_type: contextType,
    context_json: contextJson,
    comment,
  };
  if (versionNo != null && Number.isFinite(versionNo)) body.version_no = versionNo;
  return requestJson(joinUrl(daemonUrl, '/artifacts/annotations/create'), {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${clientToken}` },
    body,
  });
}

export async function updateArtifactAnnotation({ daemonUrl, clientToken, annotationId, comment }: { daemonUrl: string; clientToken: string; annotationId: string; comment: string }) {
  return requestJson(joinUrl(daemonUrl, '/artifacts/annotations/update'), {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${clientToken}` },
    body: { annotation_id: annotationId, comment },
  });
}

export async function deleteArtifactAnnotation({ daemonUrl, clientToken, annotationId }: { daemonUrl: string; clientToken: string; annotationId: string }) {
  return requestJson(joinUrl(daemonUrl, '/artifacts/annotations/delete'), {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${clientToken}` },
    body: { annotation_id: annotationId },
  });
}

export async function deleteArtifact({ daemonUrl, clientToken, artifactId }: { daemonUrl: string; clientToken: string; artifactId: string }) {
  // UI-10: DELETE /api/v1/artifacts/{id} is the Hub rewrite route (Bearer auth,
  // returns 204 No Content). Legacy POST /artifacts/delete is unserved by the Hub.
  return requestJson(joinUrl(daemonUrl, `/api/v1/artifacts/${encodeURIComponent(artifactId)}`), {
    method: 'DELETE',
    headers: bearerHeaders(clientToken),
  });
}

export async function fetchTaskLog({ daemonUrl, clientInstanceId, clientToken, taskId, limit = 50, cursor = 0 }: UserRpcRequest & { taskId: string; limit?: number; cursor?: number }) {
  return requestJson(joinUrl(daemonUrl, '/user-rpc'), {
    method: 'POST',
    body: {
      action: 'task_log',
      client_instance_id: clientInstanceId,
      client_token: clientToken,
      task_id: taskId,
      limit,
      cursor,
    },
  });
}

function taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action, agentPath, body }: any) {
  if (agentToken) {
    return requestJson(joinUrl(daemonUrl, agentPath), { method: 'POST', body: { agent_token: agentToken, ...body } });
  }
  return requestJson(joinUrl(daemonUrl, '/user-rpc'), { method: 'POST', body: { action, client_instance_id: clientInstanceId, client_token: clientToken, ...body } });
}

export async function createTask({ daemonUrl, agentToken, clientInstanceId, clientToken, ...task }: Partial<TaskAgentRequest & UserRpcRequest> & Record<string, any>) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_create', agentPath: '/tasks/create', body: task });
}

export async function createTaskChain({ daemonUrl, agentToken, clientInstanceId, clientToken, ...chain }: Partial<TaskAgentRequest & UserRpcRequest> & Record<string, any>) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_chain_create', agentPath: '/task-chains/create', body: chain });
}

export async function updateTask({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, title, description, acceptanceCriteria, dependsOn }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; title?: string; description?: string; acceptanceCriteria?: string; dependsOn?: string }) {
  const body: any = { task_id: taskId, chain_id: chainId || '' };
  if (title !== undefined) body.title = title;
  if (description !== undefined) body.description = description;
  if (acceptanceCriteria !== undefined) body.acceptance_criteria = acceptanceCriteria;
  if (dependsOn !== undefined) body.depends_on = dependsOn;
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_update', agentPath: '/tasks/update', body });
}

export async function deleteTask({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_delete', agentPath: '/tasks/delete', body: { task_id: taskId, chain_id: chainId || '' } });
}

export async function assignTask({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, agentInstanceId }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; agentInstanceId: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_assign', agentPath: '/tasks/assign', body: { task_id: taskId, chain_id: chainId || '', agent_instance_id: agentInstanceId } });
}

export async function addTaskParticipant({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, agentInstanceId, role }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; agentInstanceId: string; role: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_participant', agentPath: '/tasks/participant', body: { task_id: taskId, chain_id: chainId || '', agent_instance_id: agentInstanceId, role } });
}

export async function removeTaskParticipant({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, agentInstanceId, role }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; agentInstanceId: string; role: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_participant_remove', agentPath: '/tasks/participant/remove', body: { task_id: taskId, chain_id: chainId || '', agent_instance_id: agentInstanceId, role } });
}

export async function resolveTaskComment({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, commentId }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; commentId: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_comment_resolve', agentPath: '/tasks/comment-resolve', body: { task_id: taskId, chain_id: chainId || '', comment_id: commentId } });
}

export async function updateTaskChain({ daemonUrl, agentToken, clientInstanceId, clientToken, chainId, title, description, coordinatorAgentInstanceId, defaultReviewerAgentInstanceId, finalSummary }: Partial<TaskAgentRequest & UserRpcRequest> & { chainId: string; title?: string; description?: string; coordinatorAgentInstanceId?: string; defaultReviewerAgentInstanceId?: string; finalSummary?: string }) {
  const body: any = { chain_id: chainId };
  if (title !== undefined) body.title = title;
  if (description !== undefined) body.description = description;
  if (coordinatorAgentInstanceId !== undefined) body.coordinator_agent_instance_id = coordinatorAgentInstanceId;
  if (defaultReviewerAgentInstanceId !== undefined) body.default_reviewer_agent_instance_id = defaultReviewerAgentInstanceId;
  if (finalSummary !== undefined) body.final_summary = finalSummary;
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_chain_update', agentPath: '/task-chains/update', body });
}

export async function updateTaskChainStatus({ daemonUrl, agentToken, clientInstanceId, clientToken, chainId, status, finalSummary }: Partial<TaskAgentRequest & UserRpcRequest> & { chainId: string; status: string; finalSummary?: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_chain_status', agentPath: '/task-chains/status', body: { chain_id: chainId, status, final_summary: finalSummary || '' } });
}

function userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action, body = {} }: UserRpcRequest & { action: string; body?: Record<string, any> }) {
  return requestJson(joinUrl(daemonUrl, '/user-rpc'), {
    method: 'POST',
    body: { action, client_instance_id: clientInstanceId, client_token: clientToken, ...body },
  });
}

export function normalizeProject(project: any): Project {
  return {
    projectId: project.project_id || '',
    name: project.name || '',
    description: project.description || '',
    anchors: (project.anchors ?? []).map((anchor: any) => ({
      type: anchor.type || '',
      value: anchor.value || '',
      note: anchor.note || '',
    })),
    createdUnixMs: Number(project.created_unix_ms || 0),
    updatedUnixMs: Number(project.updated_unix_ms || 0),
    order: Number(project.order || 0),
  };
}

export async function reorderAgents({ daemonUrl, clientInstanceId, clientToken, agentIds }: UserRpcRequest & { agentIds: string[] }) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'agent_reorder', body: { agent_ids: agentIds } });
}

export async function fetchPreferences({ daemonUrl, clientToken }: { daemonUrl: string; clientToken: string }) {
  return requestJson(joinUrl(daemonUrl, '/preferences'), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken || ''}` }
  });
}

export async function savePreference({ daemonUrl, clientToken, key, value, interrupt }: { daemonUrl: string; clientToken: string; key: string; value: string; interrupt: boolean }) {
  return requestJson(joinUrl(daemonUrl, '/preferences'), {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${clientToken || ''}` },
    body: { key, value, interrupt }
  });
}

export async function triggerMemoryAudit({
  daemonUrl,
  clientToken,
  timeRange,
  targetChains,
  auditorInstructions,
}: {
  daemonUrl: string;
  clientToken: string;
  timeRange?: string;
  targetChains?: string[];
  auditorInstructions?: string;
}) {
  const path = '/task-chains/audit';
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${clientToken}` },
    body: {
      time_range: timeRange,
      target_chains: targetChains,
      auditor_instructions: auditorInstructions,
    }
  });
}
