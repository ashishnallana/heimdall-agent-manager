// Private fixture setup and SHA-256 snapshots for the real-stack profile smoke.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
export function treeSnapshot(dir) {
  const out = {};
  const walk = (p, rel) => {
    if (!fs.existsSync(p)) return;
    const st = fs.lstatSync(p);
    if (st.isSymbolicLink()) {
      out[rel] = 'link:' + fs.readlinkSync(p);
      return;
    }
    if (st.isDirectory()) {
      for (const name of fs.readdirSync(p).sort()) walk(path.join(p, name), path.join(rel, name));
      return;
    }
    if (st.isFile()) out[rel] = createHash('sha256').update(fs.readFileSync(p)).digest('hex');
  };
  walk(dir, '.');
  return out;
}
const [root, realHome, fixture] = process.argv.slice(2);
if (root && realHome && fixture) {
  const write = (p, data) => {
    fs.mkdirSync(path.dirname(p), { recursive: true, mode: 0o700 });
    fs.writeFileSync(p, data, { mode: 0o600 });
  };
  const home = path.join(root, 'fake-home');
  write(
    path.join(home, '.claude/.credentials.json'),
    JSON.stringify({
      claudeAiOauth: {
        accessToken: 'p4-dummy-claude-auth',
        refreshToken: 'p4-dummy-refresh',
        expiresAt: 0,
      },
    }),
  );
  write(
    path.join(home, '.claude.json'),
    JSON.stringify({
      hasCompletedOnboarding: true,
      projects: {},
      mcpServers: { unsafe: { command: 'P4_UNSAFE_CODE' } },
    }),
  );
  write(
    path.join(home, '.claude/settings.json'),
    JSON.stringify({
      theme: 'dark',
      hooks: { SessionStart: [{ command: 'P4_UNSAFE_CODE' }] },
      enabledPlugins: { unsafe: true },
    }),
  );
  write(
    path.join(home, '.codex/auth.json'),
    JSON.stringify({ OPENAI_API_KEY: 'p4-dummy-codex-auth' }),
  );
  write(
    path.join(home, '.codex/config.toml'),
    'model = "test-only"\n[mcp_servers.unsafe]\ncommand = "P4_UNSAFE_CODE"\n',
  );
  write(path.join(home, '.gemini/oauth_creds.json'), '{"access_token":"p4-dummy-gemini-auth"}');
  write(
    path.join(home, '.gemini/settings.json'),
    '{"theme":"light","mcpServers":{"unsafe":{"command":"P4_UNSAFE_CODE"}}}',
  );
  write(path.join(home, '.pi/agent/auth.json'), '{"test":"p4-dummy-pi-auth"}');
  write(
    path.join(home, 'project-outside-isolated-home/README.md'),
    'Disposable external project for the provider profile smoke.\n',
  );
  for (const d of ['claude', 'codex', 'gemini', 'config', 'data', 'state', 'cache'])
    write(path.join(root, 'decoys', d, 'SENTINEL'), 'unchanged-decoy-' + d);
  fs.copyFileSync(fixture, path.join(root, 'profile-provider'));
  fs.chmodSync(path.join(root, 'profile-provider'), 0o700);
  write(
    path.join(root, 'actual-home-before.json'),
    JSON.stringify({
      claude: treeSnapshot(path.join(realHome, '.claude')),
      codex: treeSnapshot(path.join(realHome, '.codex')),
    }),
  );
  console.log('Fixture and full real-provider checksum snapshots prepared.');
}
