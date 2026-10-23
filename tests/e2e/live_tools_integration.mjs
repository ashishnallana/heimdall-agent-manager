// Fresh real Hub/Bridge/CLI, with an explicitly synthetic provider process.
// Canonical provider events are injected; no provider-native execution is claimed.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync, spawn } from 'node:child_process';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const WebSocket = require('ws');
const root = path.resolve(process.env.LIVE_TOOLS_EVIDENCE);
const bin = path.resolve(process.env.LIVE_TOOLS_BIN);
const local = path.join(root, 'local');
const env = { ...process.env, HEIMDALL_LOCAL_STATE_ROOT: local, PATH: root + ':' + process.env.PATH,
  HEIMDALL_HAM_PTY_HOST_BIN: process.env.LIVE_TOOLS_PTY, HEIMDALL_BRIDGE_PTY_HOST: '1' };
const proxy = 'http://127.0.0.1:18680';
const hub = 'http://127.0.0.1:18681';
const db = path.join(local, 'hubs/b3/hub.db');
fs.mkdirSync(root, {recursive: true, mode: 0o700});
let evidence;
evidence = { head: run('git', ['rev-parse', 'HEAD']).trim(), provider_evidence: 'injected canonical ham.ext.v1; synthetic idle provider, no native provider claim', checks: [], commands: [], snapshots: [] };
function run(cmd, args, options = {}) {
  const r = spawnSync(cmd, args, { env, encoding: 'utf8', timeout: 90_000, ...options });
  evidence?.commands.push({cmd, args, exit_code: r.status});
  if (r.status !== 0) throw new Error(`${cmd} ${args.join(' ')}: ${r.status}\n${r.stdout}\n${r.stderr}`);
  return r.stdout;
}
function sql(source, params = []) {
  return JSON.parse(run('python3', ['-c', 'import sqlite3,json,sys; c=sqlite3.connect(sys.argv[1]); r=c.execute(sys.argv[2],json.loads(sys.argv[3])); print(json.dumps(r.fetchall())); c.commit()', db, source, JSON.stringify(params)]));
}
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function wait(fn, label, timeout = 20000) {
  for (const deadline = Date.now() + timeout;;) {
    const result = await fn(); if (result) return result;
    if (Date.now() > deadline) throw new Error(`timeout: ${label}`);
    await sleep(150);
  }
}
async function api(method, route, body, user = 'tanmay') {
  const r = await fetch(proxy + '/api/v1' + route, {method, headers: {'Content-Type': 'application/json', 'X-Dev-User': user}, body: body === undefined ? undefined : JSON.stringify(body)});
  const text = await r.text(); let value; try { value = JSON.parse(text); } catch { value = text; }
  if (!r.ok) throw Object.assign(new Error(`${method} ${route} ${r.status}: ${text}`), {status: r.status});
  return value.data;
}
function check(label, value) { assert.ok(value, label); evidence.checks.push(label); console.log(`PASS ${label}`); }
function launcher(kind, verb, extra = []) { return run('bash', [`scripts/local-${kind}.sh`, verb, '--name', 'b3', ...extra]); }
const sockets = [];
async function stream(user) {
  const frames = [];
  const ticket = await api('POST', '/me/ws-ticket', {}, user);
  const socket = new WebSocket(hub.replace('http:', 'ws:') + '/api/v1/user-ws?ticket=' + encodeURIComponent(ticket.ticket), {headers: {Origin: 'http://127.0.0.1:15673'}});
  sockets.push(socket);
  socket.on('message', bytes => { try { const v = JSON.parse(bytes); frames.push(v); fs.appendFileSync(path.join(root, `${user}-ws.jsonl`), JSON.stringify(v) + '\n'); } catch {} });
  await new Promise((resolve, reject) => { socket.once('open', resolve); socket.once('error', reject); });
  return { socket, frames };
}
let bridge;
const instances = [];
try {
  console.log(launcher('hub', 'start', ['--hub-port', '18681', '--proxy-port', '18680', '--ui-port', '15673', '--user', 'tanmay', '--no-ui', '--no-plan-limits', '--bin-dir', bin]));
  const fixture = path.join(root, 'fixture-provider');
  fs.writeFileSync(fixture, `#!/usr/bin/env python3\nimport os,sys,json,subprocess,time\nif '--version' in sys.argv:\n print('codex-cli 0.162.0');sys.exit()\nif 'plugin' in sys.argv:\n print('{"installed":[],"available":[]}');sys.exit()\np=${JSON.stringify(root)}\ni=os.environ.get('HEIMDALL_AGENT_INSTANCE_ID','unknown')\nopen(p+'/'+i+'.env.json','w').write(json.dumps({k:v for k,v in os.environ.items() if k.startswith('HEIMDALL_')}))\nsubprocess.run([${JSON.stringify(path.join(bin, 'ham-ctl'))},'start-success'])\nprint('Synthetic provider ready',flush=True)\nwhile True:time.sleep(1)\n`, {mode: 0o700});
  sql("UPDATE provider_catalog SET binary=?, base_args='[]', yolo_args='[]', ask_args='[]', extension='{}' WHERE provider='codex'", [path.basename(fixture)]);
  sql("UPDATE provider_catalog_meta SET catalog_etag='b3-synthetic-provider'");
  console.log(launcher('bridge', 'start', ['--hub', 'b3', '--auto-enroll', '--port', '49681', '--local-endpoint-port', '49682', '--bin-dir', bin, '--pty-host-bin', process.env.LIVE_TOOLS_PTY]));
  bridge = (await api('GET', '/bridges')).find(x => x.machine_hostname || x.bridge_id);
  evidence.discovery = await api('POST', `/bridges/${bridge.bridge_id}/providers/discover`, {});
  await api('PUT', `/bridges/${bridge.bridge_id}/providers/codex`, {enabled: true});
  const agent = await api('POST', '/agents', {name: 'B3 synthetic fixture', slug: 'b3-fixture', instructions: 'Integration fixture only'});
  const chain = await api('POST', '/task-chains', {title: 'B3 live tools integration'});
  const model = sql("SELECT model_id FROM provider_models WHERE provider='codex' AND state='active' ORDER BY rank LIMIT 1")[0][0];
  for (const name of ['A', 'B']) {
    const inst = await api('POST', '/agent-instances', {agent_id: agent.agent_id, bridge_id: bridge.bridge_id, provider: 'codex', model, display_name: name, chain_id: chain.chain_id});
    instances.push(inst);
    const file = path.join(root, `${inst.agent_instance_id}.env.json`);
    await wait(() => fs.existsSync(file), 'synthetic process launch');
    inst.env = {...env, ...JSON.parse(fs.readFileSync(file))};
    await wait(async () => (await api('GET', `/agent-instances/${inst.agent_instance_id}`)).runtime_status === 'running', 'instance ready');
  }
  console.log('STACK_READY', instances.map(x => x.agent_instance_id));
  fs.writeFileSync(path.join(root, 'setup.json'), JSON.stringify({bridge_id: bridge.bridge_id, instances: instances.map(({env, ...x}) => x), chain_id: chain.chain_id}, null, 2));
  const owner = await stream('tanmay');
  const foreign = await stream('paid');
  const snapshot = async (inst = instances[0]) => {
    const value = await api('GET', `/agent-instances/${inst.agent_instance_id}/tool-activity-live`);
    evidence.snapshots.push(value); return value;
  };
  const event = (kind, id, session = 'b3-session', extra = {}) => ({schema: 'ham.ext.v1', provider: 'codex', event: kind, ts: new Date().toISOString(), session_id: session, tool: {name: 'Read', use_id: id}, payload: {}, ...extra});
  function inject(inst, events) {
    const out = run(path.join(bin, 'ham-ctl'), ['extension', 'event', '--stdin'], {env: inst.env, input: JSON.stringify(Array.isArray(events) ? {events} : events)});
    assert.match(out, /"ok":true/); return out;
  }
  for (const type of ['tool_activity', 'shell_run']) {
    sql(`INSERT INTO chat_messages (message_id,conversation_id,owner_user_id,direction,body,created_at,message_type)
      SELECT ?,conversation_id,owner_user_id,'agent_to_user','historical fixture','2020-01-01T00:00:00Z',?
      FROM chat_conversations WHERE agent_instance_id=? LIMIT 1`, ['b3-history-' + type, type, instances[0].agent_instance_id]);
  }
  evidence.historical_before = sql("SELECT * FROM chat_messages WHERE message_id LIKE 'b3-history-%' ORDER BY message_id");
  check('historical tool and shell marker fixtures stored before lifecycle', evidence.historical_before.length === 2);
  const before = sql('SELECT message_type, COUNT(*) FROM chat_messages GROUP BY message_type');
  evidence.db_before = before;
  await sleep(1100); // source cutoff is millisecond precision; no boot-second ambiguity
  const started = event('tool.start', 'call-a'); inject(instances[0], started);
  await wait(() => owner.frames.find(f => JSON.stringify(f).includes('call-a') && JSON.stringify(f).includes('tool_activity_live')), 'owner live start without chat fetch');
  check('owner WS start arrives before completion without chat fetch', true);
  check('snapshot sees running provider', (await snapshot()).active.length === 1);
  inject(instances[0], started);
  inject(instances[0], event('tool.start', 'call-b'));
  inject(instances[1], event('tool.start', 'call-c'));
  check('duplicate starts and concurrent calls remain separate', (await snapshot()).active.length === 2 && (await snapshot(instances[1])).active.length === 1);
  const page = await api('GET', `/task-chains/${chain.chain_id}/tool-activity-live`);
  evidence.chain_snapshot = page;
  check('chain snapshot has both identities', page.members.length === 2);
  await sleep(120);
  const ended = event('tool.end', 'call-a'); inject(instances[0], ended);
  inject(instances[0], ended); inject(instances[0], started);
  const completion = await snapshot();
  check('end removes active call, last duration only, retry/reorder cannot resurrect', completion.active.length === 1 && completion.last_completion?.duration_ms >= 0);
  inject(instances[0], event('tool.end', 'call-b'));
  inject(instances[1], event('tool.end', 'call-c'));
  await wait(async () => (await snapshot()).active.length === 0, 'final completion');
  check('final one-to-zero clears active list', true);
  check('foreign owner receives no call content', !foreign.frames.some(f => JSON.stringify(f).includes('call-a')));
  const denied = await fetch(proxy + `/api/v1/agent-instances/${instances[0].agent_instance_id}/tool-activity-live`, {headers: {'X-Dev-User': 'paid'}});
  check('foreign owner snapshot denied', denied.status === 404);
  const call = (inst, args) => run(path.join(bin, 'ham-ctl'), args, {env: inst.env});
  const shell = JSON.parse(call(instances[0], ['shell', 'run', '--cmd', 'echo b3-output; sleep 3', '--bg', '--cwd', root]));
  evidence.shell_start = shell;
  const shellId = shell.data?.session?.session_id || shell.data?.data?.session?.session_id;
  assert.ok(shellId, JSON.stringify(shell));
  check('real ham-ctl shell run is visible', (await snapshot()).active.some(x => x.shell_session_id === shellId));
  await wait(async () => !(await snapshot()).active.some(x => x.shell_session_id === shellId), 'real shell completion');
  evidence.shell_log = call(instances[0], ['shell', 'log', shellId]);
  check('operational shell log remains readable', evidence.shell_log.includes('b3-output'));
  const activeShell = JSON.parse(call(instances[0], ['shell', 'run', '--cmd', 'sleep 60', '--bg', '--cwd', root]));
  const activeId = activeShell.data?.session?.session_id || activeShell.data?.data?.session?.session_id;
  check('operational shell kill works', !!call(instances[0], ['shell', 'kill', activeId]));
  await wait(async () => (await snapshot()).active.length === 0, 'killed shell removes running call');
  // Reconnect fetch is a one-shot read of live Bridge memory.
  await sleep(150);
  evidence.ui_frames = owner.frames.filter(f => f.type === 'tool_activity_live');
  owner.socket.close(); const reconnected = await stream('tanmay');
  check('reconnect snapshot does not replay completed tools', (await snapshot()).active.length === 0);
  inject(instances[0], event('tool.start', 'stale-session'));
  inject(instances[0], event('session', '', 'b3-session', {payload: {phase: 'end'}}));
  check('session end clears active calls', (await snapshot()).active.length === 0);
  inject(instances[0], event('session', '', 'b3-next', {payload: {phase: 'start'}}));
  inject(instances[0], started);
  check('old-session replay cannot repopulate new session', (await snapshot()).active.length === 0);
  inject(instances[0], event('subagent.start', '', 'b3-next', {agent: {id: 'b3-child', type: 'Explore'}}));
  inject(instances[0], event('file.edit', 'edit-one', 'b3-next', {agent: {id: 'b3-child', type: 'Explore'}, tool: {name: 'Edit', use_id: 'edit-one', input: {file_path: '/fixture/b3.txt'}}, payload: {file_path: '/fixture/b3.txt', diff: '-before\n+after'}}));
  await wait(async () => JSON.stringify(await api('GET', `/agent-instances/${instances[0].agent_instance_id}/extension/files`)).includes('/fixture/b3.txt'), 'separate files projection');
  check('separate extension files retains edit projection', true);
  check('separate extension subagents retains child projection', JSON.stringify(await api('GET', `/agent-instances/${instances[0].agent_instance_id}/extension/subagents`)).includes('b3-child'));
  const permission = spawn(path.join(bin, 'ham-ctl'), ['extension', 'hook', 'claude'], {env: {...instances[0].env, HEIMDALL_EXT_PERMISSION_TIMEOUT_MS: '15000'}, stdio: ['pipe', 'pipe', 'pipe']});
  let permissionOut = ''; permission.stdout.on('data', b => permissionOut += b);
  const permissionDone = new Promise(resolve => permission.once('exit', resolve));
  permission.stdin.end(JSON.stringify({hook_event_name: 'PermissionRequest', session_id: 'b3-next', tool_name: 'Bash', tool_use_id: 'permission-one', tool_input: {command: 'echo permission-fixture'}}));
  const blockers = await wait(async () => { const b = await api('GET', `/agent-instances/${instances[0].agent_instance_id}/blockers`); return b.blockers?.length ? b : false; }, 'permission blocker');
  evidence.permission_blockers = blockers;
  await api('POST', `/agent-instances/${instances[0].agent_instance_id}/blockers/${blockers.blockers[0].blocker_id}/resolve`, {decision: 'allow', message: 'B3 integration fixture'});
  await permissionDone;
  check('separate permission decision reaches waiting hook', permissionOut.includes('allow'));
  const timeline = await api('GET', `/agent-instances/${instances[0].agent_instance_id}/extension/events`);
  evidence.timeline = timeline;
  check('backend extension event history remains available', JSON.stringify(timeline).includes('tool.start'));
  for (const feature of ['files', 'subagents']) check(`separate extension ${feature} endpoint remains available`, !!(await api('GET', `/agent-instances/${instances[0].agent_instance_id}/extension/${feature}`)));
  const bridgeToken = fs.readFileSync(path.join(local, 'bridges/b3/credentials/bridge-token'), 'utf8').trim().split(/\r?\n/).at(-1);
  const legacy = await fetch(hub + '/api/v1/agent-actions/tool-activity', {method: 'POST', headers: {'Content-Type': 'application/json', Authorization: 'Bearer ' + bridgeToken}, body: JSON.stringify({agent_instance_id: instances[0].agent_instance_id, params: {body: 'legacy retry', metadata: {calls: []}}})});
  evidence.legacy = {status: legacy.status, body: await legacy.json()};
  check('legacy authenticated tool activity POST is no-op', legacy.status === 200 && JSON.stringify(evidence.legacy).includes('"persisted":false'));
  evidence.db_after = sql('SELECT message_type, COUNT(*) FROM chat_messages GROUP BY message_type');
  check('zero new tool_activity and shell_run conversation rows', ['tool_activity', 'shell_run'].every(type => (evidence.db_after.find(x => x[0] === type)?.[1] || 0) === (before.find(x => x[0] === type)?.[1] || 0)));
  inject(instances[0], event('tool.start', 'restart-active', 'b3-next'));
  check('restart fixture has active Bridge source state', (await snapshot()).active.length === 1);
  console.log(launcher('hub', 'stop')); console.log(launcher('hub', 'start', ['--no-ui', '--no-plan-limits', '--bin-dir', bin]));
  await wait(async () => { try { return (await snapshot()).availability === 'ready'; } catch { return false; } }, 'Hub restart Bridge reconnect', 30000);
  const restored = await snapshot();
  check('Hub restart recovers still-active Bridge source without replaying finished tools or shell rows', restored.active.length === 1 && restored.active[0].tool_use_id === 'restart-active');
  inject(instances[0], event('tool.end', 'restart-active', 'b3-next'));
  check('recovered active call completes normally', (await snapshot()).active.length === 0);
  const lifecycle = await stream('tanmay');
  inject(instances[0], event('tool.start', 'stop-active', 'b3-next'));
  check('stop fixture has an active call', (await snapshot()).active.length === 1);
  for (const inst of instances) await api('POST', `/agent-instances/${inst.agent_instance_id}/stop`, {});
  await wait(async () => (await api('GET', `/agent-instances/${instances[0].agent_instance_id}`)).runtime_status === 'stopped', 'asynchronous agent stop');
  await wait(() => lifecycle.frames.some(f => f.type === 'tool_activity_live_unavailable' && f.instance_id === instances[0].agent_instance_id), 'stop unavailable fence');
  try { check('agent stop returns empty source snapshot', (await snapshot()).active.length === 0); }
  catch (error) { check('agent stop fences unavailable source with bridge_offline', error.status === 409); evidence.stop_snapshot_status = error.status; }
  const oldToken = instances[0].env.HEIMDALL_AGENT_TOKEN;
  const launchFrames = await stream('tanmay');
  await api('POST', `/agent-instances/${instances[0].agent_instance_id}/start`, {});
  await wait(() => {
    const fresh = JSON.parse(fs.readFileSync(path.join(root, `${instances[0].agent_instance_id}.env.json`)));
    if (fresh.HEIMDALL_AGENT_TOKEN === oldToken) return false;
    instances[0].env = {...env, ...fresh}; return true;
  }, 'actual relaunch token generation');
  await wait(() => launchFrames.frames.some(f => f.type === 'tool_activity_live_resync'), 'actual relaunch resync hint');
  await wait(async () => (await api('GET', `/agent-instances/${instances[0].agent_instance_id}`)).runtime_status === 'running', 'relaunch ready');
  check('actual relaunch emits resync and snapshot starts empty', (await snapshot()).active.length === 0);
  inject(instances[0], event('session', '', 'b3-relaunched', {payload: {phase: 'start'}}));
  inject(instances[0], event('tool.start', 'bridge-restart-active', 'b3-relaunched'));
  check('Bridge restart fixture has active volatile state', (await snapshot()).active.length === 1);
  console.log(launcher('bridge', 'stop'));
  console.log(launcher('bridge', 'start', ['--hub', 'b3', '--bin-dir', bin, '--pty-host-bin', process.env.LIVE_TOOLS_PTY]));
  await wait(async () => { try { return (await snapshot()).availability === 'ready'; } catch { return false; } }, 'Bridge process restart fresh source', 30000);
  check('Bridge process restart starts empty without replaying historical tool or shell rows', (await snapshot()).active.length === 0);
  evidence.db_final = sql('SELECT message_type, COUNT(*) FROM chat_messages GROUP BY message_type');
  check('all restart and relaunch paths still create zero tool/shell messages', ['tool_activity', 'shell_run'].every(type => (evidence.db_final.find(x => x[0] === type)?.[1] || 0) === (before.find(x => x[0] === type)?.[1] || 0)));
  evidence.historical_after = sql("SELECT * FROM chat_messages WHERE message_id LIKE 'b3-history-%' ORDER BY message_id");
  check('historical marker rows remain byte-for-byte unchanged', JSON.stringify(evidence.historical_before) === JSON.stringify(evidence.historical_after));
  evidence.status = 'pass';
} catch (error) { evidence.status = 'fail'; evidence.error = error.stack; console.error(error); process.exitCode = 1; }
finally {
  for (const socket of sockets) socket.terminate();
  for (const inst of instances) { try { await api('POST', `/agent-instances/${inst.agent_instance_id}/stop`, {}); } catch {} }
  for (const kind of ['bridge', 'hub']) { try { console.log(launcher(kind, 'stop')); } catch (error) { console.error(error.message); } }
  // Enrollment briefly starts its own bridge-scoped host before the runtime
  // switches to the isolated endpoint directory. Stop only our newly minted ID.
  if (bridge) {
    const socket = `/tmp/heimdall-bridge-local/pty-host-${bridge.bridge_id}.sock`;
    try { evidence.pty_cleanup = run(process.env.LIVE_TOOLS_PTY, ['--socket', socket, 'stop']); } catch (error) { console.error(error.message); }
  }
  for (const inst of instances) fs.rmSync(path.join(root, `${inst.agent_instance_id}.env.json`), {force: true});
  fs.writeFileSync(path.join(root, 'manifest.json'), JSON.stringify(evidence, null, 2));
  console.log('EVIDENCE', path.join(root, 'manifest.json'));
}
