// Real Hub -> sealed UI API -> Bridge -> native plugin CLI / PTY integration.
// Agent model execution is an offline recording fixture; extension installation
// uses the locally installed Claude binary and checkout-bundled marketplace.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { openSeedApprover } from './approver.mjs';
import { hubLogin, sessionHeaders } from '../../tests/e2e/hubOidc.mjs';
import { importKeyring } from '../../src/ui/utils/vaultKeyring.ts';
import { setActiveVaultKey, encryptVaultText } from '../../src/ui/utils/vaultCrypto.ts';
import { providerProfilesApi } from '../../src/ui/components/providers/providerProfiles.ts';

const [api, root, realHome] = process.argv.slice(2);
if (!api || !root || !realHome)
  throw new Error('usage: profile-integration.mjs <ui-api> <private-root> <real-home>');
const bridgeDir = path.join(root, 'state/bridges/profiles');
const fakeHome = path.join(root, 'fake-home');
const hubDir = path.join(root, 'state/hubs/profiles');
const config = fs.readFileSync(path.join(bridgeDir, 'config.toml'), 'utf8');
const bridgeId = config.match(/^daemon_id = "([^"]+)"/m)?.[1];
assert.ok(bridgeId);
const checks = [];
const pass = (label) => {
  checks.push(label);
  console.log('ok   ' + label);
};
const fetchNative = globalThis.fetch;
const cookie = await hubLogin(api, '');
const headers = sessionHeaders(cookie, process.env.HEIMDALL_LOCAL_UI_ORIGIN || api);
const request = async (p, method = 'GET', body) => {
  const r = await fetchNative(api + '/api/v1' + p, {
    method,
    headers: { ...headers, ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(30000),
  });
  const json = await r.json();
  if (!r.ok) throw new Error(method + ' ' + p.split('?')[0] + ': ' + JSON.stringify(json.error));
  return json.data ?? json;
};
const poll = async (fn, label, limit = 60000) => {
  const deadline = Date.now() + limit;
  do {
    const result = await fn();
    if (result) return result;
    await new Promise((r) => setTimeout(r, 200));
  } while (Date.now() < deadline);
  throw new Error('Timeout: ' + label);
};
const app = await openSeedApprover({ api, key: path.join(hubDir, 'approver/device.json') });
const keyring = await importKeyring(app.keyringBytes);
app.keyringBytes.fill(0);
setActiveVaultKey(keyring);
// Exercise the production browser client against the real server, not a copied
// encoder. Only relative /api/v1 requests are adapted to this private UI origin.
globalThis.fetch = (url, init = {}) =>
  fetchNative(String(url).startsWith('/api/v1') ? api + url : url, {
    ...init,
    headers: { ...headers, ...init.headers },
    signal: init.signal || AbortSignal.timeout(30000),
  });

function treeSnapshot(dir) {
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
const read = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const isolatedHome = path.join(bridgeDir, 'home');
const manifest = read(path.join(isolatedHome, '.heimdall-home-manifest.json'));
assert.ok(manifest);
assert.equal(
  fs.readFileSync(path.join(isolatedHome, '.claude/.credentials.json'), 'utf8'),
  fs.readFileSync(path.join(fakeHome, '.claude/.credentials.json'), 'utf8'),
);
assert.equal(
  fs.readFileSync(path.join(isolatedHome, '.codex/auth.json'), 'utf8'),
  fs.readFileSync(path.join(fakeHome, '.codex/auth.json'), 'utf8'),
);
assert.ok(
  !JSON.stringify(read(path.join(isolatedHome, '.claude/settings.json'))).includes(
    'P4_UNSAFE_CODE',
  ),
);
assert.ok(
  !fs
    .readFileSync(path.join(isolatedHome, '.codex/config.toml'), 'utf8')
    .includes('P4_UNSAFE_CODE'),
);
pass('fake-home auth copies and checksum manifest exist; code-running settings excluded');
const beforeFake = treeSnapshot(fakeHome);
const beforeDecoys = treeSnapshot(path.join(root, 'decoys'));
const actualBefore = read(path.join(root, 'actual-home-before.json'));
const fixtureBinary = path.join(root, 'profile-provider');
const forbidden = [fixtureBinary, 'P4_PROFILE_ACCOUNT'];
const ids = ['claude_p4alpha', 'claude_p4beta'];
const definitions = ids.map((id, i) => ({
  profile_id: id,
  provider: 'claude',
  label_enc: '',
  accent: i ? '#2299aa' : '#aa5522',
  enabled: true,
  environment: [{ name: 'P4_PROFILE_ACCOUNT', value: 'p4-private-value-' + i, sensitive: true }],
  config: {
    binary_path: fixtureBinary,
    config_dir: path.join(root, 'profile-private-' + i),
    launch_args: '"--p4-private-arg-' + i + '"',
    custom_models: [],
  },
}));
try {
  for (const p of definitions) {
    p.label_enc = await encryptVaultText('P4 private label ' + p.profile_id);
    forbidden.push(
      p.config.config_dir,
      p.environment[0].value,
      p.config.launch_args.slice(1, -1),
      'P4 private label ' + p.profile_id,
    );
    await providerProfilesApi.operate(bridgeId, p.profile_id, 'upsert', p);
  }
  await poll(
    async () =>
      (await providerProfilesApi.list(bridgeId)).filter((p) => ids.includes(p.profile_id))
        .length === 2,
    'profile metadata sync',
  );
  for (const p of definitions) {
    const view = await providerProfilesApi.operate(bridgeId, p.profile_id, 'get');
    assert.equal(view.config.config_dir, p.config.config_dir);
    assert.equal(view.environment[0].value, '');
    assert.equal(view.environment[0].value_redacted, true);
  }
  pass('production sealed UI client creates two profiles; real bridge get redacts stored secrets');
  if (process.argv.includes('--seed-only')) {
    await request('/bridges/' + bridgeId + '/providers/discover', 'POST', { stage: 'providers' });
    fs.writeFileSync(path.join(root, 'preview-bridge-id'), bridgeId, { mode: 0o600 });
    console.log('Review profiles restored after purge proof.');
  } else {
    // Default-profile install exercises inherited HOME with all decoys cleared.
    await providerProfilesApi.operate(bridgeId, 'claude', 'upsert', {
      provider: 'claude',
      label_enc: '',
      accent: '',
      enabled: true,
      environment: [],
      config: { binary_path: fixtureBinary },
    });
    await request('/bridges/' + bridgeId + '/providers/discover', 'POST', { stage: 'providers' });
    await request('/bridges/' + bridgeId + '/providers/claude', 'PUT', {
      enabled: true,
      profile_id: 'claude',
    });
    for (const p of definitions)
      await request('/bridges/' + bridgeId + '/providers/discover', 'POST', {
        stage: 'providers',
        providers: ['claude'],
        profile_id: p.profile_id,
      });
    const status = await request('/bridges/' + bridgeId + '/provider-status');
    for (const p of definitions)
      assert.ok(
        status.providers.some(
          (s) => s.profile_id === p.profile_id && s.state === 'present' && s.enabled,
        ),
        'custom profile is detected independently',
      );
    const extension = async (profileId) => {
      const command = await request(
        '/bridges/' + bridgeId + '/providers/claude/extension-install',
        'POST',
        { profile_id: profileId },
      );
      const result = await poll(
        async () => {
          const c = await request(
            '/bridges/' + bridgeId + '/providers/claude/extension-install/' + command.command_id,
          );
          if (['failed', 'cancelled'].includes(c.status))
            throw new Error('extension ' + profileId + ': ' + JSON.stringify(c));
          return c.status === 'succeeded' ? c : null;
        },
        'real CLI extension install ' + profileId,
        120000,
      );
      assert.equal(result.profile_id, profileId);
    };
    await extension('claude');
    assert.ok(fs.existsSync(path.join(isolatedHome, '.claude/plugins/installed_plugins.json')));
    pass('real Claude plugin install targets isolated default HOME, not decoy config dirs');
    for (const p of definitions) {
      await extension(p.profile_id);
      const installed = read(path.join(p.config.config_dir, 'plugins/installed_plugins.json'));
      assert.ok(JSON.stringify(installed).includes('heimdall'));
      const events = fs
        .readFileSync(path.join(p.config.config_dir, '.p4-plugin-events.jsonl'), 'utf8')
        .trim()
        .split('\n')
        .map(JSON.parse);
      assert.ok(events.some((e) => e.args[0] === 'plugin' && e.args[1] === 'install'));
      assert.ok(
        events.every((e) => e.configDir === p.config.config_dir && e.home === isolatedHome),
      );
    }
    pass(
      'real Claude CLI installs checkout extension separately into both profile config directories',
    );

    const projectDir = path.join(fakeHome, 'project-outside-isolated-home');
    const browsing = await request(
      '/bridges/' + bridgeId + '/fs?path=' + encodeURIComponent(projectDir),
    );
    assert.equal(browsing.ok, true);
    assert.equal(browsing.root, fakeHome);
    assert.ok(browsing.entries.some((e) => e.name === 'README.md'));
    const project = await request('/projects', 'POST', {
      name: await encryptVaultText('P4 external project'),
      description: '',
      default_path: projectDir,
    });
    await request('/projects/' + project.project_id + '/bridge-paths/' + bridgeId, 'PUT', {
      path: projectDir,
    });
    const validation = await request(
      '/projects/' + project.project_id + '/bridge-paths/' + bridgeId + '/validate',
      'POST',
      {},
    );
    assert.ok(!validation.error);
    pass(
      'real-home project outside isolated provider HOME can be registered, validated and browsed',
    );

    const agents = await request('/agents?limit=200');
    const agentId = agents[0].agent_id;
    const launched = [];
    for (const p of definitions) {
      const model = status.providers
        .find((s) => s.profile_id === p.profile_id)
        .models.find((m) => m.state === 'active').model_id;
      const instance = await request('/agent-instances', 'POST', {
        agent_id: agentId,
        bridge_id: bridgeId,
        provider: 'claude',
        provider_profile: p.profile_id,
        model,
        project_id: project.project_id,
      });
      launched.push(instance);
      const launchFile = path.join(p.config.config_dir, '.p4-launch.json');
      await poll(() => fs.existsSync(launchFile), 'offline managed provider launched');
      const record = read(launchFile);
      assert.equal(record.account, p.environment[0].value);
      assert.equal(record.home, isolatedHome);
      assert.equal(record.configDir, p.config.config_dir);
      assert.ok(record.args.includes(p.config.launch_args.slice(1, -1)));
      assert.equal(record.instanceId, instance.agent_instance_id);
      await poll(async () => {
        const row = await request('/agent-instances/' + instance.agent_instance_id);
        assert.equal(row.provider_profile, p.profile_id);
        return row.startup_status === 'ready';
      }, 'real endpoint start-success');
      await request('/agent-instances/' + instance.agent_instance_id + '/stop', 'POST', {});
      await poll(
        async () =>
          ['stopped', 'terminated'].includes(
            (await request('/agent-instances/' + instance.agent_instance_id)).runtime_status,
          ),
        'managed provider stop',
      );
    }
    pass(
      'both profiles launch through real Hub/Bridge/PTY/bootstrap/start-success with separate args/env (offline model boundary)',
    );

    // Include SQLite WAL bytes; a checkpoint alone could hide a leaked recent write.
    const dbFiles = ['hub.db', 'hub.db-wal', 'hub.db-shm']
      .map((name) => path.join(hubDir, name))
      .filter(fs.existsSync);
    for (const file of dbFiles) {
      const bytes = fs.readFileSync(file);
      for (const needle of forbidden)
        assert.ok(!bytes.includes(Buffer.from(needle)), 'hub DB contains forbidden profile field');
    }
    const stored = read(path.join(bridgeDir, 'data/bridge/provider_profiles.json'));
    assert.ok(!JSON.stringify(stored).includes('p4-private-value-'));
    const secretDir = path.join(bridgeDir, 'data/bridge/profile-secrets');
    assert.equal(fs.statSync(secretDir).mode & 0o777, 0o700);
    for (const file of fs.readdirSync(secretDir))
      assert.equal(fs.statSync(path.join(secretDir, file)).mode & 0o777, 0o600);
    pass(
      'hub DB plus WAL/SHM contain no profile path, env name/value, private label or args; local secrets are separate 0600 files',
    );

    assert.deepEqual(treeSnapshot(fakeHome), beforeFake);
    assert.deepEqual(treeSnapshot(path.join(root, 'decoys')), beforeDecoys);
    const actualAfter = {
      claude: treeSnapshot(path.join(realHome, '.claude')),
      codex: treeSnapshot(path.join(realHome, '.codex')),
    };
    const diffs = [];
    for (const provider of ['claude', 'codex'])
      for (const file of new Set([
        ...Object.keys(actualBefore[provider]),
        ...Object.keys(actualAfter[provider]),
      ]))
        if (actualBefore[provider][file] !== actualAfter[provider][file])
          diffs.push(provider + ':' + file);
    // Live Codex session streams and runtime journals change independently of
    // provider installation. Report them; keep all other checksums strict.
    const volatile = (name) =>
      /^codex:(sessions\/|(?:history|session_index)\.jsonl$|models_cache\.json$|(?:logs|state|thread_history)_\d+\.sqlite(?:-(?:wal|shm))?$)/.test(
        name,
      );
    const volatileChanged = diffs.filter(volatile);
    assert.deepEqual(
      diffs.filter((name) => !volatile(name)),
      [],
      'protected real provider files changed',
    );
    pass(
      'fake HOME and all decoys unchanged; real auth/config/plugins and every nonvolatile provider file checksum unchanged',
    );
    if (volatileChanged.length)
      console.log(
        'info live Codex runtime files changed separately: ' + volatileChanged.join(', '),
      );

    fs.writeFileSync(
      path.join(root, 'result.json'),
      JSON.stringify(
        {
          checks,
          bridgeId,
          profiles: ids,
          instances: launched.map((i) => i.agent_instance_id),
          actualFiles: Object.values(actualAfter).reduce((n, x) => n + Object.keys(x).length, 0),
          volatileChanged,
        },
        null,
        2,
      ),
      { mode: 0o600 },
    );
    console.log('PASS (' + checks.length + ' integration checks)');
  }
} finally {
  globalThis.fetch = fetchNative;
  setActiveVaultKey(null);
}
