#!/usr/bin/env node
// Seed a local hub with deterministic sample agents, task chains and memories.
//
//   node scripts/local-runtime/seed.mjs --api <proxy-url> --record <seed.json> [--user <name>]
//
// Everything goes through the hub's public REST API behind ham-dev-proxy, the same
// path the browser UI uses, so validation, ownership and vault rules all apply.
// Idempotent: a fixture is skipped when the record file says it was seeded before
// (even if the user since renamed or deleted it) or when an item with the same
// name/title already exists. Nothing is ever updated, and no agent is launched:
// agents are created as definitions and chains without a coordinator.
// Shared by local-hub.sh and local-hub.ps1 (see CONTRACT.md).
import { readFileSync, writeFileSync, renameSync, existsSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export const FIXTURES = {
  agents: [
    { key: 'sample-coordinator', name: 'Sample Coordinator', instructions: 'Plans and delegates sample work. Seeded by local-hub.' },
    { key: 'sample-worker', name: 'Sample Worker', instructions: 'Implements sample tasks. Seeded by local-hub.' },
  ],
  chains: [
    {
      key: 'sample-onboarding', title: 'Sample: onboarding walkthrough',
      description: 'Seeded sample chain showing a small planned feature.',
      tasks: [
        { title: 'Read the project README', description: 'Summarise the setup steps.' },
        { title: 'Add a hello-world endpoint', description: 'Small change with a test.' },
      ],
    },
    {
      key: 'sample-bugfix', title: 'Sample: bug triage',
      description: 'Seeded sample chain showing a triage flow.',
      tasks: [{ title: 'Reproduce the reported crash', description: 'Write down exact steps.' }],
    },
  ],
  memories: [
    { key: 'sample-test-command', type: 'fact', title: 'Sample: how tests run', body: 'Run scoped tests for the package you touch before submitting.' },
    { key: 'sample-review-habit', type: 'habit', title: 'Sample: review habit', body: 'Reviewers read the diff and the worker evidence before voting.' },
  ],
};

function parseArgs(argv) {
  const out = { user: '' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--api') out.api = argv[++i];
    else if (a === '--record') out.record = argv[++i];
    else if (a === '--user') out.user = argv[++i];
    else throw new Error(`unknown argument ${a}`);
  }
  if (!out.api || !out.record) throw new Error('usage: seed.mjs --api <url> --record <file> [--user <name>]');
  return out;
}

export async function seed({ api, record, user = '', fetchImpl = fetch, log = console.log }) {
  const base = api.replace(/\/+$/, '');
  const state = existsSync(record) ? JSON.parse(readFileSync(record, 'utf8')) : { version: 1, seeded: {} };
  const headers = { 'Content-Type': 'application/json' };
  if (user) headers['X-Dev-User'] = user;

  async function call(method, path, body) {
    const res = await fetchImpl(base + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
    const text = await res.text();
    if (!res.ok) throw new Error(`${method} ${path} -> ${res.status}: ${text.slice(0, 300)}`);
    return text ? JSON.parse(text) : {};
  }
  function save() {
    const tmp = `${record}.tmp`;
    writeFileSync(tmp, JSON.stringify(state, null, 2) + '\n');
    renameSync(tmp, record);
  }
  const counts = { created: 0, skipped: 0 };
  function skip(key, why) { counts.skipped++; log(`seed: skip ${key} (${why})`); }
  function done(key, id) { state.seeded[key] = id; save(); counts.created++; log(`seed: created ${key} ${id}`); }

  const agents = (await call('GET', '/api/v1/agents?limit=200')).data || [];
  for (const f of FIXTURES.agents) {
    if (state.seeded[f.key]) { skip(f.key, 'recorded'); continue; }
    const hit = agents.find((a) => a.name === f.name);
    if (hit) { state.seeded[f.key] = hit.agent_id; save(); skip(f.key, 'exists'); continue; }
    const r = await call('POST', '/api/v1/agents', { name: f.name, slug: f.key, template_id: '', instructions: f.instructions });
    done(f.key, r.data.agent_id);
  }

  const chains = (await call('GET', '/api/v1/task-chains?flat=1')).data || [];
  for (const f of FIXTURES.chains) {
    if (state.seeded[f.key]) { skip(f.key, 'recorded'); continue; }
    const hit = chains.find((c) => c.title === f.title);
    if (hit) { state.seeded[f.key] = hit.chain_id; save(); skip(f.key, 'exists'); continue; }
    const chain = (await call('POST', '/api/v1/task-chains', { title: f.title, description: f.description })).data.chain_id;
    for (const t of f.tasks) {
      await call('POST', `/api/v1/task-chains/${encodeURIComponent(chain)}/tasks`, { title: t.title, description: t.description });
    }
    done(f.key, chain);
  }

  const memories = (await call('GET', '/api/v1/memories?limit=200')).data || [];
  for (const f of FIXTURES.memories) {
    if (state.seeded[f.key]) { skip(f.key, 'recorded'); continue; }
    const hit = memories.find((m) => m.title === f.title);
    if (hit) { state.seeded[f.key] = hit.memory_id; save(); skip(f.key, 'exists'); continue; }
    const id = (await call('POST', '/api/v1/memories', { type: f.type, title: f.title, body: f.body })).data.memory_id;
    // Approval is the normal human step; the seeding user is that human here.
    await call('POST', `/api/v1/memories/${encodeURIComponent(id)}/approve`, {});
    done(f.key, id);
  }
  log(`seed: ${counts.created} created, ${counts.skipped} skipped`);
  return counts;
}

// Compared by real path: the checkout is often reached through a symlink
// (/home -> /var/home), and a plain URL comparison then silently skips main.
if (process.argv[1] && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1])) {
  seed(parseArgs(process.argv.slice(2))).catch((err) => {
    console.error(`seed: ${err.message}`);
    process.exit(1);
  });
}
