import type { VaultKeyring } from './vaultKeyring.ts';
import { encryptVaultText } from './vaultContent.ts';
import { decryptVaultBytes, encryptVaultBytes } from './vaultCrypto.ts';
import { HTML_BUNDLE_LIMITS, readHtmlBundle } from './htmlBundle.ts';

/** base64 of the 15 MiB html-bundle archive (artifacts.create content_base64). */
export const MCP_ARTIFACT_BUNDLE_BASE64_MAX = Math.floor((HTML_BUNDLE_LIMITS.archiveBytes + 2) / 3) * 4;
/** Matches vault.control_job_payload_max: bundle seal (create) and bundle download (get) jobs only, all others 4 MiB. */
export function mcpJobPayloadMax(operation: string, tool?: string): number {
  return (operation === 'seal_resource' && tool === 'artifacts.create') || (operation === 'read' && tool === 'artifacts.get') ? MCP_ARTIFACT_BUNDLE_BASE64_MAX + 1024 * 1024 : 4 * 1024 * 1024;
}

/**
 * artifacts.get of an html-bundle: open the relayed vault token to the exact archive
 * bytes and return them as canonical base64 (matches vault.control_artifact_bundle_open).
 * Only the ZIP magic and the 15 MiB size are checked; the viewer validates on render.
 */
export async function openArtifactBundle(kind: unknown, token: unknown, keyring: VaultKeyring): Promise<string> {
  if (kind !== 'html-bundle' || typeof token !== 'string' || !token.startsWith('vault:v2:') || token.length > MCP_ARTIFACT_BUNDLE_BASE64_MAX + 1024 * 1024) throw new Error('Invalid artifact bundle');
  const opened = await decryptVaultBytes(token, keyring);
  if (opened.status !== 'ok') throw new Error('MCP key unavailable');
  const bytes = opened.bytes;
  try {
    if (bytes.length < 4 || bytes.length > HTML_BUNDLE_LIMITS.archiveBytes || bytes[0] !== 0x50 || bytes[1] !== 0x4b || bytes[2] !== 3 || bytes[3] !== 4) throw new Error('Invalid artifact bundle');
    let binary = '';
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    return btoa(binary);
  } finally { bytes.fill(0); }
}

/** Canonical standard base64 only (padded, no whitespace), as the Odin sealer requires. */
function decodeCanonicalBase64(text: string): Uint8Array {
  if (text.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(text)) throw new Error('Invalid bundle encoding');
  const binary = atob(text);
  const bytes = Uint8Array.from(binary, c => c.charCodeAt(0));
  let again = '';
  for (let i = 0; i < bytes.length; i += 0x8000) again += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  if (btoa(again) !== text) throw new Error('Invalid bundle encoding');
  return bytes;
}

export const resourceSpecs: Record<string, { fields: string[]; text: string[] }> = {
  artifact: { fields: ["artifact_id", "name", "description", "kind", "content_type", "mime", "ext", "size_bytes", "stored_bytes", "agent_id", "agent_instance_id", "chain_id", "task_id", "project_id", "link", "created_at", "updated_at", "revision", "content", "content_error", "content_base64"], text: ["name", "description", "content"] },
  memory: { fields: ['memory_id', 'read_only', 'title', 'description', 'body', 'evidence', 'title_error', 'description_error', 'body_error', 'evidence_error', 'type', 'status', 'expires_at', 'agent_ids', 'project_ids', 'bridge_ids', 'template_ids', 'proposed_by_instance_id', 'proposed_in_chain_id', 'created_at', 'updated_at', 'revision'], text: ['title', 'description', 'body', 'evidence'] },
  project: { fields: ['project_id', 'name', 'name_error', 'slug', 'description', 'description_error', 'repo_url', 'vcs_kind', 'default_path', 'state', 'created_at', 'updated_at', 'revision', 'bridge_paths'], text: ['name', 'description', 'slug'] },
  issue: { fields: ['issue_id', 'title', 'title_error', 'description', 'description_error', 'description_limit', 'created_by', 'status', 'scope_type', 'target_id', 'chain_id', 'vote_count', 'comment_count', 'created_at', 'updated_at', 'closed_at', 'revision', 'comments', 'comments_next_cursor'], text: ['title', 'description'] },
  issue_comment: { fields: ['comment_id', 'issue_id', 'author_id', 'author_name', 'body', 'body_error', 'created_at', 'updated_at'], text: ['author_name', 'body'] },
};
export const resourceToolKinds: Record<string, string> = { 'artifacts.list': 'artifact', 'artifacts.get': 'artifact', 'memories.list': 'memory', 'memories.get': 'memory', 'projects.list': 'project', 'projects.get': 'project', 'issues.list': 'issue', 'issues.get': 'issue' };
export async function sealResourceFields(tool: string, input: unknown, keyring: VaultKeyring): Promise<string> {
  const kind = ({ 'artifacts.create': 'artifact', 'artifacts.update': 'artifact', 'memories.create': 'memory', 'memories.update': 'memory', 'projects.create': 'project', 'projects.update': 'project', 'issues.create': 'issue', 'issues.update': 'issue', 'issues.comment': 'issue_comment' } as Record<string, string>)[tool];
  if (!kind || !input || typeof input !== 'object' || Array.isArray(input)) throw new Error('Invalid resource fields');
  const allowed = kind === 'issue_comment' ? ['body'] : kind === 'project' || tool === 'artifacts.update' ? ['name', 'description'] : resourceSpecs[kind].text;
  const output: Record<string, string> = {};
  if ('content_base64' in input) {
    if (tool !== 'artifacts.create' || 'content' in input) throw new Error('Invalid resource fields');
  }
  for (const [key, value] of Object.entries(input)) {
    if (key === 'content_base64') {
      // Hub-packed html-bundle: re-validate before sealing the exact archive bytes.
      if (typeof value !== 'string' || value.length > MCP_ARTIFACT_BUNDLE_BASE64_MAX) throw new Error('Invalid bundle');
      const archive = decodeCanonicalBase64(value);
      if (archive.length === 0 || archive.length > HTML_BUNDLE_LIMITS.archiveBytes) throw new Error('Invalid bundle');
      await readHtmlBundle(archive);
      output[key] = await encryptVaultBytes(archive, keyring);
      archive.fill(0);
      continue;
    }
    const limit = key === 'title' || key === 'name' ? 500 : (kind === 'memory' && key === 'body' || kind === 'artifact' && key === 'content') ? 65536 : 20000;
    if (!allowed.includes(key) || typeof value !== 'string' || value.includes('\0') || value !== new TextDecoder('utf-8', { fatal: true }).decode(new TextEncoder().encode(value)) || new TextEncoder().encode(value).length > limit || (['name', 'title', 'body'].includes(key) && !value.trim())) throw new Error('Invalid resource text');
    output[key] = await encryptVaultText(value, keyring);
  }
  return JSON.stringify(output);
}
