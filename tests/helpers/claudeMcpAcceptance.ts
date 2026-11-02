// Actual Claude Code consumes only this ephemeral MCP connection. The config
// contains a synthetic-account token and is never printed or retained.
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { check } from './nativeMcpAcceptance.ts';

export async function claudeMcpAcceptance(h: any, token: string, chainId: string, agentId: string, bridgeId: string, instanceId: string) {
  const config = path.join(h.root, 'claude-mcp.json');
  fs.writeFileSync(config, JSON.stringify({ mcpServers: { heimdall: { type: 'http', url: h.base + '/api/v1/mcp', headers: { Authorization: 'Bearer ' + token } } } }), { mode: 0o600 });
  const prompt = `This is an authorized disposable MCP acceptance test with a synthetic account. Use only the heimdall MCP tools. Create a task in chain ${chainId}, assigned to durable agent ${agentId} on bridge ${bridgeId}. Use request_id claude-controlled-task, title Claude-controlled acceptance, requires_user_approval false. Goal: Write claude-result.md containing exactly MCP_CLAUDE_OFFLOAD_OK; upload it using ham-ctl artifact create --name claude-result.md --kind markdown --content-type text/markdown --file claude-result.md and submit the native task lease. Acceptance: task completed and its task-associated artifact contains MCP_CLAUDE_OFFLOAD_OK. You ARE authorized to start the existing instance ${instanceId} when it is stopped: read instances.get, use its revision with instances.start and a stable request_id, then poll instances.operations or instances.get. Native idle shutdown can stop it between jobs. If the task is blocked on agent_not_running after a restart, read its current revision and call tasks.control action recheck with a stable request_id. This lifecycle recovery is explicitly part of the test. Poll tasks.get until done (maximum 120 seconds, at most 25 reads), then artifacts.list filtered by the new task_id and artifacts.get for its result. Return the actual task_id, artifact_id and retrieved content. Do not fabricate results or substitute an artifact you create yourself. No messages, permission changes or review approvals. If a tool fails, report the exact safe error.`;
  try {
    const env = { ...process.env, NODE_EXTRA_CA_CERTS: h.certFile }; delete env.CLAUDECODE;
    const child = spawn(process.env.HEIMDALL_E2E_CLAUDE_BIN || 'claude', ['--settings', '{"disableAllHooks":true}', '--setting-sources', '', '--no-session-persistence', '--strict-mcp-config', '--mcp-config', config, '--tools', '', '--allowedTools', 'mcp__heimdall__*', '--output-format', 'stream-json', '--verbose', '--max-turns', '35', '-p', prompt], { cwd: h.root, env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', bytes => stdout += bytes); child.stderr.on('data', bytes => stderr += bytes);
    const timer = setTimeout(() => child.kill('SIGKILL'), 180000);
    const code = await new Promise<number | null>((resolve, reject) => { child.once('error', reject); child.once('exit', resolve); }); clearTimeout(timer);
    fs.writeFileSync(path.join(h.root, 'claude-private-transcript.jsonl'), stdout, { mode: 0o600 });
    fs.writeFileSync(path.join(h.root, 'claude-private-stderr.log'), stderr, { mode: 0o600 });
    check(code === 0, `external Claude Code exited successfully (${code})`);
    const events = stdout.split('\n').filter(Boolean).map(line => { try { return JSON.parse(line); } catch { return {}; } });
    const result = events.findLast(event => event.type === 'result');
    check(result && !result.is_error, 'external Claude returned a successful result');
    const tools = events.flatMap(event => event.message?.content ?? []).filter(item => item.type === 'tool_use').map(item => item.name);
    check(tools.some(name => /tasks[._]create$/.test(name)), 'external Claude invoked native MCP task creation');
    check(tools.some(name => /artifacts[._]get$/.test(name)), 'external Claude invoked MCP artifact retrieval');
    check(String(result.result).includes('MCP_CLAUDE_OFFLOAD_OK'), 'external Claude returned actual artifact marker');
    return { tools, result: String(result.result) };
  } finally { fs.rmSync(config, { force: true }); }
}
