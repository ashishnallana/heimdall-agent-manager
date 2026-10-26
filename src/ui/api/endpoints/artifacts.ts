import { useEffect, useState } from 'react';
import { useSelector } from 'react-redux';
import * as daemonApi from '../daemonApi';
import { heimdallApi, withSessionQuery } from '../heimdallApi';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';
import {
  VAULT_ARMOR_PREFIX,
  isVaultArmored,
  encryptVaultText,
  decryptVaultText,
  decryptVaultBytes,
  getActiveVaultKey,
  base64ToBytes,
  bytesToBase64,
} from '../../utils/vaultContent';

type ArtifactAuthArgs = {
  daemonUrl?: string;
  clientToken?: string;
};

type ArtifactListArgs = ArtifactAuthArgs & {
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
};

type ArtifactCreateArgs = ArtifactAuthArgs & {
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
  content?: string;
};

type ArtifactUpdateArgs = ArtifactAuthArgs & {
  artifactId: string;
  name?: string;
  kind?: string;
  projectId?: string;
  description?: string;
  originKind?: string;
  originRef?: string;
  contentBase64?: string;
  changeReason?: string;
};

type ArtifactTextContentArgs = ArtifactAuthArgs & {
  artifactId: string;
  versionNo?: number | null;
};

type ArtifactRollbackArgs = ArtifactAuthArgs & {
  artifactId: string;
  versionNo: number;
  changeReason?: string;
};

type ArtifactAnnotationsArgs = ArtifactAuthArgs & {
  artifactId: string;
  versionNo?: number | null;
};

type CreateArtifactAnnotationArgs = ArtifactAuthArgs & {
  artifactId: string;
  versionNo?: number | null;
  contextType: string;
  contextJson: unknown;
  comment: string;
};

type UpdateArtifactAnnotationArgs = ArtifactAuthArgs & {
  annotationId: string;
  artifactId: string;
  versionNo?: number | null;
  comment: string;
};

type DeleteArtifactAnnotationArgs = ArtifactAuthArgs & {
  annotationId: string;
  artifactId: string;
  versionNo?: number | null;
};

function isElectronDeviceAuth(): boolean {
  return typeof window !== 'undefined' && Boolean((window as any).odinApi?.deviceAuth);
}

function isBrowserAmbientAuth(): boolean {
  if (typeof window === 'undefined') return false;
  return window.location.protocol === 'http:' || window.location.protocol === 'https:';
}

function auth(session: any) {
  // Hub v1 artifact endpoints should be auth-mode neutral. In the routed
  // Authentik app, same-origin cookies authenticate relative /api/v1 requests;
  // in Electron, the fetch bridge rewrites relative /api/v1 requests to the
  // configured Hub and injects the secure-store user token. Do not pass legacy
  // Redux clientToken values on those paths. If no legacy token exists in a web
  // shell, prefer the ambient /api/v1 route instead of an unauthenticated local
  // daemon URL so upload and preview use the same cookie/device auth path.
  const token = String(session?.clientToken || '');
  if (isElectronDeviceAuth() || token === 'v1' || (!token && isBrowserAmbientAuth())) return { daemonUrl: '', clientToken: '' };
  return { daemonUrl: session.daemonUrl, clientToken: token };
}

function artifactIdOf(row: any, fallback = '') {
  return String(row?.artifact_id || row?.artifactId || fallback || '');
}

function projectListTag(projectId = '') {
  return `PROJECT:${projectId || 'NONE'}`;
}

function originListTag(originRef = '') {
  return `ORIGIN:${originRef || 'NONE'}`;
}

function annotationScopeTag(artifactId: string, versionNo?: number | null) {
  return `${artifactId}:${versionNo == null ? 'HEAD' : versionNo}`;
}

function stringField(row: any, ...keys: string[]): string {
  for (const key of keys) {
    const value = row?.[key];
    if (value != null && String(value).trim()) return String(value).trim();
  }
  return '';
}

function inferExt(name: string, explicitExt = ''): string {
  const normalizedExt = String(explicitExt || '').trim().toLowerCase();
  if (normalizedExt) return normalizedExt.startsWith('.') ? normalizedExt : `.${normalizedExt}`;
  const normalizedName = String(name || '').trim().toLowerCase();
  const dot = normalizedName.lastIndexOf('.');
  if (dot <= 0 || dot === normalizedName.length - 1) return '';
  return normalizedName.slice(dot);
}

function inferKind(kind: string, mime: string, ext: string, name: string, renderer = ''): string {
  const explicit = String(kind || '').trim().toLowerCase();
  if (explicit) return explicit;
  const normalizedMime = String(mime || '').trim().toLowerCase();
  const normalizedExt = String(ext || '').trim().toLowerCase();
  const normalizedName = String(name || '').trim().toLowerCase();
  const normalizedRenderer = String(renderer || '').trim().toLowerCase();
  if (normalizedRenderer === 'markdown' || normalizedMime === 'text/markdown' || normalizedMime === 'text/plain' || ['.md', '.markdown', '.txt'].includes(normalizedExt) || normalizedName.endsWith('.md') || normalizedName.endsWith('.markdown') || normalizedName.endsWith('.txt')) return 'markdown';
  if (normalizedMime === 'image/png' || normalizedExt === '.png' || normalizedName.endsWith('.png')) return 'png';
  if (normalizedMime === 'image/jpeg' || ['.jpg', '.jpeg'].includes(normalizedExt) || normalizedName.endsWith('.jpg') || normalizedName.endsWith('.jpeg')) return 'jpeg';
  if (normalizedMime === 'text/csv' || normalizedExt === '.csv' || normalizedName.endsWith('.csv')) return 'csv';
  if (normalizedMime === 'text/html' || ['.html', '.htm'].includes(normalizedExt) || normalizedName.endsWith('.html') || normalizedName.endsWith('.htm')) return 'html';
  return '';
}

function inferMime(kind: string, explicitMime: string): string {
  const normalizedMime = String(explicitMime || '').trim().toLowerCase();
  if (normalizedMime) return normalizedMime;
  switch (String(kind || '').trim().toLowerCase()) {
    case 'markdown':
    case 'text':
      return 'text/markdown';
    case 'png':
      return 'image/png';
    case 'jpeg':
    case 'jpg':
      return 'image/jpeg';
    case 'csv':
      return 'text/csv';
    case 'html':
      return 'text/html';
    default:
      return '';
  }
}

export function normalizeArtifactRecord(row: any) {
  if (!row || typeof row !== 'object') return row;
  const artifactId = artifactIdOf(row);
  const name = stringField(row, 'name') || artifactId || 'Untitled artifact';
  const ext = inferExt(name, stringField(row, 'ext', 'extension'));
  const explicitMime = stringField(row, 'mime', 'content_type', 'contentType');
  const kind = inferKind(stringField(row, 'kind', 'type'), explicitMime, ext, name, stringField(row, 'renderer'));
  const mime = inferMime(kind, explicitMime);
  const contentType = stringField(row, 'content_type', 'contentType') || mime;
  const rawSize = row?.size_bytes ?? row?.sizeBytes ?? row?.size;
  const sizeBytes = Number(rawSize || 0);
  return {
    ...row,
    artifact_id: artifactId,
    artifactId,
    name,
    kind,
    mime,
    content_type: contentType,
    contentType,
    ext,
    size_bytes: Number.isFinite(sizeBytes) ? sizeBytes : 0,
    sizeBytes: Number.isFinite(sizeBytes) ? sizeBytes : 0,
    link: stringField(row, 'link') || (artifactId ? `artifact://${artifactId}` : ''),
  };
}

function normalizeArtifactResponse(data: any) {
  const raw = data?.artifact || data?.data?.artifact || (data?.data?.artifact_id || data?.data?.artifactId ? data.data : null) || (data?.artifact_id || data?.artifactId ? data : null);
  if (!raw) return data;
  return { ...data, artifact: normalizeArtifactRecord(raw) };
}

function normalizeArtifactVersionsResponse(data: any) {
  const rows = Array.isArray(data?.versions)
    ? data.versions
    : (Array.isArray(data?.data?.versions) ? data.data.versions : (Array.isArray(data?.data) ? data.data : []));
  return { ...data, versions: rows.map((row: any) => normalizeArtifactRecord(row)) };
}

function artifactContentUrl(session: any, artifactId: string, versionNo?: number | null) {
  const a = auth(session);
  return daemonApi.artifactContentUrl({ daemonUrl: a.daemonUrl, clientToken: a.clientToken, artifactId, version: versionNo });
}

function artifactFetchInit(session: any): RequestInit {
  const a = auth(session);
  return a.clientToken
    ? { headers: { 'Authorization': `Bearer ${a.clientToken}` }, credentials: 'omit' }
    : { credentials: 'include' };
}

function withoutArtifactAuthArgs<T extends ArtifactAuthArgs>(args: T): Omit<T, keyof ArtifactAuthArgs> {
  const { daemonUrl: _daemonUrl, clientToken: _clientToken, ...rest } = (args || {}) as T;
  return rest as Omit<T, keyof ArtifactAuthArgs>;
}

export const artifactsApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    listArtifacts: build.query<any, ArtifactListArgs>({
      queryFn: withSessionQuery(async (args, { session }) => {
        const {
          projectId = '',
          creatorId = '',
          originRef = '',
          includeDeleted = false,
          limit = 20,
          offset = 0,
          agent_instance_id,
          agentInstanceId,
          agent_id,
          agentId,
          chain_id,
          chainId,
          task_id,
          taskId,
          kind,
          since,
          until,
          sort,
          order,
          cursor,
        } = args || {};
        const data = await daemonApi.listArtifacts({
          ...auth(session),
          projectId,
          creatorId,
          originRef,
          includeDeleted,
          limit,
          offset,
          agent_instance_id,
          agentInstanceId,
          agent_id,
          agentId,
          chain_id,
          chainId,
          task_id,
          taskId,
          kind,
          since,
          until,
          sort,
          order,
          cursor,
        });
        return { ...data, artifacts: normalizeArtifacts(data) };
      }),
      providesTags: (result, _error, { projectId = '', originRef = '', chainId = '', chain_id = '' }) => [
        { type: 'Artifact' as const, id: projectListTag(projectId) },
        ...(originRef ? [{ type: 'Artifact' as const, id: originListTag(originRef) }] : []),
        ...(chainId || chain_id ? [{ type: 'Artifact' as const, id: `CHAIN_LIST:${chainId || chain_id}` }] : []),
        ...((result?.artifacts || []).map((artifact: any) => ({ type: 'Artifact' as const, id: artifactIdOf(artifact) })).filter((tag: any) => Boolean(tag.id))),
      ],
    }),
    fetchArtifactsPage: build.query<any, ArtifactListArgs & { offset: number }>({
      queryFn: withSessionQuery(async (args, { session }) => {
        const {
          projectId = '',
          creatorId = '',
          originRef = '',
          includeDeleted = false,
          limit = 20,
          offset = 0,
          agent_instance_id,
          agentInstanceId,
          agent_id,
          agentId,
          chain_id,
          chainId,
          task_id,
          taskId,
          kind,
          since,
          until,
          sort,
          order,
          cursor,
        } = args || {};
        const data = await daemonApi.listArtifacts({
          ...auth(session),
          projectId,
          creatorId,
          originRef,
          includeDeleted,
          limit,
          offset,
          agent_instance_id,
          agentInstanceId,
          agent_id,
          agentId,
          chain_id,
          chainId,
          task_id,
          taskId,
          kind,
          since,
          until,
          sort,
          order,
          cursor,
        });
        return { ...data, artifacts: normalizeArtifacts(data) };
      }),
      async onQueryStarted(arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          const {
            projectId,
            creatorId,
            originRef,
            includeDeleted,
            limit = 20,
            daemonUrl,
            clientToken,
            agent_instance_id,
            agentInstanceId,
            agent_id,
            agentId,
            chain_id,
            chainId,
            task_id,
            taskId,
            kind,
            since,
            until,
            sort,
            order,
            cursor,
          } = arg;
          const cacheKeyArgs = {
            projectId,
            creatorId,
            originRef,
            includeDeleted,
            limit,
            daemonUrl,
            clientToken,
            agent_instance_id,
            agentInstanceId,
            agent_id,
            agentId,
            chain_id,
            chainId,
            task_id,
            taskId,
            kind,
            since,
            until,
            sort,
            order,
            cursor,
          };
          dispatch(
            artifactsApi.util.updateQueryData('listArtifacts', cacheKeyArgs, (draft) => {
              if (!draft) return;
              draft.has_more = data.has_more;
              draft.next_cursor = data.next_cursor;
              draft.next_offset = data.next_offset;
              draft.total = data.total;
              
              const existingIds = new Set(draft.artifacts.map((a: any) => a.artifact_id || a.artifactId));
              for (const art of data.artifacts) {
                const id = art.artifact_id || art.artifactId;
                if (!existingIds.has(id)) {
                  draft.artifacts.push(art);
                }
              }
            })
          );
        } catch {}
      }
    }),
    fetchArtifactMeta: build.query<any, ArtifactAuthArgs & { artifactId: string }>({
      queryFn: withSessionQuery(async ({ artifactId }, { session }) => {
        if (!artifactId) return { artifact: null };
        return normalizeArtifactResponse(await daemonApi.fetchArtifactMeta({ ...auth(session), artifactId }));
      }),
      providesTags: (_result, _error, { artifactId }) => [{ type: 'Artifact' as const, id: artifactId }],
    }),
    fetchArtifactVersions: build.query<any, ArtifactAuthArgs & { artifactId: string }>({
      queryFn: withSessionQuery(async ({ artifactId }, { session }) => {
        if (!artifactId) return { versions: [] };
        try {
          return normalizeArtifactVersionsResponse(await daemonApi.fetchArtifactVersions({ ...auth(session), artifactId }));
        } catch {
          return { versions: [] };
        }
      }),
      providesTags: (_result, _error, { artifactId }) => [{ type: 'ArtifactVersions' as const, id: artifactId }],
    }),
    fetchArtifactTextContent: build.query<any, ArtifactTextContentArgs>({
      queryFn: withSessionQuery(async ({ artifactId, versionNo = null }, { session, state }) => {
        if (!artifactId) return { artifactId, versionNo, text: '' };
        const response = await fetch(artifactContentUrl(session, artifactId, versionNo), artifactFetchInit(session));
        if (!response.ok) throw new Error(`Failed to load artifact content (${response.status})`);
        const body = await response.text();
        const responseContentType = response.headers.get('content-type') || '';
        let text = body;
        if (/\bjson\b/i.test(responseContentType)) {
          try {
            const parsed = JSON.parse(body);
            const extracted = typeof parsed?.content === 'string'
              ? parsed.content
              : typeof parsed?.data?.content === 'string'
                ? parsed.data.content
                : typeof parsed?.text === 'string'
                  ? parsed.text
                  : '';
            if (extracted) text = extracted;
          } catch {}
        }
        const isUnlocked = Boolean(state?.vault?.isUnlocked);
        const activeKey = getActiveVaultKey();
        if (isUnlocked && activeKey && isVaultArmored(text)) {
          try {
            text = await decryptVaultText(text, activeKey);
          } catch {}
        }
        return { artifactId, versionNo, text };
      }),
      providesTags: (_result, _error, { artifactId }) => [{ type: 'ArtifactContent' as const, id: artifactId }],
      keepUnusedDataFor: 0,
    }),
    fetchArtifactAnnotations: build.query<any, ArtifactAnnotationsArgs>({
      queryFn: withSessionQuery(async ({ artifactId, versionNo = null }, { session }) => {
        if (!artifactId) return { annotations: [] };
        try {
          const data = await daemonApi.fetchArtifactAnnotations({ ...auth(session), artifactId, versionNo });
          return { ...data, annotations: Array.isArray(data?.annotations) ? data.annotations : (Array.isArray(data?.data) ? data.data : []) };
        } catch {
          return { annotations: [] };
        }
      }),
      providesTags: (_result, _error, { artifactId, versionNo = null }) => [
        { type: 'ArtifactAnnotations' as const, id: artifactId },
        { type: 'ArtifactAnnotations' as const, id: annotationScopeTag(artifactId, versionNo) },
      ],
    }),
    createArtifact: build.mutation<any, ArtifactCreateArgs>({
      queryFn: withSessionQuery(async (args, { session, state }) => {
        const isUnlocked = Boolean(state?.vault?.isUnlocked);
        const activeKey = getActiveVaultKey();
        let effectiveArgs = args;
        if (isUnlocked && activeKey) {
          let file = args.file;
          let contentBase64 = args.contentBase64;
          let content = (args as any).content;
          let name = args.name;
          let description = args.description;

          if (name && !isVaultArmored(name)) {
            name = await encryptVaultText(name, activeKey);
          }
          if (description && !isVaultArmored(description)) {
            description = await encryptVaultText(description, activeKey);
          }

          if (content && typeof content === 'string' && !isVaultArmored(content)) {
            const encContent = await encryptVaultText(content, activeKey);
            contentBase64 = bytesToBase64(new TextEncoder().encode(encContent));
            content = encContent;
          } else if (contentBase64 && typeof contentBase64 === 'string') {
            try {
              const decoded = new TextDecoder('utf-8', { fatal: true }).decode(base64ToBytes(contentBase64));
              if (decoded && !isVaultArmored(decoded)) {
                const encContent = await encryptVaultText(decoded, activeKey);
                contentBase64 = bytesToBase64(new TextEncoder().encode(encContent));
                content = encContent;
              }
            } catch {}
          } else if (file instanceof Blob) {
            const mime = String(args.mime || (file as any).type || '').toLowerCase();
            const ext = inferExt(args.name, args.ext);
            const isText = mime.startsWith('text/') || mime === 'application/json' || ['.md', '.markdown', '.txt', '.json', '.diff', '.patch', '.csv'].includes(ext);
            if (isText) {
              try {
                const text = await file.text();
                if (text && !isVaultArmored(text)) {
                  const encContent = await encryptVaultText(text, activeKey);
                  contentBase64 = bytesToBase64(new TextEncoder().encode(encContent));
                  content = encContent;
                  file = null;
                }
              } catch {}
            }
          }

          effectiveArgs = {
            ...args,
            name,
            description,
            file,
            contentBase64,
            ...(content !== undefined ? { content } : {}),
          };
        }
        const data = await daemonApi.createArtifact({ ...withoutArtifactAuthArgs(effectiveArgs), ...auth(session) });
        const artifact = normalizeArtifact(data?.artifact || data?.data || data);
        return { ...data, artifact, link: artifact?.link || (artifact?.artifact_id ? `artifact://${artifact.artifact_id}` : '') };
      }),
      invalidatesTags: (result, _error, { projectId = '', originRef = '', chainId = '', chain_id = '' }) => {
        const artifactId = artifactIdOf(result?.artifact);
        const resolvedChainId = chainId || chain_id || result?.artifact?.chain_id || result?.artifact?.chainId;
        return [
          { type: 'Artifact' as const, id: projectListTag(projectId || result?.artifact?.project_id || result?.artifact?.projectId || '') },
          ...(originRef || result?.artifact?.origin_ref ? [{ type: 'Artifact' as const, id: originListTag(originRef || result?.artifact?.origin_ref || result?.artifact?.originRef || '') }] : []),
          ...(resolvedChainId ? [{ type: 'Artifact' as const, id: `CHAIN_LIST:${resolvedChainId}` }] : []),
          ...(artifactId ? [
            { type: 'Artifact' as const, id: artifactId },
            { type: 'ArtifactContent' as const, id: artifactId },
            { type: 'ArtifactVersions' as const, id: artifactId },
            { type: 'ArtifactAnnotations' as const, id: artifactId },
          ] : []),
        ];
      },
    }),
    updateArtifact: build.mutation<any, ArtifactUpdateArgs>({
      queryFn: withSessionQuery(async (args, { session, state }) => {
        const isUnlocked = Boolean(state?.vault?.isUnlocked);
        const activeKey = getActiveVaultKey();
        let name = args.name;
        let description = args.description;
        if (isUnlocked && activeKey) {
          if (name && !isVaultArmored(name)) {
            name = await encryptVaultText(name, activeKey);
          }
          if (description && !isVaultArmored(description)) {
            description = await encryptVaultText(description, activeKey);
          }
        }
        return daemonApi.updateArtifact({
          ...withoutArtifactAuthArgs({
            ...args,
            ...(name !== undefined ? { name } : {}),
            ...(description !== undefined ? { description } : {}),
          }),
          ...auth(session),
        });
      }),
      invalidatesTags: (result, _error, { artifactId, projectId = '', originRef = '' }) => {
        const updated = result?.artifact || {};
        return [
          { type: 'Artifact' as const, id: artifactId },
          { type: 'Artifact' as const, id: projectListTag(projectId || updated.project_id || updated.projectId || '') },
          ...(originRef || updated.origin_ref ? [{ type: 'Artifact' as const, id: originListTag(originRef || updated.origin_ref || updated.originRef || '') }] : []),
          { type: 'ArtifactContent' as const, id: artifactId },
          { type: 'ArtifactVersions' as const, id: artifactId },
          { type: 'ArtifactAnnotations' as const, id: artifactId },
        ];
      },
    }),
    rollbackArtifact: build.mutation<any, ArtifactRollbackArgs>({
      queryFn: withSessionQuery(async ({ artifactId, versionNo, changeReason = '' }, { session }) => {
        return daemonApi.rollbackArtifact({ ...auth(session), artifactId, versionNo, changeReason });
      }),
      invalidatesTags: (_result, _error, { artifactId }) => [
        { type: 'Artifact' as const, id: artifactId },
        { type: 'ArtifactContent' as const, id: artifactId },
        { type: 'ArtifactVersions' as const, id: artifactId },
        { type: 'ArtifactAnnotations' as const, id: artifactId },
      ],
    }),
    createArtifactAnnotation: build.mutation<any, CreateArtifactAnnotationArgs>({
      queryFn: withSessionQuery(async (args, { session }) => daemonApi.createArtifactAnnotation({ ...withoutArtifactAuthArgs(args), ...auth(session) })),
      invalidatesTags: (_result, _error, { artifactId, versionNo = null }) => [
        { type: 'ArtifactAnnotations' as const, id: artifactId },
        { type: 'ArtifactAnnotations' as const, id: annotationScopeTag(artifactId, versionNo) },
      ],
    }),
    updateArtifactAnnotation: build.mutation<any, UpdateArtifactAnnotationArgs>({
      queryFn: withSessionQuery(async (args, { session }) => daemonApi.updateArtifactAnnotation({ ...withoutArtifactAuthArgs(args), ...auth(session) })),
      invalidatesTags: (_result, _error, { artifactId, versionNo = null }) => [
        { type: 'ArtifactAnnotations' as const, id: artifactId },
        { type: 'ArtifactAnnotations' as const, id: annotationScopeTag(artifactId, versionNo) },
      ],
    }),
    deleteArtifactAnnotation: build.mutation<any, DeleteArtifactAnnotationArgs>({
      queryFn: withSessionQuery(async (args, { session }) => daemonApi.deleteArtifactAnnotation({ ...withoutArtifactAuthArgs(args), ...auth(session) })),
      invalidatesTags: (_result, _error, { artifactId, versionNo = null }) => [
        { type: 'ArtifactAnnotations' as const, id: artifactId },
        { type: 'ArtifactAnnotations' as const, id: annotationScopeTag(artifactId, versionNo) },
      ],
    }),
    deleteArtifact: build.mutation<any, ArtifactAuthArgs & { artifactId: string }>({
      queryFn: withSessionQuery(async ({ artifactId }, { session }) => daemonApi.deleteArtifact({ ...auth(session), artifactId })),
      invalidatesTags: (_result, _error, { artifactId }) => [
        { type: 'Artifact' as const, id: artifactId },
        { type: 'ArtifactContent' as const, id: artifactId },
        { type: 'ArtifactVersions' as const, id: artifactId },
        { type: 'ArtifactAnnotations' as const, id: artifactId },
      ],
    }),
  }),
});

export function normalizeArtifact(row: any) {
  if (!row) return null;
  return normalizeArtifactRecord(row);
}

export function normalizeArtifacts(data: any) {
  const rows = Array.isArray(data?.artifacts)
    ? data.artifacts
    : (Array.isArray(data?.data?.artifacts) ? data.data.artifacts : (Array.isArray(data?.data) ? data.data : (Array.isArray(data) ? data : [])));
  return rows
    .map((row: any) => normalizeArtifact(row))
    .filter((row: any) => row?.artifact_id || row?.artifactId)
    .sort((a: any, b: any) => {
      const left = Number(b?.updated_unix_ms || b?.updatedUnixMs || b?.updated_at || b?.updatedAt || b?.created_unix_ms || b?.createdUnixMs || 0);
      const right = Number(a?.updated_unix_ms || a?.updatedUnixMs || a?.updated_at || a?.updatedAt || a?.created_unix_ms || a?.createdUnixMs || 0);
      return left - right;
    });
}

export type ArtifactContentState = {
  url: string;
  /** The decrypted content (binary-exact), or the raw payload when it is not armored. */
  blob: Blob | null;
  loading: boolean;
  error: string;
  /** The payload is vault-armored and could not be opened (vault locked or another vault). */
  locked: boolean;
  /** Why `locked` is set: the vault is locked (or lacks the epoch key), or the payload was sealed by a previous vault. */
  lockReason: '' | 'locked' | 'other_vault';
};

const EMPTY_CONTENT_STATE: ArtifactContentState = { url: '', blob: null, loading: false, error: '', locked: false, lockReason: '' };

export function useArtifactContentState({ daemonUrl, clientToken, artifactId, versionNo = null }: { daemonUrl: string; clientToken: string; artifactId: string; versionNo?: number | null }) {
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const [state, setState] = useState<ArtifactContentState>(EMPTY_CONTENT_STATE);
  useEffect(() => {
    const token = String(clientToken || '');
    const ambientAuth = isElectronDeviceAuth() || token === 'v1';
    if (!artifactId || (!ambientAuth && (!daemonUrl || !token))) {
      setState(EMPTY_CONTENT_STATE);
      return;
    }
    let cancelled = false;
    let nextUrl = '';
    // Dropping the previous blob here is what clears a decrypted preview on vault lock,
    // version change and close: `isUnlocked`, `versionNo` and `artifactId` re-run this.
    setState({ ...EMPTY_CONTENT_STATE, loading: true });
    fetch(daemonApi.artifactContentUrl({ daemonUrl: ambientAuth ? '' : daemonUrl, artifactId, version: versionNo }), ambientAuth
      ? { credentials: 'include' }
      : { headers: token ? { 'Authorization': `Bearer ${token}` } : undefined, credentials: token ? 'omit' : 'include' })
      .then((response) => {
        if (!response.ok) throw new Error(`Failed to load artifact content (${response.status})`);
        return response.blob();
      })
      .then(async (blob) => {
        let finalBlob = blob;
        let locked = false;
        let lockReason: ArtifactContentState['lockReason'] = '';
        // Resolved here rather than in render: the active CryptoKey is a module-level
        // ref, not reactive state, so it must be read when the blob is decrypted.
        // `isUnlocked` is the reactive trigger that re-runs this effect on unlock/lock.
        // Only an armored payload is read as text; unencrypted binaries stay untouched.
        const rawText = (await blob.slice(0, VAULT_ARMOR_PREFIX.length).text()) === VAULT_ARMOR_PREFIX ? await blob.text() : '';
        if (rawText && isVaultArmored(rawText)) {
          locked = true;
          lockReason = 'locked';
          const activeKey = getActiveVaultKey();
          if (isUnlocked && activeKey) {
            try {
              // Bytes, not text: TextDecoder would corrupt binary payloads (ZIP bundles,
              // images) by replacing invalid UTF-8 with U+FFFD (REQ-BUNDLE-4).
              const opened = await decryptVaultBytes(rawText, activeKey);
              if (opened.status === 'ok') {
                finalBlob = new Blob([opened.bytes as unknown as BlobPart], { type: blob.type || 'application/octet-stream' });
                opened.bytes.fill(0);
                locked = false;
                lockReason = '';
              } else if (opened.status === 'other_vault') {
                lockReason = 'other_vault';
              }
            } catch {}
          }
        }
        nextUrl = URL.createObjectURL(finalBlob);
        if (cancelled) URL.revokeObjectURL(nextUrl);
        else setState({ url: nextUrl, blob: finalBlob, loading: false, error: '', locked, lockReason });
      })
      .catch((err) => {
        if (!cancelled) setState({ ...EMPTY_CONTENT_STATE, error: String(err?.message || err || 'Failed to load artifact content') });
      });
    return () => {
      cancelled = true;
      if (nextUrl) URL.revokeObjectURL(nextUrl);
    };
  }, [daemonUrl, clientToken, artifactId, versionNo, isUnlocked]);
  return state;
}

export const {
  useListArtifactsQuery,
  useFetchArtifactMetaQuery,
  useFetchArtifactVersionsQuery,
  useFetchArtifactTextContentQuery,
  useCreateArtifactMutation,
  useUpdateArtifactMutation,
  useDeleteArtifactMutation,
} = artifactsApi;
