#!/usr/bin/env node
// Write an isolated bridge config for one local bridge instance.
//
//   node scripts/local-runtime/bridge-config.mjs --template config.toml --out <cfg>
//        --dir <instance-dir> --hub-url <url> --port <bridge-port> --name <instance>
//
// Starts from the repo's config.toml and rewrites every path and endpoint the
// bridge persists to so it points inside <instance-dir> and at <hub-url>. Keys the
// bridge writes itself (daemon_id after enrollment) are preserved when <cfg>
// already exists, so re-running never undoes an enrollment. [[peer]] blocks are
// dropped: a local bridge federates with nothing. Shared by local-bridge.sh/.ps1.
import { readFileSync, writeFileSync, renameSync, existsSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

export function renderBridgeConfig(template, { dir, hubUrl, port, name, existing = '' }) {
  const d = dir.replace(/\\/g, '/').replace(/\/+$/, '');
  const enrolledId = (existing.match(/^daemon_id\s*=\s*"([^"]*)"/m) || [])[1];
  const values = {
    'daemon.port': String(port),
    'daemon.data_dir': `"${d}/data"`,
    'daemon.daemon_id': `"${enrolledId || `local-${name}`}"`,
    // Wrappers talk to this bridge; ham-ctl talks to the hub (as dev-stack did).
    'wrapper.daemon_url': `"http://127.0.0.1:${port}"`,
    'wrapper.credentials_path': `"${d}/data/wrapper-credentials.json"`,
    'wrapper.agent_run_dir': `"${d}/agent-runs"`,
    'wrapper.tmux_session': `"ham-local-${name}"`,
    'ctl.daemon_url': `"${hubUrl}"`,
  };
  const seen = new Set();
  const out = [];
  let section = '';
  let inPeer = false;
  for (const line of template.split('\n')) {
    const header = line.trim().match(/^\[{1,2}([^\]]+)\]{1,2}$/);
    if (header) {
      inPeer = line.trim() === '[[peer]]';
      section = header[1];
      if (inPeer) continue;
    }
    if (inPeer) continue;
    const kv = line.match(/^(\s*)([a-z_]+)(\s*=\s*)(.*)$/);
    const key = kv && `${section}.${kv[2]}`;
    if (kv && key in values && !seen.has(key)) {
      seen.add(key);
      out.push(`${kv[1]}${kv[2]}${kv[3]}${values[key]}`);
      continue;
    }
    out.push(line);
  }
  const missing = Object.keys(values).filter((k) => !seen.has(k));
  if (missing.length) throw new Error(`template lacks keys: ${missing.join(', ')}`);
  return out.join('\n');
}

function main(argv) {
  const a = {};
  for (let i = 0; i < argv.length; i += 2) a[argv[i].replace(/^--/, '')] = argv[i + 1];
  for (const k of ['template', 'out', 'dir', 'hub-url', 'port', 'name']) {
    if (!a[k]) throw new Error(`missing --${k}`);
  }
  const existing = existsSync(a.out) ? readFileSync(a.out, 'utf8') : '';
  const text = renderBridgeConfig(readFileSync(a.template, 'utf8'), {
    dir: a.dir, hubUrl: a['hub-url'], port: a.port, name: a.name, existing,
  });
  mkdirSync(dirname(a.out), { recursive: true });
  writeFileSync(`${a.out}.tmp`, text, { mode: 0o600 });
  renameSync(`${a.out}.tmp`, a.out);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try { main(process.argv.slice(2)); } catch (err) { console.error(`bridge-config: ${err.message}`); process.exit(1); }
}
