// Fresh real Hub/Bridge/CLI, with an explicitly synthetic provider process.
// Canonical provider events are injected; no provider-native execution is claimed.
import fs from 'node:fs';
import net from 'node:net';
import { performance } from 'node:perf_hooks';
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
evidence = { kind: 'tool-stream-ui-evidence', schema_version: 1, capture_source: 'isolated-backend-websocket', endpoint: '/api/v1/tool-activity/stream', backend_head: run('git', ['rev-parse', 'HEAD']).trim(), ui_head: run('git', ['rev-parse', 'HEAD']).trim(), head: run('git', ['rev-parse', 'HEAD']).trim(), provider_evidence: 'injected canonical ham.ext.v1; synthetic idle provider, no native provider claim', checks: [], commands: [], snapshots: [] };
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
async function launcher(kind, verb, extra = []) { return runAsync('bash', [`scripts/local-${kind}.sh`, verb, '--name', 'b3', ...extra]); }
const sockets = [];
async function stream(user, ids, label = user) {
  const frames = [], timed = [];
  const ticket = await api('POST', '/me/ws-ticket', {}, user);
  const socket = new WebSocket(hub.replace('http:', 'ws:') + '/api/v1/tool-activity/stream?ticket=' + encodeURIComponent(ticket.ticket), {headers: {Origin: 'http://127.0.0.1:15673'}});
  sockets.push(socket);
  socket.on('error', () => {});
  socket.on('message', bytes => {
    const frame = JSON.parse(bytes);
    frames.push(frame); timed.push({ms: performance.now(), frame});
    fs.appendFileSync(path.join(root, label + '-ws.jsonl'), JSON.stringify(timed.at(-1)) + '\n');
  });
  await new Promise((resolve, reject) => { socket.once('open', resolve); socket.once('error', reject); });
  socket.send(JSON.stringify({type: 'subscribe', instance_ids: ids}));
  return {socket, frames, timed, label};
}
async function runAsync(cmd, args, options = {}) {
  const p = spawn(cmd, args, {env, ...options});
  let stdout = '', stderr = '';
  p.stdout.on('data', b => stdout += b); p.stderr.on('data', b => stderr += b);
  const status = await new Promise((resolve, reject) => { p.once('exit', resolve); p.once('error', reject); });
  evidence.commands.push({cmd, args, exit_code: status});
  if (status !== 0) throw new Error(cmd + ' ' + args.join(' ') + ': ' + status + '\n' + stdout + stderr);
  return stdout;
}
// Byte-for-byte TCP pass-through: the original Hub/Bridge handshake and WS
// frames remain untouched. Parse copies only, and retain tool-stream traffic.
const upstream = [], peers = new Set(), relaySockets = new Set();
function encodeTestFrame(value) {
  const data = Buffer.from(JSON.stringify(value));
  const header = Buffer.alloc(data.length < 126 ? 6 : 8);
  header[0] = 0x81;
  if (data.length < 126) header[1] = 0x80 | data.length;
  else {header[1] = 0x80 | 126; header.writeUInt16BE(data.length, 2);}
  // Zero mask is legal; only explicitly adversarial replay probes use this.
  return Buffer.concat([header, data]);
}
function observer(direction, pair) {
  let pending = Buffer.alloc(0), headers = false, websocket = true;
  return data => {
    if (!websocket) return;
    pending = Buffer.concat([pending, data]);
    if (!headers) {
      const end = pending.indexOf('\r\n\r\n');
      if (end < 0) return;
      websocket = /upgrade: websocket/i.test(pending.subarray(0, end).toString());
      pending = pending.subarray(end + 4); headers = true;
      if (!websocket) {pending = Buffer.alloc(0); return;}
    }
    while (pending.length >= 2) {
      const opcode = pending[0] & 15, masked = !!(pending[1] & 128);
      let length = pending[1] & 127, at = 2;
      if (length === 126) {if (pending.length < 4) return; length = pending.readUInt16BE(2); at = 4;}
      else if (length === 127) {if (pending.length < 10) return; length = Number(pending.readBigUInt64BE(2)); at = 10;}
      if (pending.length < at + (masked ? 4 : 0) + length) return;
      let mask;
      if (masked) {mask = pending.subarray(at, at + 4); at += 4;}
      const payload = Buffer.from(pending.subarray(at, at + length));
      if (masked) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
      pending = pending.subarray(at + length);
      if (opcode !== 1) continue;
      try {
        const frame = JSON.parse(payload);
        pair.websocket = true;
        if (frame.type === 'bridge_ready') pair.bridge_id = frame.bridge_id || frame.payload?.bridge_id;
        if (frame.type === 'tool_stream_reset') pair.source_epoch = frame.epoch;
        if (frame.type?.startsWith('tool_stream_')) {
          const row = {ms: performance.now(), direction, frame};
          upstream.push(row);
          fs.appendFileSync(path.join(root, 'bridge-wire.jsonl'), JSON.stringify(row) + '\n');
        }
      } catch {}
    }
  };
}
const relay = net.createServer(localSocket => {
  const remote = net.connect(18681, '127.0.0.1');
  const pair = {remote, local: localSocket}; peers.add(pair);
  remote.send = value => remote.write(encodeTestFrame(JSON.parse(value)));
  remote.terminate = () => remote.destroy();
  localSocket.terminate = () => localSocket.destroy();
  for (const socket of [remote, localSocket]) {
    relaySockets.add(socket); socket.on('error', () => {});
    socket.on('close', () => {peers.delete(pair); relaySockets.delete(socket); remote.destroy(); localSocket.destroy();});
  }
  localSocket.on('data', observer('bridge-to-hub', pair));
  remote.on('data', observer('hub-to-bridge', pair));
  localSocket.pipe(remote); remote.pipe(localSocket);
});
await new Promise(resolve => relay.listen(18683, '127.0.0.1', resolve));
let bridge;
const extraBridgeIds = [];
const instances = [];
try {
  console.log(await launcher('hub', 'start', ['--hub-port', '18681', '--proxy-port', '18680', '--ui-port', '15673', '--user', 'tanmay', '--no-ui', '--no-plan-limits', '--bin-dir', bin]));
  const fixture = path.join(root, 'fixture-provider');
  fs.writeFileSync(fixture, `#!/usr/bin/env python3\nimport os,sys,json,subprocess,time\nif '--version' in sys.argv:\n print('codex-cli 0.162.0');sys.exit()\nif 'plugin' in sys.argv:\n print('{"installed":[],"available":[]}');sys.exit()\np=${JSON.stringify(root)}\ni=os.environ.get('HEIMDALL_AGENT_INSTANCE_ID','unknown')\nopen(p+'/'+i+'.env.json','w').write(json.dumps({k:v for k,v in os.environ.items() if k.startswith('HEIMDALL_')}))\nsubprocess.run([${JSON.stringify(path.join(bin, 'ham-ctl'))},'start-success'])\nprint('Synthetic provider ready',flush=True)\nwhile True:time.sleep(1)\n`, {mode: 0o700});
  sql("UPDATE provider_catalog SET binary=?, base_args='[]', yolo_args='[]', ask_args='[]', extension='{}' WHERE provider='codex'", [path.basename(fixture)]);
  sql("UPDATE provider_catalog_meta SET catalog_etag='b3-synthetic-provider'");
  console.log(await launcher('bridge', 'start', ['--hub', 'b3', '--hub-url', 'http://127.0.0.1:18683', '--auto-enroll', '--port', '49681', '--local-endpoint-port', '49682', '--bin-dir', bin, '--pty-host-bin', process.env.LIVE_TOOLS_PTY]));
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
  const [a, b] = instances.map(x => x.agent_instance_id);
  const one = await stream('tanmay', [a], 'viewer-one');
  const two = await stream('tanmay', [a], 'viewer-two');
  const three = await stream('tanmay', [b], 'viewer-three');
  const foreign = await stream('paid', [a], 'foreign-owner');
  const states = (viewer, id) => viewer.frames.filter(f => f.type === 'state' && (!id || f.instance_id === id));
  const latest = (viewer, id) => states(viewer, id).at(-1);
  const controls = (kind, id) => upstream.filter(r => r.direction === 'hub-to-bridge' && r.frame.type === kind && r.frame.instance_id === id);
  const source = id => upstream.filter(r => r.direction === 'bridge-to-hub' && r.frame.type === 'tool_stream_state' && r.frame.snapshot.instance_id === id);
  await wait(() => latest(one, a)?.baseline && latest(two, a)?.baseline && latest(three, b)?.baseline, 'three viewers empty baselines');
  check('first and additional viewers earn empty current baselines', [one, two, three].every(v => states(v).some(f => f.baseline && f.snapshot.active.length === 0 && f.snapshot.completed_since_last.length === 0)));
  check('two viewers share exactly one producer token', new Set(controls('tool_stream_attach', a).map(x => x.frame.subscription_id)).size === 1);
  check('additional viewer rebaselines existing producer without detach', controls('tool_stream_detach', a).length === 0);
  await wait(() => foreign.frames.some(f => f.type === 'error' && f.code === 'forbidden'), 'foreign-owner subscription denied');
  const event = (kind, id, extra = {}) => ({schema: 'ham.ext.v1', provider: 'codex', event: kind, ts: new Date().toISOString(), session_id: 's3-session',
    tool: {name: 'Read', use_id: id, input: {file_path: '/fixture/s3.txt', secret: 'S3_PRIVATE_INPUT_SENTINEL'}},
    payload: {output: 'S3_PRIVATE_OUTPUT_SENTINEL'}, ...extra});
  function inject(inst, events) {
    const out = run(path.join(bin, 'ham-ctl'), ['extension', 'event', '--stdin'], {env: inst.env, input: JSON.stringify(Array.isArray(events) ? {events} : events)});
    assert.match(out, /"ok":true/); return out;
  }
  const call = (inst, args) => runAsync(path.join(bin, 'ham-ctl'), args, {env: inst.env});
  evidence.db_before = sql('SELECT message_type, COUNT(*) FROM chat_messages GROUP BY message_type');
  // Two transient completions and one active call in a single source interval.
  const beforeBurst = source(a).length, burstAt = performance.now();
  inject(instances[0], [event('tool.start', 'burst-1'), event('tool.start', 'burst-2'), event('tool.start', 'running-a'),
    event('tool.end', 'burst-1'), event('tool.end', 'burst-2')]);
  inject(instances[1], event('tool.start', 'running-b'));
  await wait(() => latest(one, a)?.snapshot.completed_since_last.length >= 2 && latest(three, b)?.snapshot.active.length === 1, 'batched completion and active summaries');
  const batch = latest(one, a);
  check('burst coalesces multiple completions into one bounded transient batch', source(a).length === beforeBurst + 1 && batch.snapshot.completed_since_last.length === 2 && batch.snapshot.active.length === 1);
  await wait(() => states(two, a).some(f => JSON.stringify(f) === JSON.stringify(batch)), 'identical viewer fanout');
  check('both subscribers receive byte-identical summaries', true);
  evidence.burst_delivery_ms = performance.now() - burstAt;
  check('changed summary arrives within one-second cadence tolerance (2500ms)', evidence.burst_delivery_ms <= 2500);
  check('third viewer receives only selected instance and no A leakage', states(three).every(f => f.instance_id === b) && !JSON.stringify(three.frames).includes('running-a'));
  check('A viewers receive no B state', states(one).every(f => f.instance_id === a));
  check('foreign owner receives no state content', states(foreign).length === 0);
  check('wire contains summaries without arbitrary inputs/results', !JSON.stringify(upstream).includes('S3_PRIVATE_'));
  // Adding a viewer while active yields actual active baseline, same producer.
  const four = await stream('tanmay', [a], 'viewer-four');
  await wait(() => latest(four, a)?.baseline && latest(four, a).snapshot.active.length === 1, 'active baseline for new viewer');
  check('new active viewer shares existing producer token', new Set(controls('tool_stream_attach', a).map(x => x.frame.subscription_id)).size === 1);
  four.socket.send(JSON.stringify({type: 'subscribe', instance_ids: []}));
  const idleCount = source(a).length;
  await sleep(2200);
  check('unchanged active state emits no one-second data frames', source(a).length === idleCount);
  // Duplicate start is no visible change and produces no source state.
  inject(instances[0], event('tool.start', 'running-a'));
  await sleep(1400);
  check('duplicate/no-net-change input produces no summary frame', source(a).length === idleCount);

  // Sustained callbacks span multiple source intervals. Only the source
  // generates these frames; observing their actual send times proves cadence.
  const cadenceStart = source(a).length;
  for (let i = 0; i < 18; i++) {
    inject(instances[0], [event('tool.start', 'cadence-' + i), event('tool.end', 'cadence-' + i)]);
    await sleep(100);
  }
  await sleep(1300);
  const cadenceFrames = source(a).slice(cadenceStart).filter(r => !r.frame.baseline && !r.frame.refresh);
  evidence.changed_frame_gaps_ms = cadenceFrames.slice(1).map((r, i) => r.ms - cadenceFrames[i].ms);
  check('sustained changes coalesce at1000ms source intervals (900..2500ms tolerance)',
    cadenceFrames.length >= 2 && evidence.changed_frame_gaps_ms.every(ms => ms >= 900 && ms <= 2500));

  // A real 60-second unchanged active refresh, captured for UI consumer.
  // Keep ping/pong active; neither affects per-instance source revision.
  const ping = setInterval(() => {for (const v of [one, two, three]) if (v.socket.readyState === 1) v.socket.send('{"type":"ping"}');}, 10000);
  try {
    const beforeRefresh = latest(one, a).snapshot;
    const refresh = await wait(() => states(one, a).find(f => f.refresh), 'actual unchanged active refresh', 65000);
    check('actual active refresh retains revision and current call', refresh.snapshot.revision === beforeRefresh.revision && refresh.snapshot.active.length === 1);
    const refreshSource = source(a).find(r => r.frame.refresh);
    const priorSource = source(a).filter(r => r.ms < refreshSource.ms).at(-1);
    evidence.refresh_gap_ms = refreshSource.ms - priorSource.ms;
    check('real freshness refresh is scheduled at60s within3000ms tolerance', evidence.refresh_gap_ms >= 59000 && evidence.refresh_gap_ms <= 63000);
  } finally { clearInterval(ping); }

  const detachedBefore = controls('tool_stream_detach', a).length;
  one.socket.send(JSON.stringify({type: 'subscribe', instance_ids: []}));
  await wait(() => one.frames.at(-1)?.type === 'subscribed', 'first unsubscribe acknowledgement');
  await sleep(200);
  check('first unsubscribe preserves shared producer', controls('tool_stream_detach', a).length === detachedBefore);
  inject(instances[0], event('tool.end', 'running-a'));
  await wait(() => latest(two, a)?.snapshot.active.length === 0 && latest(two, a)?.snapshot.completed_since_last.length === 1, 'remaining subscriber completion');
  check('remaining viewer continues receiving final active-to-empty completion', true);
  two.socket.send(JSON.stringify({type: 'subscribe', instance_ids: []}));
  await wait(() => controls('tool_stream_detach', a).length === detachedBefore + 1, 'last unsubscribe detaches producer');
  check('last unsubscribe detaches upstream producer once', true);
  const detachedFrames = source(a).length;
  inject(instances[0], [event('tool.start', 'unwatched'), event('tool.end', 'unwatched')]);
  await sleep(1300);
  check('unwatched source does no snapshot transport work', source(a).length === detachedFrames);
  const reconnect = await stream('tanmay', [a], 'reconnected-viewer');
  await wait(() => latest(reconnect, a)?.baseline, 'resubscribe baseline');
  check('resubscribe starts fresh empty without replaying transient completions', latest(reconnect, a).snapshot.active.length === 0 && latest(reconnect, a).snapshot.completed_since_last.length === 0);
  check('last-unsubscribe/new-subscribe creates new producer token', new Set(controls('tool_stream_attach', a).map(x => x.frame.subscription_id)).size === 2);

  // Real managed shell uses the same producer and actual lifecycle transport.
  const shell = JSON.parse(await call(instances[0], ['shell', 'run', '--cmd', 'printf s3-real-shell-output; sleep 4', '--bg', '--cwd', root]));
  const shellId = shell.data?.session?.session_id || shell.data?.data?.session?.session_id;
  assert.ok(shellId, JSON.stringify(shell)); evidence.shell_session_id = shellId;
  const shellActive = await wait(() => latest(reconnect, a)?.snapshot.active.find(x => x.shell_session_id === shellId), 'real shell active summary');
  check('real managed shell command summary arrives while active', shellActive.summary.includes('s3-real-shell-output'));
  const shellDone = await wait(() => states(reconnect, a).flatMap(f => f.snapshot.completed_since_last).find(x => x.call_id === shellActive.call_id), 'real shell completion');
  check('real shell completion has duration and terminal status', shellDone.duration_ms >= 3500 && shellDone.status === 'exited');
  evidence.shell_log = await call(instances[0], ['shell', 'log', shellId]);
  check('real shell operational output remains readable', evidence.shell_log.includes('s3-real-shell-output'));
  const killing = JSON.parse(await call(instances[0], ['shell', 'run', '--cmd', 'sleep 60', '--bg', '--cwd', root]));
  const killId = killing.data?.session?.session_id || killing.data?.data?.session?.session_id;
  await wait(() => latest(reconnect, a)?.snapshot.active.some(x => x.shell_session_id === killId), 'kill fixture active');
  await call(instances[0], ['shell', 'kill', killId]);
  await wait(() => latest(reconnect, a)?.snapshot.active.length === 0, 'real shell kill clears active');
  check('managed shell kill removes active row', true);

  // Adversarial probes copy actual observed state but deliberately alter
  // exactly one fence; they are never counted as successful source captures.
  const sourcePeer = await wait(() => [...peers].find(p => p.bridge_id === bridge.bridge_id), 'authenticated original Bridge');
  const stale = source(a)[0].frame, current = source(a).at(-1).frame;
  let probeSeq = Math.max(...upstream.map(r => r.frame.seq || 0)) + 100;
  const previous = states(reconnect, a).length;
  evidence.rejection_probes = [];
  async function rejectProbe(label, frame) {
    evidence.rejection_probes.push({label, source: bridge.bridge_id, frame});
    sourcePeer.remote.send(JSON.stringify(frame));
    await sleep(300);
    check(label, states(reconnect, a).length === previous);
  }
  await rejectProbe('retired producer token cannot repopulate current viewers', {...stale, seq: ++probeSeq});
  await rejectProbe('wrong runtime run rejected after valid source sequence', {...current, seq: ++probeSeq,
    run_count: current.run_count + 999, snapshot: {...current.snapshot, run_count: current.run_count + 999}});
  await rejectProbe('older revision rejected after valid source sequence', {...current, seq: ++probeSeq,
    snapshot: {...current.snapshot, revision: Math.max(0, current.snapshot.revision - 1)}});
  await rejectProbe('retired source epoch rejected after valid sequence', {...current, seq: ++probeSeq,
    epoch: '1', snapshot: {...current.snapshot, epoch: '1'}});
  await rejectProbe('duplicate source sequence cannot fan out again', current);

  // A separate enrolled Bridge is an actual different authenticated source.
  // Replay a copied state through its socket: transport-valid, binding-invalid.
  console.log(await launcher('bridge', 'start', ['--name', 'b3-spoof', '--hub', 'b3', '--hub-url', 'http://127.0.0.1:18683',
    '--auto-enroll', '--port', '49683', '--local-endpoint-port', '49684', '--bin-dir', bin, '--pty-host-bin', process.env.LIVE_TOOLS_PTY]));
  const spoofBridge = (await api('GET', '/bridges')).find(x => x.bridge_id !== bridge.bridge_id);
  assert.ok(spoofBridge); extraBridgeIds.push(spoofBridge.bridge_id);
  const spoofPeer = await wait(() => [...peers].find(p => p.bridge_id === spoofBridge.bridge_id && p.source_epoch), 'second authenticated Bridge transport');
  const beforeSpoof = states(reconnect, a).length;
  const validSource = source(a).at(-1).frame;
  const spoofFrame = {...validSource, epoch: spoofPeer.source_epoch, seq: 1,
    snapshot: {...validSource.snapshot, epoch: spoofPeer.source_epoch, revision: validSource.snapshot.revision + 1000}};
  evidence.rejection_probes.push({label: 'cross-Bridge source', source: spoofBridge.bridge_id, frame: spoofFrame});
  spoofPeer.remote.send(JSON.stringify(spoofFrame));
  await sleep(1200);
  check('actual cross-Bridge authenticated spoof cannot reach owner viewers', states(reconnect, a).length === beforeSpoof);
  console.log(await launcher('bridge', 'stop', ['--name', 'b3-spoof']));

  // Actual source transport loss -> unavailable -> new producer baseline.
  const unavailableBefore = reconnect.frames.filter(f => f.type === 'unavailable').length;
  const baselineBefore = states(reconnect, a).filter(f => f.baseline).length;
  for (const p of peers) if (p.websocket) p.remote.terminate();
  await wait(() => reconnect.frames.filter(f => f.type === 'unavailable').length > unavailableBefore, 'Bridge transport disconnect unavailable');
  await wait(() => states(reconnect, a).filter(f => f.baseline).length > baselineBefore, 'Bridge transport reconnect baseline', 30000);
  check('actual Bridge disconnect/reconnect clears claims then earns fresh baseline', true);

  // Socket backpressure is isolated per writer. Saturate an unread viewer with
  // bounded request/response traffic; it must disconnect without delaying fast.
  const slow = await stream('tanmay', [a], 'slow-viewer');
  await wait(() => latest(slow, a)?.baseline, 'slow viewer initial baseline');
  slow.socket._socket.pause();
  for (let batchIndex = 0; batchIndex < 100 && slow.socket.readyState === 1; batchIndex++) {
    for (let i = 0; i < 1000; i++) slow.socket.send('{"type":"invalid-slow-fixture"}', () => {});
    await sleep(5);
  }
  const fastPongCount = reconnect.frames.filter(f => f.type === 'pong').length;
  const fastPingAt = performance.now();
  reconnect.socket.send('{"type":"ping"}');
  await wait(() => reconnect.frames.filter(f => f.type === 'pong').length > fastPongCount, 'fast viewer independent pong', 2500);
  evidence.fast_pong_during_slow_ms = performance.now() - fastPingAt;
  slow.socket._socket.resume();
  await wait(() => slow.socket.readyState === WebSocket.CLOSED, 'slow viewer disconnected by bounded queue/send deadline', 12000);
  check('unread viewer is disconnected while fast viewer remains responsive', true);

  // Process restart: the provider source is volatile, no REST/history replay.
  inject(instances[0], event('tool.start', 'before-bridge-restart'));
  await wait(() => latest(reconnect, a)?.snapshot.active.length === 1, 'Bridge restart active fixture');
  const restartBaseline = states(reconnect, a).filter(f => f.baseline).length;
  console.log(await launcher('bridge', 'stop'));
  console.log(await launcher('bridge', 'start', ['--hub', 'b3', '--hub-url', 'http://127.0.0.1:18683', '--bin-dir', bin, '--pty-host-bin', process.env.LIVE_TOOLS_PTY]));
  await wait(() => states(reconnect, a).filter(f => f.baseline).length > restartBaseline, 'Bridge process restart baseline', 30000);
  check('Bridge process restart supplies empty volatile baseline', latest(reconnect, a).snapshot.active.length === 0);
  // A new Hub has no tool-content mirror: an actual fresh WS subscription
  // obtains a new baseline from the still-running Bridge memory.
  inject(instances[0], event('session', '', {payload: {phase: 'start'}}));
  inject(instances[0], event('tool.start', 'across-hub-restart'));
  await wait(() => latest(reconnect, a)?.snapshot.active.length === 1, 'Hub restart active fixture');
  console.log(await launcher('hub', 'stop'));
  console.log(await launcher('hub', 'start', ['--no-ui', '--no-plan-limits', '--bin-dir', bin]));
  await wait(async () => {
    try {return (await api('GET', '/bridges')).find(x => x.bridge_id === bridge.bridge_id)?.runtime_connected;}
    catch {return false;}
  }, 'Bridge reconnects to restarted Hub', 30000);
  const recovered = await stream('tanmay', [a], 'hub-recovered-viewer');
  await wait(() => latest(recovered, a)?.baseline, 'Hub restart obtains Bridge baseline', 30000);
  check('Hub process restart recovers source state without tool REST/history replay', latest(recovered, a).snapshot.active.length === 1);
  inject(instances[0], event('tool.end', 'across-hub-restart'));
  await wait(() => latest(recovered, a)?.snapshot.active.length === 0, 'recovered call completion');
  for (const inst of instances) await api('POST', '/agent-instances/' + inst.agent_instance_id + '/stop', {});
  await wait(() => recovered.frames.some(f => f.type === 'unavailable' && f.instance_id === a), 'terminal source unavailable');
  check('terminal source emits unavailable without fabricating completion', true);

  // Explicit absence checks are probes only, never used to obtain display data.
  evidence.legacy_endpoint_probes = [];
  for (const route of ['/agent-instances/' + a + '/tool-activity-live', '/task-chains/' + chain.chain_id + '/tool-activity-live']) {
    const response = await fetch(proxy + '/api/v1' + route, {headers: {'X-Dev-User': 'tanmay'}});
    evidence.legacy_endpoint_probes.push({route, status: response.status});
    check('removed tool snapshot endpoint returns404: ' + route, response.status === 404);
  }
  evidence.db_after = sql('SELECT message_type, COUNT(*) FROM chat_messages GROUP BY message_type');
  check('zero tool_activity/shell_run SQL conversation writes', ['tool_activity', 'shell_run'].every(type =>
    (evidence.db_after.find(x => x[0] === type)?.[1] || 0) === (evidence.db_before.find(x => x[0] === type)?.[1] || 0)));
  evidence.frame_counts = Object.fromEntries([one, two, three, four, foreign, reconnect, recovered].map(v => [v.label, {state: states(v).length, total: v.frames.length}]));
  evidence.upstream_counts = {attach: upstream.filter(r => r.frame.type === 'tool_stream_attach').length,
    detach: upstream.filter(r => r.frame.type === 'tool_stream_detach').length,
    state: upstream.filter(r => r.frame.type === 'tool_stream_state').length};
  // Actual chronological frames from separate viewers, but a single instance,
  // including initial empty baseline, active baseline, batch, refresh and loss.
  evidence.ui_frames = [one, two, four, reconnect, recovered].flatMap(v => v.timed)
    .filter(r => ['state', 'unavailable'].includes(r.frame.type) && r.frame.instance_id === a)
    .sort((x, y) => x.ms - y.ms)
    .filter((r, i, rows) => i === 0 || JSON.stringify(r.frame) !== JSON.stringify(rows[i - 1].frame))
    .map(r => r.frame);
  evidence.limits = ['Provider callback injection via actual CLI; no new native provider parity claim.',
    'Real Hub/Bridge/CLI/dev-proxy/socket transport and real managed shell; UI actual captured stream + React/JSDOM, no outer browser visual claim.',
    'Cross-Bridge spoof tested on a second enrolled Bridge transport; bounded tracker behavior additionally covered by scoped Odin tests.',
    'Refresh uses real60s source clock;120s UI receipt expiry and >2min long-running state verified with existing fake-monotonic-clock tests.'];
  const nativeEvidence = '/home/tanmay/.local/state/heimdall-tool-stream-preview-18e13baf/native-smoke-evidence.json';
  if (fs.existsSync(nativeEvidence)) {
    fs.copyFileSync(nativeEvidence, path.join(root, 'prior-native-smoke.json'));
    evidence.prior_native_smoke = {path: nativeEvidence, source_commit: '19200023ff44e4c9b42648cbac46e0ef08658c38',
      scope: 'Previously captured native Codex smoke, reused without touching preview; not a fresh native run at S3 head.'};
  }
  evidence.status = 'pass';
} catch (error) { evidence.status = 'fail'; evidence.error = error.stack; console.error(error); process.exitCode = 1; }
finally {
  for (const socket of sockets) socket.terminate();
  for (const inst of instances) {try {await api('POST', '/agent-instances/' + inst.agent_instance_id + '/stop', {});} catch {}}
  try {console.log(await launcher('bridge', 'stop', ['--name', 'b3-spoof']));} catch {}
  for (const kind of ['bridge', 'hub']) {try {console.log(await launcher(kind, 'stop'));} catch (error) {console.error(error.message);}}
  for (const p of peers) {p.remote.terminate(); p.local.terminate();}
  for (const socket of relaySockets) socket.destroy();
  relay.close();
  const enrollmentIds = [...new Set(upstream.map(r => r.frame.snapshot?.bridge_id).filter(Boolean).concat(bridge ? [bridge.bridge_id] : [], extraBridgeIds))];
  for (const id of enrollmentIds) {
    const socket = '/tmp/heimdall-bridge-local/pty-host-' + id + '.sock';
    try {evidence.pty_cleanup = run(process.env.LIVE_TOOLS_PTY, ['--socket', socket, 'stop']);} catch (error) {console.error(error.message);}
  }
  for (const inst of instances) fs.rmSync(path.join(root, inst.agent_instance_id + '.env.json'), {force: true});
  fs.writeFileSync(path.join(root, 'manifest.json'), JSON.stringify(evidence, null, 2));
  console.log('EVIDENCE', path.join(root, 'manifest.json'));
}
