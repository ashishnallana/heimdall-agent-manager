// Real native HTTP and Bridge runtime acceptance; synthetic account/vault only.
// Optional real model execution uses the caller's explicitly selected Codex home.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { nativeMcpHub, check, eventually } from '../helpers/nativeMcpAcceptance.ts';
import { claudeMcpAcceptance } from '../helpers/claudeMcpAcceptance.ts';
import { remoteMcpBridge } from '../helpers/remoteMcpBridge.ts';

const scope = 'mcp:chains mcp:tasks:read mcp:tasks:write mcp:agents:read mcp:agents:write mcp:instances:read mcp:instances:control mcp:memories:read mcp:memories:write mcp:projects:read mcp:projects:write mcp:issues:read mcp:issues:write mcp:artifacts:read mcp:artifacts:write';
async function main() {
  const h = await nativeMcpHub();
  const report: Record<string, unknown> = { kind: 'isolated-native-http', production: false, actual_model_execution: false, external_claude: false, physical_machines: 1 };
  report.native_binaries = Object.fromEntries(['HUB', 'BRIDGE'].map(kind => [kind.toLowerCase(), createHash('sha256').update(fs.readFileSync(process.env[`HEIMDALL_E2E_${kind}_BIN`]!)).digest('hex')]));
  let remote: Awaited<ReturnType<typeof remoteMcpBridge>> | undefined;
  try {
    let bridge: any = await h.enroll();
    check((await h.signed('POST', `/api/v1/bridges/${bridge.bridgeId}/providers/discover`, { providers: ['codex'], stage: 'providers' })).status === 200, 'native Codex provider discovery');
    const hosted = await h.grant(scope);
    const legacy = await h.grant('mcp:chains');
    const device = await h.grant(scope, 'device');
    const tools = await h.rpc(hosted, 'tools/list'); check(tools.json.result.tools.length === 46, 'expanded grant exposes 46 tools');
    const oldTools = await h.rpc(legacy, 'tools/list'); check(oldTools.json.result.tools.length === 4, 'legacy grant still exposes only four tools');
    const denied = await h.rpc(legacy, 'tools/call', { name: 'artifacts.list', arguments: {} }); check(denied.json.result?.isError && denied.json.result.content[0].text === 'scope_missing', 'legacy grant cannot read artifacts');
    const deviceTools = await h.rpc(device, 'tools/list'); check(deviceTools.json.result.tools.length === 46, 'device grant retains signed scope');
    const bridges = await h.tool(hosted, 'bridges.list', {}); check(bridges.records.some((r: any) => r.bridge_id === bridge.bridgeId && r.eligible), 'MCP discovers real enrolled Bridge');
    let providers = await h.tool(hosted, 'providers.list', { bridge_id: bridge.bridgeId });
    check(!providers.records.find((r: any) => r.provider === 'codex')?.eligible, 'unchecked/disabled provider is not eligible');
    if (process.env.HEIMDALL_E2E_LIVE_RUNTIME === '1') {
      check((await h.signed('PUT', `/api/v1/bridges/${bridge.bridgeId}/providers/codex`, { enabled: true })).status === 200, 'synthetic account explicitly enables its Codex provider');
      providers = await h.tool(hosted, 'providers.list', { bridge_id: bridge.bridgeId });
    }
    report.providers = providers.records.map((r: any) => ({ provider: r.provider, provider_profile: r.provider_profile, eligible: r.eligible, detection_state: r.detection_state, models_state: r.models_state, models: r.models.filter((m: any) => m.eligible).map((m: any) => m.model_id) }));
    console.log('PROVIDERS ' + JSON.stringify(report.providers));
    const c = await h.tool(hosted, 'chains.create', { title: 'Disposable MCP acceptance', description: 'Synthetic task/result test; no production data.' });
    const chainId = c.chain_id; check(typeof chainId === 'string', 'MCP creates chain over authenticated HTTP');
    const created = await h.tool(hosted, 'artifacts.create', { request_id: 'http-artifact', name: 'result.md', content_type: 'text/markdown', content: '# Synthetic result\nVerified.', chain_id: chainId });
    const read = await h.tool(hosted, 'artifacts.get', { artifact_id: created.resource_id }); check(read.records[0].content === '# Synthetic result\nVerified.' && read.records[0].link === created.link, 'HTTP encrypted artifact roundtrip and stable link');
    const replay = await h.tool(hosted, 'artifacts.create', { request_id: 'http-artifact', name: 'result.md', content_type: 'text/markdown', content: '# Synthetic result\nVerified.', chain_id: chainId });
    check(JSON.stringify(replay) === JSON.stringify(created), 'HTTP mutation replay is stable');
    const deviceRead = await h.tool(device, 'artifacts.get', { artifact_id: created.resource_id });
    check(deviceRead.records[0].content === '# Synthetic result\nVerified.', 'device grant decrypts via real approved Bridge');
    const foreign = await h.foreignRequest('POST', '/api/v1/projects', { name: 'Other synthetic owner', slug: 'foreign-synthetic', default_path: path.join(h.root, 'foreign-project') });
    check(foreign.status === 201 && foreign.data.project_id, 'second synthetic owner creates private project (' + foreign.status + ' ' + (foreign.data.error?.message || foreign.data.message || '') + ')');
    const foreignRead = await h.rpc(hosted, 'tools/call', { name: 'projects.get', arguments: { project_id: foreign.data.project_id } });
    check(foreignRead.json.result?.isError && foreignRead.json.result.content[0].text === 'not_found', 'foreign resource denied without content disclosure');
    report.chain_id = chainId; report.bridge_id = bridge.bridgeId; report.artifact_id = created.resource_id;
    if (process.env.HEIMDALL_E2E_REMOTE_BRIDGE) {
      remote = await remoteMcpBridge(h); bridge = remote;
      check((await h.signed('POST', `/api/v1/bridges/${bridge.bridgeId}/providers/discover`, { providers: ['codex'], stage: 'providers' })).status === 200, 'remote native provider discovery');
      check((await h.signed('PUT', `/api/v1/bridges/${bridge.bridgeId}/providers/codex`, { enabled: true })).status === 200, 'synthetic remote provider explicitly enabled');
      providers = await h.tool(hosted, 'providers.list', { bridge_id: bridge.bridgeId });
      Object.assign(report, { physical_machines: 2, execution_machine: remote.physicalHostname, execution_bridge_id: remote.bridgeId });
    }
    if (process.env.HEIMDALL_E2E_LIVE_RUNTIME === '1') {
      const eligible = providers.records.find((r: any) => r.provider === 'codex' && r.eligible);
      check(eligible, 'eligible real Codex provider available');
      const model = process.env.HEIMDALL_E2E_MODEL || eligible.models.find((m: any) => m.eligible)?.model_id;
      check(model, 'explicit or discovered eligible model available');
      const work = remote?.projectDir || path.join(h.root, 'project'); if (!remote) fs.mkdirSync(work);
      const project = await h.tool(hosted, 'projects.create', { request_id: 'project', name: 'Synthetic acceptance', default_path: work });
      const agent = await h.tool(hosted, 'agents.create', { request_id: 'agent', name: 'MCP acceptance worker', instructions: 'You are a disposable acceptance worker. On EVERY launch or relaunch, FIRST signal native readiness with ./.heimdall/bin/ham-ctl start-success, even if no task is ready. Then read AGENTS.md and TASK.md. Pull your task with ./.heimdall/bin/ham-ctl lease next. Complete its small synthetic job, create its requested Markdown artifact through ham-ctl artifact create, then lease submit. Never touch production accounts, other directories or user data. Wait for a task if none is ready.', supports: [{ bridge_id: bridge.bridgeId, enabled: true, max_instances: 1 }] });
      const chain = await h.tool(hosted, 'chains.get', { chain_id: chainId });
      await h.tool(hosted, 'chains.configure', { chain_id: chainId, request_id: 'fleet', expected_revision: chain.chain.configuration_revision, action: 'fleet', agent_id: agent.agent_id, bridge_id: bridge.bridgeId, provider: eligible.provider, provider_profile: eligible.provider_profile, model, capacity: 1, roles: ['worker'] });
      const barrier = path.join(work, '.controller-ready');
      const controllerMode = process.env.HEIMDALL_E2E_CLAUDE_CLIENT === '1';
      const task = await h.tool(hosted, 'tasks.create', { chain_id: chainId, request_id: 'task', title: 'Write synthetic acceptance result', goal: 'Create a Markdown artifact named acceptance-result.md containing exactly MCP_NATIVE_OFFLOAD_OK. Associate it with this task and chain using ham-ctl artifact create flags. Submit the lease with the artifact:// link in the summary. All files belong only in this disposable project directory.' + (controllerMode ? ` Before submitting, wait at most 90 seconds for the test coordinator to create ${barrier}; use ham-ctl shell run for this bounded wait. This barrier lets a second real task queue before native idle shutdown.` : ''), acceptance: ['Artifact content equals MCP_NATIVE_OFFLOAD_OK and native task lease is submitted.'], assignee_agent_id: agent.agent_id, bridge_id: bridge.bridgeId, requires_user_approval: false });
      const definition = await h.tool(hosted, 'agents.get', { agent_id: agent.agent_id });
      const unsupported = await h.rpc(hosted, 'tools/call', { name: 'instances.create', arguments: { agent_id: agent.agent_id, chain_id: chainId, project_id: project.resource_id, bridge_id: bridge.bridgeId, provider: eligible.provider, provider_profile: eligible.provider_profile, model: 'unsupported-acceptance-model', request_id: 'unsupported-runtime', expected_revision: definition.records[0].revision } });
      check(unsupported.json.result?.isError && unsupported.json.result.content[0].text === 'invalid_arguments', 'unsupported model denied before native launch');
      const runtime = await h.tool(hosted, 'instances.create', { agent_id: agent.agent_id, chain_id: chainId, project_id: project.resource_id, bridge_id: bridge.bridgeId, provider: eligible.provider, provider_profile: eligible.provider_profile, model, request_id: 'runtime', expected_revision: definition.records[0].revision });
      check(runtime.agent_instance_id, 'real instance create accepted');
      const configured = await h.tool(hosted, 'chains.get', { chain_id: chainId });
      await h.tool(hosted, 'chains.configure', { chain_id: chainId, action: 'publish', request_id: 'publish', expected_revision: configured.chain.configuration_revision });
      const clientPromise = controllerMode ? claudeMcpAcceptance(h, hosted, chainId, agent.agent_id, bridge.bridgeId, runtime.agent_instance_id) : undefined;
      // Do not let a rejected model call become an unhandled rejection while
      // the native first task is still waiting at its bounded test barrier.
      clientPromise?.catch(() => {});
      let barrierReleased = false;
      console.log('RUNTIME ' + JSON.stringify({ task_id: task.task_id, agent_id: agent.agent_id, agent_instance_id: runtime.agent_instance_id, model }));
      const completed = await eventually(async () => {
        if (controllerMode && !barrierReleased) {
          const queued = await h.tool(hosted, 'tasks.list', { chain_id: chainId });
          if (queued.tasks.some((row: any) => row.title === 'Claude-controlled acceptance')) { if (remote) await remote.releaseBarrier(); else fs.writeFileSync(barrier, 'ready', { mode: 0o600 }); barrierReleased = true; }
        }
        const detail = await h.tool(hosted, 'tasks.get', { chain_id: chainId, task_id: task.task_id });
        const row = detail.tasks[0];
        if (row.state === 'done' || row.state === 'in_review') return row;
        if (row.blocked_kind) console.log('TASK_STATE ' + JSON.stringify({ state: row.state, blocked_kind: row.blocked_kind }));
        return undefined;
      }, 'actual provider task completion', 180000);
      check(completed.latest_attempt_no >= 1, 'native task acquired and submitted by real process');
      const artifacts = await h.tool(hosted, 'artifacts.list', { task_id: task.task_id });
      check(artifacts.records?.length > 0, 'task-produced artifact associated with task');
      const result = await h.tool(hosted, 'artifacts.get', { artifact_id: artifacts.records[0].artifact_id });
      check(result.records[0].content.trim() === 'MCP_NATIVE_OFFLOAD_OK', 'real offload artifact retrieved through MCP');
      await h.tool(hosted, 'tasks.comment', { chain_id: chainId, task_id: task.task_id, request_id: 'acceptance-comment', body: 'Verified real encrypted task result through MCP.' });
      const commented = await h.tool(hosted, 'tasks.get', { chain_id: chainId, task_id: task.task_id, include_comments: true });
      check(commented.comments.some((row: any) => row.body === 'Verified real encrypted task result through MCP.'), 'task comment write/read roundtrip');
      Object.assign(report, { actual_model_execution: true, task_id: task.task_id, agent_id: agent.agent_id, agent_instance_id: runtime.agent_instance_id, result_artifact_id: result.records[0].artifact_id, task_state: completed.state, model });
      if (clientPromise) {
        const client = await clientPromise;
        const tasks = await h.tool(hosted, 'tasks.list', { chain_id: chainId });
        const controlled = tasks.tasks.find((row: any) => row.title === 'Claude-controlled acceptance');
        check(controlled?.state === 'done', 'Claude-created task actually completed in native task system');
        const files = await h.tool(hosted, 'artifacts.list', { task_id: controlled.task_id });
        const artifact = await h.tool(hosted, 'artifacts.get', { artifact_id: files.records[0].artifact_id });
        check(artifact.records[0].content.trim() === 'MCP_CLAUDE_OFFLOAD_OK', 'independent verification of Claude-controlled real result');
        Object.assign(report, { external_claude: true, claude_task_id: controlled.task_id, claude_artifact_id: artifact.records[0].artifact_id, claude_tools: client.tools });
      }
      const moveModel = process.env.HEIMDALL_E2E_MOVE_MODEL;
      if (moveModel) {
        const source = await h.tool(hosted, 'instances.get', { agent_instance_id: runtime.agent_instance_id });
        await h.tool(hosted, 'instances.reconfigure', { agent_instance_id: runtime.agent_instance_id, bridge_id: bridge.bridgeId, project_id: project.resource_id, provider: eligible.provider, provider_profile: eligible.provider_profile, model: moveModel, request_id: 'actual-model-move', expected_revision: source.records[0].revision });
        const moved = await eventually(async () => {
          const operation = await h.tool(hosted, 'instances.operations', { operation_tool: 'instances.reconfigure', request_id: 'actual-model-move' });
          if (operation.status === 'completed') return operation;
          if (operation.status === 'failed' || operation.status === 'repair_required') throw new Error('Real model move: ' + operation.status + ' ' + operation.phase);
          return undefined;
        }, 'actual native model move readiness', 90000);
        const destination = await h.tool(hosted, 'instances.get', { agent_instance_id: runtime.agent_instance_id });
        check(destination.records[0].model === moveModel, 'native model move reaches requested destination');
        Object.assign(report, { model_move: { model: moveModel, status: moved.status } });
      }
      const current = await h.tool(hosted, 'instances.get', { agent_instance_id: runtime.agent_instance_id });
      await h.tool(hosted, 'instances.stop', { agent_instance_id: runtime.agent_instance_id, request_id: 'stop', expected_revision: current.records[0].revision });
      await eventually(async () => {
        const operation = await h.tool(hosted, 'instances.operations', { operation_tool: 'instances.stop', request_id: 'stop' });
        return operation.status === 'completed' ? operation : undefined;
      }, 'native stop completion');
      if (remote) await remote.close(); else bridge.runtime.kill();
      await eventually(async () => {
        const rows = await h.tool(hosted, 'bridges.list', {});
        return rows.records.some((row: any) => row.bridge_id === bridge.bridgeId && !row.eligible) ? true : undefined;
      }, 'disposable execution Bridge offline');
      const stopped = await h.tool(hosted, 'instances.get', { agent_instance_id: runtime.agent_instance_id });
      const offline = await h.rpc(hosted, 'tools/call', { name: 'instances.start', arguments: { agent_instance_id: runtime.agent_instance_id, request_id: 'offline-start', expected_revision: stopped.records[0].revision } });
      check(offline.json.result?.isError && offline.json.result.content[0].text === 'bridge_offline', 'offline target denied without fallback launch');
      report.offline_target_denied = true;
    }
    console.log('REPORT ' + JSON.stringify(report));
    fs.writeFileSync(path.join(h.root, 'report.json'), JSON.stringify(report, null, 2), { mode: 0o600 });
  } finally { if (remote) await remote.close(); await h.close(); }
}
main().catch(error => { console.error('FAIL ' + error.message); process.exit(1); });
