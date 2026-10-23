// Creates a real provider instance in the isolated preview only. No credentials
// are written to the evidence record or printed.
import fs from 'node:fs';
const origin = 'http://127.0.0.1:18790';
const state = '/home/tanmay/.local/state/heimdall-tool-stream-preview-18e13baf';
async function api(method, route, body) {
  const response = await fetch(origin + '/api/v1' + route, {
    method, headers: {'Content-Type': 'application/json'},
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const value = await response.json();
  if (!response.ok) throw new Error(`${method} ${route}: ${response.status} ${JSON.stringify(value)}`);
  return value.data;
}
const bridge = (await api('GET', '/bridges'))[0];
for (const provider of ['claude', 'codex']) {
  await api('PUT', `/bridges/${bridge.bridge_id}/providers/${provider}`, {enabled: true});
}
const agent = await api('POST', '/agents', {
  name: 'Tool stream preview smoke', slug: 'tool-stream-preview-smoke',
  instructions: 'You are a live smoke-test agent in an isolated local Heimdall preview. Follow the bootstrap startup instructions. Use the provided local ham-ctl for communication. Do only requested preview smoke commands. After startup, report ready and wait for requests. Do not modify repositories, production services, credentials, or settings.',
});
const chain = await api('POST', '/task-chains', {title: 'Tool stream hands-on preview'});
const instance = await api('POST', '/agent-instances', {
  agent_id: agent.agent_id, bridge_id: bridge.bridge_id,
  provider: 'codex', model: 'gpt-6.1-sol', display_name: 'Stream smoke',
  chain_id: chain.chain_id,
});
const record = {
  bridge_id: bridge.bridge_id, agent_id: agent.agent_id,
  chain_id: chain.chain_id, instance_id: instance.agent_instance_id,
  provider: 'codex', model: 'gpt-6.1-sol',
};
fs.writeFileSync(state + '/smoke.json', JSON.stringify(record, null, 2), {mode: 0o600});
console.log(JSON.stringify(record));
