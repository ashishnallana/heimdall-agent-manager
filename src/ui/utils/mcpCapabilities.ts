export const MCP_BASE_SCOPE = 'mcp:chains';
export const MCP_CAPABILITIES = [
  ['mcp:tasks:read', 'Read tasks'], ['mcp:tasks:write', 'Manage and dispatch tasks on your machines'],
  ['mcp:agents:read', 'Read agent definitions'], ['mcp:agents:write', 'Manage agent definitions'],
  ['mcp:instances:read', 'Read sessions and available machines/providers'], ['mcp:instances:control', 'Launch, stop and move sessions'],
  ['mcp:memories:read', 'Read memories'], ['mcp:memories:write', 'Create, edit and archive memories'],
  ['mcp:projects:read', 'Read projects'], ['mcp:projects:write', 'Manage projects'],
  ['mcp:issues:read', 'Read issues'], ['mcp:issues:write', 'Manage issues'],
  ['mcp:artifacts:read', 'Read artifacts'], ['mcp:artifacts:write', 'Manage artifacts'],
  ['mcp:chains:message', 'Send messages as you to chain coordinators and wake them on your machines'],
] as const;

/** Fixed order and unique known scopes match the signed native representation. */
export function validMcpScopes(scope: unknown): scope is string {
  if (scope === MCP_BASE_SCOPE) return true;
  if (typeof scope !== 'string' || scope.length > 1024 || !scope.startsWith(`${MCP_BASE_SCOPE} `)) return false;
  const parts = scope.split(' ');
  if (parts.length < 2 || parts.length > MCP_CAPABILITIES.length + 1) return false;
  let previous = -1;
  for (const part of parts.slice(1)) {
    const index = MCP_CAPABILITIES.findIndex(([value]) => value === part);
    if (index <= previous) return false;
    previous = index;
  }
  return true;
}
export function mcpScopeSubset(selected: string, requested: string): boolean {
  if (!validMcpScopes(selected) || !validMcpScopes(requested)) return false;
  const allowed = new Set(requested.split(' '));
  return selected.split(' ').every((scope) => allowed.has(scope));
}
export function mcpConsentVersion(scope: unknown): 0 | 1 | 2 {
  return !validMcpScopes(scope) ? 0 : scope === MCP_BASE_SCOPE ? 1 : 2;
}
export function mcpConsentDomain(version: number): string {
  if (version !== 1 && version !== 2) throw new Error('Unsupported connector consent');
  return `heimdall-mcp-consent/v${version}\n`;
}
export function selectedMcpScopes(requested: string, selected: readonly string[]): string {
  if (!validMcpScopes(requested) || new Set(selected).size !== selected.length || selected.some((scope) => !MCP_CAPABILITIES.some(([known]) => known === scope))) throw new Error('Invalid connector permissions');
  const result = [MCP_BASE_SCOPE, ...MCP_CAPABILITIES.map(([value]) => value).filter((value) => selected.includes(value))].join(' ');
  if (!mcpScopeSubset(result, requested)) throw new Error('Permission was not requested');
  return result;
}
