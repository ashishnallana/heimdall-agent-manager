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

export async function saveAgentTemplate({ daemonUrl, template }: { daemonUrl: string; template: any }) {
  return requestJson(joinUrl(daemonUrl, template?.update ? '/agents/templates/update' : '/agents/templates/create'), {
    method: 'POST',
    body: template || {},
  });
}

export async function showAgentTemplate({ daemonUrl, templateId }: { daemonUrl: string; templateId: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/templates/show'), {
    method: 'POST',
    body: { template_id: templateId },
  });
}

export async function archiveAgentTemplate({ daemonUrl, templateId }: { daemonUrl: string; templateId: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/templates/archive'), {
    method: 'POST',
    body: { template_id: templateId },
  });
}

export async function listKnownAgents({ daemonUrl, projectId = '' }: { daemonUrl: string; projectId?: string }) {
  const data = await listKnownAgentsCatalog({ daemonUrl, projectId });
  return data.agents;
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

export async function listKnownAgentsPage({ daemonUrl, projectId = '', limit = 20, offset = 0 }: { daemonUrl: string; projectId?: string; limit?: number; offset?: number }) {
  const data = await listKnownAgentsCatalog({ daemonUrl, projectId, limit, offset });
  return {
    agents: data.agents,
    limit: data.limit,
    offset: data.offset,
    nextOffset: data.offset + data.agents.length,
    hasMore: data.hasMore,
    total: data.total,
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

// UI-8: Add agent to chain. Creates a new AgentInstance bound to an EXISTING
// chain_id via POST /api/v1/agent-instances (the rewrite API), as documented in
// the architecture doc and confirmed ready in the gap analysis. This never
// attaches an unrelated live instance from another chain — it hydrates a fresh
// instance into the current chain and creates its 1:1 conversation.
export async function createAgentInstanceInChain({ daemonUrl, clientToken, agentId, chainId, bridgeId, providerProfile, model, projectId, displayName, templateId }: { daemonUrl: string; clientToken: string; agentId: string; chainId: string; bridgeId?: string; providerProfile?: string; model?: string; projectId?: string; displayName?: string; templateId?: string }) {
  if (!agentId || !chainId) throw new Error('agentId and chainId are required to add an agent to a chain');
  return requestJson(joinUrl(daemonUrl, '/api/v1/agent-instances'), {
    method: 'POST',
    headers: { Authorization: `Bearer ${clientToken}` },
    body: {
      agent_id: agentId,
      chain_id: chainId,
      // The hub's instance_input_from_body honors bridge_id on create, so the
      // popup's chosen bridge is respected (falls back to bridge default when omitted).
      ...(bridgeId ? { bridge_id: bridgeId } : {}),
      ...(providerProfile ? { provider_profile: providerProfile } : {}),
      ...(model ? { model: model } : {}),
      ...(projectId ? { project_id: projectId } : {}),
      ...(displayName ? { display_name: displayName } : {}),
      ...(templateId ? { template_id: templateId } : {}),
    },
    timeoutMs: 10000,
  });
}

export async function showAgent({ daemonUrl, agentRecordId, agentInstanceId }: { daemonUrl: string; agentRecordId?: string; agentInstanceId?: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/show'), {
    method: 'POST',
    body: { agent_record_id: agentRecordId || '', agent_instance_id: agentInstanceId || '' },
  });
}

// UI-9: agent bridge-support config (which bridges this agent may run on).
// Rewrite /api/v1 routes with Bearer clientToken (see gap analysis lines 59-62).
export type AgentBridgeSupportEntry = {
  bridgeId: string;
  enabled: boolean;
  providerProfile?: string;
  model?: string;
  priority?: number;
  maxInstances?: number;
};

export async function listAgentBridgeSupport({ daemonUrl, clientToken, agentId }: { daemonUrl: string; clientToken: string; agentId: string }) {
  return requestJson(joinUrl(daemonUrl, `/api/v1/agents/${encodeURIComponent(agentId)}/bridge-support`), {
    method: 'GET',
    headers: { Authorization: `Bearer ${clientToken}` },
  });
}

export async function patchAgentBridgeSupport({ daemonUrl, clientToken, agentId, bridgeId, enabled, providerProfile, model, priority, maxInstances }: { daemonUrl: string; clientToken: string; agentId: string; bridgeId: string; enabled?: boolean; providerProfile?: string; model?: string; priority?: number; maxInstances?: number }) {
  return requestJson(joinUrl(daemonUrl, `/api/v1/agents/${encodeURIComponent(agentId)}/bridge-support/${encodeURIComponent(bridgeId)}`), {
    method: 'PATCH',
    headers: { Authorization: `Bearer ${clientToken}` },
    body: {
      ...(enabled !== undefined ? { enabled } : {}),
      ...(providerProfile !== undefined ? { provider_profile: providerProfile } : {}),
      ...(model !== undefined ? { model: model } : {}),
      ...(priority !== undefined ? { priority } : {}),
      ...(maxInstances !== undefined ? { max_instances: maxInstances } : {}),
    },
  });
}

// UI-9: Bridges list (all known bridges the user owns / can use).
export async function listBridges({ daemonUrl, clientToken }: { daemonUrl: string; clientToken: string }) {
  return requestJson(joinUrl(daemonUrl, '/api/v1/bridges'), {
    method: 'GET',
    headers: { Authorization: `Bearer ${clientToken}` },
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

export async function renameBridge({ daemonUrl, clientToken, bridgeId, label }: { daemonUrl: string; clientToken: string; bridgeId: string; label: string }) {
  return requestJson(joinUrl(daemonUrl, `/api/v1/bridges/${encodeURIComponent(bridgeId)}`), {
    method: 'PATCH',
    headers: { Authorization: `Bearer ${clientToken}` },
    body: { label },
  });
}

// Revoke = "remove": invalidates token, disconnects live WS, marks revoked.
export async function revokeBridge({ daemonUrl, clientToken, bridgeId }: { daemonUrl: string; clientToken: string; bridgeId: string }) {
  return requestJson(joinUrl(daemonUrl, `/api/v1/bridges/${encodeURIComponent(bridgeId)}/revoke`), {
    method: 'POST',
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

export async function createAgent({ daemonUrl, agentId, agentInstanceId, displayName, providerProfile, templateId, projectId, model, start }: { daemonUrl: string; agentId?: string; agentInstanceId?: string; displayName?: string; providerProfile?: string; templateId?: string; projectId?: string; model?: string; start?: boolean }) {
  return requestJson(joinUrl(daemonUrl, '/agents/create'), {
    method: 'POST',
    body: {
      agent_id: agentId || '',
      agent_instance_id: agentInstanceId || '',
      display_name: displayName || '',
      provider_profile: providerProfile || '',
      template_id: templateId || '',
      project_id: sanitizeProjectId(projectId),
      model: model || 'normal',
      start: Boolean(start),
    },
  });
}

export async function updateAgent({ daemonUrl, agentRecordId, agentInstanceId, displayName, templateId, providerProfile, projectId, runDir, model, updateAgentIdDefaults }: { daemonUrl: string; agentRecordId?: string; agentInstanceId?: string; displayName?: string; templateId?: string; providerProfile?: string; projectId?: string; runDir?: string; model?: string; updateAgentIdDefaults?: boolean }) {
  const body: any = { agent_record_id: agentRecordId || '', agent_instance_id: agentInstanceId || '' };
  if (displayName !== undefined) body.display_name = displayName;
  if (templateId !== undefined) body.template_id = templateId;
  if (providerProfile !== undefined) body.provider_profile = providerProfile;
  if (projectId !== undefined) body.project_id = sanitizeProjectId(projectId);
  if (runDir !== undefined) body.run_dir = runDir;
  if (model !== undefined) body.model = model;
  if (updateAgentIdDefaults) body.update_agent_id_defaults = true;
  return requestJson(joinUrl(daemonUrl, '/agents/update'), {
    method: 'POST',
    body,
  });
}

export async function archiveAgent({ daemonUrl, agentRecordId, agentInstanceId }: { daemonUrl: string; agentRecordId?: string; agentInstanceId?: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/archive'), {
    method: 'POST',
    body: { agent_record_id: agentRecordId || '', agent_instance_id: agentInstanceId || '' },
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

export async function associateAgentWithProject({ daemonUrl, agentRecordId, agentInstanceId, projectId }: { daemonUrl: string; agentRecordId?: string; agentInstanceId?: string; projectId: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/associate'), {
    method: 'POST',
    body: { agent_record_id: agentRecordId || '', agent_instance_id: agentInstanceId || '', project_id: sanitizeProjectId(projectId) },
  });
}

export async function disassociateAgentFromProject({ daemonUrl, agentRecordId, agentInstanceId }: { daemonUrl: string; agentRecordId?: string; agentInstanceId?: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/disassociate'), {
    method: 'POST',
    body: { agent_record_id: agentRecordId || '', agent_instance_id: agentInstanceId || '' },
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

export async function deleteAgentId({ daemonUrl, clientToken, agentId }: { daemonUrl: string; clientToken: string; agentId: string }) {
  return requestJson(joinUrl(daemonUrl, '/agent-ids/delete'), {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${clientToken}` },
    body: JSON.stringify({ agent_id: agentId }),
  });
}

export async function listTasks({ daemonUrl, clientToken, chainId = '', createdAfter = 0, createdBefore = 0, limit = 50, offset = 0 }: Omit<UserRpcRequest, 'clientInstanceId'> & { chainId?: string; createdAfter?: number; createdBefore?: number; limit?: number; offset?: number }) {
  let path = `/tasks?limit=${limit}&offset=${offset}`;
  if (chainId) path += `&chain_id=${encodeURIComponent(chainId)}`;
  if (createdAfter > 0) path += `&created_after=${createdAfter}`;
  if (createdBefore > 0) path += `&created_before=${createdBefore}`;

  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` }
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

export async function addTaskComment({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, body, artifactContentBase64, artifactName, artifactKind }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; body: string; artifactContentBase64?: string; artifactName?: string; artifactKind?: string }) {
  const requestBody: any = { task_id: taskId, chain_id: chainId || '', body };
  if (artifactContentBase64 !== undefined) requestBody.artifact_content_base64 = artifactContentBase64;
  if (artifactName !== undefined) requestBody.artifact_name = artifactName;
  if (artifactKind !== undefined) requestBody.artifact_kind = artifactKind;
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_comment', agentPath: '/tasks/comment', body: requestBody });
}

export async function updateTaskStatus({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, status, body }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; status: string; body: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_status', agentPath: '/tasks/status', body: { task_id: taskId, chain_id: chainId || '', status, body } });
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

export async function voteTask({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, approved, comment }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; approved: boolean; comment: string }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_review_vote', agentPath: '/tasks/vote', body: { task_id: taskId, chain_id: chainId || '', result: approved ? 'lgtm' : 'ngtm', comment } });
}

export async function nudgeTask({ daemonUrl, agentToken, clientInstanceId, clientToken, taskId, chainId, body, interrupt }: Partial<TaskAgentRequest & UserRpcRequest> & { taskId: string; chainId?: string; body: string; interrupt?: boolean }) {
  return taskMutationRequest({ daemonUrl, agentToken, clientInstanceId, clientToken, action: 'task_nudge', agentPath: '/tasks/nudge', body: { task_id: taskId, chain_id: chainId || '', body, interrupt: Boolean(interrupt) } });
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

function normalizeMemoryTargetValue(value: any): string {
  if (value == null) return '';
  return String(value).trim();
}

function normalizeMemoryMutationBody(body: Record<string, any>) {
  const normalized = { ...body };
  if (normalized.memory_id == null && normalized.memoryId != null) normalized.memory_id = normalized.memoryId;
  if (normalized.expected_version == null && normalized.expectedVersion != null) normalized.expected_version = normalized.expectedVersion;
  if (normalized.target_agent_id == null && normalized.targetAgentId != null) normalized.target_agent_id = normalizeMemoryTargetValue(normalized.targetAgentId);
  if (normalized.target_project_id == null && normalized.targetProjectId != null) normalized.target_project_id = normalizeMemoryTargetValue(normalized.targetProjectId);
  if (normalized.target_template_id == null && normalized.targetTemplateId != null) normalized.target_template_id = normalizeMemoryTargetValue(normalized.targetTemplateId);
  if (normalized.target_bridge_id == null && normalized.targetBridgeId != null) normalized.target_bridge_id = normalizeMemoryTargetValue(normalized.targetBridgeId);
  if (normalized.source_task_id == null && normalized.sourceTaskId != null) normalized.source_task_id = normalized.sourceTaskId;
  if (normalized.metadata_json == null && normalized.metadataJson != null) normalized.metadata_json = normalized.metadataJson;
  return normalized;
}

export async function listMemory({ daemonUrl, clientInstanceId, clientToken, type, status, targetProjectId, targetBridgeId, includeAllStatuses = true }: UserRpcRequest & { type?: string; status?: string; targetProjectId?: string; targetBridgeId?: string; includeAllStatuses?: boolean }) {
  return userRpcRequest({
    daemonUrl,
    clientInstanceId,
    clientToken,
    action: 'memory_list',
    body: {
      type: type || '',
      status: status || '',
      target_project_id: normalizeMemoryTargetValue(targetProjectId),
      target_bridge_id: normalizeMemoryTargetValue(targetBridgeId),
      include_all_statuses: includeAllStatuses,
    }
  });
}

export async function listApplicableMemory({ daemonUrl, clientInstanceId, clientToken, targetAgentId, targetProjectId, targetBridgeId }: UserRpcRequest & { targetAgentId?: string; targetProjectId?: string; targetBridgeId?: string }) {
  return requestJson(joinUrl(daemonUrl, '/memory/applicable'), { method: 'POST', body: { client_instance_id: clientInstanceId, client_token: clientToken, target_agent_id: normalizeMemoryTargetValue(targetAgentId), target_project_id: normalizeMemoryTargetValue(targetProjectId), target_bridge_id: normalizeMemoryTargetValue(targetBridgeId) } });
}

export async function showMemory({ daemonUrl, clientInstanceId, clientToken, memoryId }: UserRpcRequest & { memoryId: string }) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'memory_show', body: { memory_id: memoryId } });
}

export async function memoryHistory({ daemonUrl, clientInstanceId, clientToken, memoryId }: UserRpcRequest & { memoryId: string }) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'memory_history', body: { memory_id: memoryId } });
}

export async function proposeMemory({ daemonUrl, clientInstanceId, clientToken, proposalAction, ...body }: UserRpcRequest & { proposalAction: 'new' | 'edit' | 'archive' | 'rollback' } & Record<string, any>) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: `memory_propose_${proposalAction}`, body: normalizeMemoryMutationBody(body) });
}

export async function decideMemory({ daemonUrl, clientInstanceId, clientToken, proposalId, decision, reason }: UserRpcRequest & { proposalId: string; decision: 'approve' | 'reject'; reason?: string }) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'memory_decide', body: { proposal_id: proposalId, decision, reason: reason || '' } });
}

export async function testLaunch({ daemonUrl, provider, model }: { daemonUrl: string; provider: string; model: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/test-launch'), { method: 'POST', body: { provider, model } });
}

export async function getTestStatus({ daemonUrl, testRunId }: { daemonUrl: string; testRunId: string }) {
  return requestJson(joinUrl(daemonUrl, `/agents/test-status?test_run_id=${encodeURIComponent(testRunId)}`));
}

export async function getTestHistory({ daemonUrl }: { daemonUrl: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/test-history'));
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

export async function listProjects({ daemonUrl, clientInstanceId, clientToken }: UserRpcRequest) {
  const data = await userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'project_list' });
  return { ...data, projects: (data.projects ?? []).map(normalizeProject) };
}

export async function showProject({ daemonUrl, clientInstanceId, clientToken, projectId }: UserRpcRequest & { projectId: string }) {
  const data = await userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'project_show', body: { project_id: projectId } });
  return { ...data, project: data.project ? normalizeProject(data.project) : null };
}

export async function createProject({ daemonUrl, clientInstanceId, clientToken, name, description, anchors }: UserRpcRequest & { name: string; description?: string; anchors?: ProjectAnchor[] }) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'project_create', body: { name, description: description || '', anchors: anchors || [] } });
}

export async function updateProject({ daemonUrl, clientInstanceId, clientToken, projectId, name, description, anchors }: UserRpcRequest & { projectId: string; name?: string; description?: string; anchors?: ProjectAnchor[] }) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'project_update', body: { project_id: projectId, name: name || '', description: description || '', anchors: anchors || [] } });
}

export async function deleteProject({ daemonUrl, clientInstanceId, clientToken, projectId }: UserRpcRequest & { projectId: string }) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'project_delete', body: { project_id: projectId } });
}

export async function reorderProjects({ daemonUrl, clientInstanceId, clientToken, projectIds }: UserRpcRequest & { projectIds: string[] }) {
  return userRpcRequest({ daemonUrl, clientInstanceId, clientToken, action: 'project_reorder', body: { project_ids: projectIds } });
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

export async function resetPreference({ daemonUrl, clientToken, key }: { daemonUrl: string; clientToken: string; key: string }) {
  return requestJson(joinUrl(daemonUrl, `/preferences/${encodeURIComponent(key)}`), {
    method: 'DELETE',
    headers: { 'Authorization': `Bearer ${clientToken || ''}` }
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

export async function testAgentConnectivity({ daemonUrl, clientToken, providers }: { daemonUrl: string; clientToken: string; providers?: string }) {
  return requestJson(joinUrl(daemonUrl, '/agents/test-connectivity'), {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${clientToken || ''}` },
    body: providers ? { providers } : undefined
  });
}

export async function fetchTaskChains({
  daemonUrl,
  clientToken,
  status,
  evaluation,
  limit = 100,
}: {
  daemonUrl: string;
  clientToken: string;
  status?: string;
  evaluation?: string;
  limit?: number;
}) {
  let path = `/task-chains?limit=${limit}`;
  if (status) path += `&status=${encodeURIComponent(status)}`;
  if (evaluation) path += `&evaluation=${encodeURIComponent(evaluation)}`;
  return requestJson(joinUrl(daemonUrl, path), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` },
  });
}

export async function fetchTaskChainDetail({ daemonUrl, clientToken, chainId }: { daemonUrl: string; clientToken: string; chainId: string }) {
  return requestJson(joinUrl(daemonUrl, `/api/v1/task-chains/${encodeURIComponent(chainId)}`), {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${clientToken}` },
  });
}

export async function createTaskChainRest({ daemonUrl, clientToken, title, description, kind, coordinatorAgentId }: { daemonUrl: string; clientToken: string; title: string; description?: string; kind?: string; coordinatorAgentId?: string }) {
  return requestJson(joinUrl(daemonUrl, '/api/v1/task-chains'), {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${clientToken}` },
    body: { title, description: description || '', kind: kind || 'team_work', coordinator_agent_id: coordinatorAgentId || '' },
  });
}

export async function updateTaskChainRest({ daemonUrl, clientToken, chainId, title, description, status }: { daemonUrl: string; clientToken: string; chainId: string; title?: string; description?: string; status?: string }) {
  return requestJson(joinUrl(daemonUrl, `/api/v1/task-chains/${encodeURIComponent(chainId)}`), {
    method: 'PATCH',
    headers: { 'Authorization': `Bearer ${clientToken}` },
    body: { title, description, status },
  });
}

export async function updateTaskDetail({ daemonUrl, clientToken, chainId, taskId, title, description, assigneeRef, reviewerRefs }: { daemonUrl: string; clientToken: string; chainId: string; taskId: string; title?: string; description?: string; assigneeRef?: any; reviewerRefs?: any[] }) {
  return requestJson(joinUrl(daemonUrl, `/api/v1/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}`), {
    method: 'PATCH',
    headers: { 'Authorization': `Bearer ${clientToken}` },
    body: { title, description, assignee_ref: assigneeRef, reviewer_refs: reviewerRefs },
  });
}

export async function cancelTaskDetail({ daemonUrl, clientToken, chainId, taskId }: { daemonUrl: string; clientToken: string; chainId: string; taskId: string }) {
  return requestJson(joinUrl(daemonUrl, `/api/v1/task-chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(taskId)}/cancel`), {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${clientToken}` },
    body: {},
  });
}

export async function addChainMember({ daemonUrl, clientToken, chainId, agentInstanceId, role }: { daemonUrl: string; clientToken: string; chainId: string; agentInstanceId: string; role?: string }) {
  return requestJson(joinUrl(daemonUrl, `/api/v1/task-chains/${encodeURIComponent(chainId)}/members`), {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${clientToken}` },
    body: { agent_instance_id: agentInstanceId, role: role || 'assignee' },
  });
}

export async function removeChainMember({ daemonUrl, clientToken, chainId, agentInstanceId }: { daemonUrl: string; clientToken: string; chainId: string; agentInstanceId: string }) {
  return requestJson(joinUrl(daemonUrl, `/api/v1/task-chains/${encodeURIComponent(chainId)}/members/${encodeURIComponent(agentInstanceId)}`), {
    method: 'DELETE',
    headers: { 'Authorization': `Bearer ${clientToken}` },
  });
}
