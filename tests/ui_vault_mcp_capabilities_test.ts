import assert from 'node:assert/strict';
import test from 'node:test';
import { MCP_CAPABILITIES, validMcpScopes, mcpScopeSubset, mcpConsentVersion, mcpConsentDomain, selectedMcpScopes } from '../src/ui/utils/mcpCapabilities.ts';

test('MCP capabilities are canonical, explicit and versioned without implicit escalation', () => {
  assert.equal(mcpConsentVersion('mcp:chains'), 1);
  const all = ['mcp:chains', ...MCP_CAPABILITIES.map(([scope]) => scope)].join(' ');
  assert.ok(validMcpScopes(all));
  assert.equal(mcpConsentVersion(all), 2);
  assert.notEqual(mcpConsentDomain(1), mcpConsentDomain(2));
  assert.throws(() => mcpConsentDomain(0));
  assert.equal(selectedMcpScopes(all, []), 'mcp:chains');
  assert.equal(selectedMcpScopes(all, ['mcp:artifacts:write', 'mcp:tasks:read']), 'mcp:chains mcp:tasks:read mcp:artifacts:write');
  assert.equal(mcpScopeSubset(all, 'mcp:chains'), false);
  assert.throws(() => selectedMcpScopes('mcp:chains', ['mcp:tasks:write']));
  assert.throws(() => selectedMcpScopes(all, ['mcp:tasks:read', 'mcp:tasks:read']));
  for (const bad of ['', 'mcp:tasks:read', 'mcp:chains ', 'mcp:chains  mcp:tasks:read', 'mcp:chains mcp:tasks:read mcp:tasks:read', 'mcp:chains mcp:tasks:write mcp:tasks:read', 'mcp:chains mcp:unknown', 'mcp:chains mcp:messages:write']) {
    assert.equal(validMcpScopes(bad), false, bad);
    assert.equal(mcpConsentVersion(bad), 0, bad);
  }
});
