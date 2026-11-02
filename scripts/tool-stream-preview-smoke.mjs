import fs from 'node:fs';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createRequire} from 'node:module';
const require = createRequire(import.meta.url);
const WebSocket = require('ws');
const state = '/home/tanmay/.local/state/heimdall-tool-stream-preview-18e13baf';
const setup = JSON.parse(fs.readFileSync(state + '/smoke.json'));
const sid = fs.readFileSync('.ui-preview-session', 'utf8').trim();
const base = `http://127.0.0.1:49325/proxy/${sid}`;
// Users authenticate only with OIDC: pass the hub session (the value of the
// __Host-heimdall_session cookie from a sign-in against that hub) in HEIMDALL_SESSION.
const sessionCookie = process.env.HEIMDALL_SESSION ? {Cookie: `__Host-heimdall_session=${process.env.HEIMDALL_SESSION}`} : {};
const frames = [];
const checks = [];
const sockets = [];
function check(label, condition) {
  assert.ok(condition, label); checks.push(label); console.log('PASS ' + label);
}
async function wait(predicate, label, timeout = 20_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const result = await predicate(); if (result) return result;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error('timeout: ' + label);
}
async function api(method, route, body) {
  const response = await fetch(base + '/api/v1' + route, {
    method, headers: {'Content-Type': 'application/json', Origin: 'https://heimdall-preview.mundus.in', ...sessionCookie},
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  assert.ok(response.ok, `${method} ${route}: ${response.status}`);
  return (await response.json()).data;
}
async function stream(ticket = true) {
  const suffix = ticket ? '?ticket=' + encodeURIComponent((await api('POST', '/me/ws-ticket', {})).ticket) : '';
  // The machine-to-machine local /proxy relay supports HTTP, not upgrades.
  // Exercise upgrades at the actual browser-facing preview server instead.
  const socket = new WebSocket('ws://127.0.0.1:45291/api/v1/tool-activity/stream' + suffix,
    {headers: {Origin: 'https://heimdall-preview.mundus.in', ...sessionCookie}});
  sockets.push(socket);
  const local = [];
  socket.on('message', data => {const frame = JSON.parse(data); frames.push(frame); local.push(frame);});
  await new Promise((resolve, reject) => {socket.once('open', resolve); socket.once('error', reject);});
  socket.send(JSON.stringify({type: 'subscribe', instance_ids: [setup.instance_id]}));
  await wait(() => local.find(frame => frame.type === 'state' && frame.baseline), 'fresh Bridge baseline');
  return {socket, local};
}
function localCtl(args) {
  const executable = `${state}/bridges/tool-stream-18e13baf/endpoint/instances/${setup.instance_id}/bin/ham-ctl`;
  const child = spawn(executable, args, {stdio: ['ignore', 'pipe', 'pipe']});
  let output = ''; let error = '';
  child.stdout.on('data', data => output += data);
  child.stderr.on('data', data => error += data);
  return new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', code => {
    if (code !== 0) reject(new Error(`local CLI exit ${code}: ${error}`));
    else resolve(JSON.parse(output));
  }); });
}
try {
  check('relay health reaches isolated Hub', (await api('GET', '/health')).ok);
  check('relay authenticates isolated test user', (await api('GET', '/me')).user_id === 'tanmay');
  const bridges = await api('GET', '/bridges');
  check('only isolated enrolled Bridge is connected', bridges.length === 1 && bridges[0].bridge_id === setup.bridge_id && bridges[0].runtime_connected && bridges[0].enrollment_state === 'enrolled');
  const html = await (await fetch(base + '/')).text();
  check('relay serves SPA prefix guard', html.includes('data-heimdall-preview-guard'));
  const asset = html.match(/src="\.\/(assets\/[^\"]+\.js)"/)[1];
  check('relative hashed asset loads through relay', (await fetch(base + '/' + asset)).status === 200);
  check('SPA fallback loads through relay', (await fetch(base + '/deep-route')).status === 200);
  const owner = await stream();
  check('ticket-authenticated dedicated tools WS baseline through preview server and dev proxy', true);
  owner.socket.send(JSON.stringify({type: 'ping'}));
  await wait(() => owner.local.find(frame => frame.type === 'pong'), 'JSON pong');
  check('dedicated tools WS ping/pong through preview server and dev proxy', true);
  const response = await localCtl(['shell', 'run', '--cmd', 'printf tool-stream-managed-smoke; sleep 5', '--bg', '--cwd', '/home/tanmay/hamwt/tool-stream-preview']);
  const shell = response.data?.data?.session || response.data?.session;
  assert.ok(shell?.session_id);
  const active = await wait(() => frames.flatMap(frame => frame.snapshot?.active || []).find(call => call.shell_session_id === shell.session_id), 'real managed shell active');
  check('real shell command summary arrives while active', active.summary.includes('tool-stream-managed-smoke'));
  const second = await stream(false);
  check('session-cookie WS baseline includes running shell', second.local.some(frame => frame.baseline && frame.snapshot.active.some(call => call.shell_session_id === shell.session_id)));
  const completed = await wait(() => frames.flatMap(frame => frame.snapshot?.completed_since_last || []).find(call => call.call_id === active.call_id), 'real shell completion');
  check('real completion includes measured duration', completed.duration_ms >= 4000 && completed.status === 'exited');
  check('completion removes shell from active state', frames.filter(frame => frame.type === 'state').at(-1).snapshot.active.every(call => call.shell_session_id !== shell.session_id));
  if (process.argv.includes('--native')) {
    const before = frames.length;
    await api('POST', '/chats/chat_18e13c02c10bad5e/messages', {
      body: 'Preview smoke: run exactly one native shell tool command `printf tool-stream-native-smoke; sleep 6` now, then report completion using the local ham-ctl chat send --to user. Do not edit files or settings.',
    });
    const native = await wait(() => frames.slice(before).flatMap(frame => frame.snapshot?.active || []).find(call => call.source === 'provider' && call.summary.includes('tool-stream-native-smoke')), 'native provider active tool', 90_000);
    await wait(() => frames.slice(before).flatMap(frame => frame.snapshot?.completed_since_last || []).find(call => call.call_id === native.call_id), 'native provider completion', 30_000);
    check('native Codex tool active summary and completion arrive through dedicated WS', true);
  }
  const extension = await localCtl(['extension', 'status']);
  check('native extension accepted events without drops', extension.data.events_accepted > 0 && extension.data.events_dropped === 0);
  const evidencePath = state + (process.argv.includes('--native') ? '/native-smoke-evidence.json' : '/live-smoke-evidence.json');
  fs.writeFileSync(evidencePath, JSON.stringify({
    setup, session_id: sid, checks, shell_session_id: shell.session_id,
    frames, extension_status: extension.data, observed_at: new Date().toISOString(),
  }, null, 2), {mode: 0o600});
  console.log(`PASS ${checks.length} live preview checks; evidence ${evidencePath}`);
} finally {
  for (const socket of sockets) socket.terminate();
}
