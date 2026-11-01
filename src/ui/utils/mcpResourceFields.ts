import type { VaultKeyring } from './vaultKeyring.ts';
import { encryptVaultText } from './vaultContent.ts';

export const resourceSpecs: Record<string, { fields: string[]; text: string[] }> = {
  memory: { fields: ['memory_id', 'read_only', 'title', 'description', 'body', 'evidence', 'title_error', 'description_error', 'body_error', 'evidence_error', 'type', 'status', 'expires_at', 'agent_ids', 'project_ids', 'bridge_ids', 'template_ids', 'proposed_by_instance_id', 'proposed_in_chain_id', 'created_at', 'updated_at', 'revision'], text: ['title', 'description', 'body', 'evidence'] },
  project: { fields: ['project_id', 'name', 'name_error', 'slug', 'description', 'description_error', 'repo_url', 'vcs_kind', 'default_path', 'state', 'created_at', 'updated_at', 'revision', 'bridge_paths'], text: ['name', 'description', 'slug'] },
  issue: { fields: ['issue_id', 'title', 'title_error', 'description', 'description_error', 'description_limit', 'created_by', 'status', 'scope_type', 'target_id', 'chain_id', 'vote_count', 'comment_count', 'created_at', 'updated_at', 'closed_at', 'revision', 'comments', 'comments_next_cursor'], text: ['title', 'description'] },
  issue_comment: { fields: ['comment_id', 'issue_id', 'author_id', 'author_name', 'body', 'body_error', 'created_at', 'updated_at'], text: ['author_name', 'body'] },
};
export const resourceToolKinds: Record<string, string> = { 'memories.list': 'memory', 'memories.get': 'memory', 'projects.list': 'project', 'projects.get': 'project', 'issues.list': 'issue', 'issues.get': 'issue' };
export async function sealResourceFields(tool: string, input: unknown, keyring: VaultKeyring): Promise<string> {
  const kind = ({ 'memories.create': 'memory', 'memories.update': 'memory', 'projects.create': 'project', 'projects.update': 'project', 'issues.create': 'issue', 'issues.update': 'issue', 'issues.comment': 'issue_comment' } as Record<string, string>)[tool];
  if (!kind || !input || typeof input !== 'object' || Array.isArray(input)) throw new Error('Invalid resource fields');
  const allowed = kind === 'issue_comment' ? ['body'] : kind === 'project' ? ['name', 'description'] : resourceSpecs[kind].text;
  const output: Record<string, string> = {};
  for (const [key, value] of Object.entries(input)) {
    const limit = key === 'title' || key === 'name' ? 500 : kind === 'memory' && key === 'body' ? 65536 : 20000;
    if (!allowed.includes(key) || typeof value !== 'string' || new TextEncoder().encode(value).length > limit || (['name', 'title', 'body'].includes(key) && !value.trim())) throw new Error('Invalid resource text');
    output[key] = await encryptVaultText(value, keyring);
  }
  return JSON.stringify(output);
}
