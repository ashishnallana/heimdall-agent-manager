import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { syncExtensions, purgeProfiles } from './profile-state.mjs';

const script = join(dirname(fileURLToPath(import.meta.url)), '..', 'local-bridge.sh');
function put(path, data) { mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, data); }

test('isolated extension snapshot is refreshed and never edits checkout files', () => {
  const root = mkdtempSync(join(tmpdir(), 'p1c-sync-'));
  try {
    const checkout = join(root, 'checkout'), instance = join(root, 'instance');
    put(join(checkout, 'extensions', 'claude-code', 'plugin.json'), 'one');
    put(join(checkout, 'extensions', '.agents', 'plugins', 'marketplace.json'), 'marketplace');
    syncExtensions(checkout, instance);
    assert.equal(readFileSync(join(instance, 'data/extensions/claude-code/plugin.json'), 'utf8'), 'one');
    put(join(instance, 'data/extensions', 'stale'), 'old');
    put(join(checkout, 'extensions/claude-code/plugin.json'), 'two');
    syncExtensions(checkout, instance);
    assert.equal(readFileSync(join(instance, 'data/extensions/claude-code/plugin.json'), 'utf8'), 'two');
    assert.equal(readFileSync(join(checkout, 'extensions/claude-code/plugin.json'), 'utf8'), 'two');
    assert.equal(readFileSync(join(instance, 'data/extensions/.agents/plugins/marketplace.json'), 'utf8'), 'marketplace');
    assert.equal(existsSync(join(instance, 'data/extensions/stale')), false);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('profile purge removes only selected instance profiles, secrets and observation caches', () => {
  const root = mkdtempSync(join(tmpdir(), 'p1c-purge-'));
  try {
    for (const name of ['one', 'two']) {
      put(join(root, name, 'data/bridge/provider_profiles.json'), 'settings');
      put(join(root, name, 'data/bridge/profile-secrets/key.bin'), 'secret');
      put(join(root, name, 'home/auth.json'), 'auth');
      put(join(root, name, 'data/bridge/provider_models.json.probe-claude_x/request.tmp'), 'probe');
    }
    purgeProfiles(join(root, 'one'));
    assert.equal(existsSync(join(root, 'one/data/bridge/provider_profiles.json')), false);
    assert.equal(existsSync(join(root, 'one/data/bridge/profile-secrets')), false);
    assert.equal(existsSync(join(root, 'one/home/auth.json')), true);
    assert.equal(existsSync(join(root, 'one/data/bridge/provider_models.json.probe-claude_x')), false);
    assert.equal(existsSync(join(root, 'two/data/bridge/provider_models.json.probe-claude_x/request.tmp')), true);
    assert.equal(existsSync(join(root, 'two/data/bridge/profile-secrets/key.bin')), true);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

function localFixture(root, { isolated = true, vaultFails = false } = {}) {
  const dir = join(root, 'bridges', 'fixture');
  put(join(dir, 'instance.env'), 'KIND=bridge\nHUB_URL=http://127.0.0.1:1\nISOLATED_HOME=' + (isolated ? '1' : '0') + '\n');
  put(join(dir, 'config.toml'), 'daemon_id = "brg_abcdef"\n');
  put(join(dir, 'data/bridge/provider_profiles.json'), 'settings');
  put(join(dir, 'data/bridge/profile-secrets/key.bin'), 'secret');
  put(join(dir, 'home/auth.json'), 'auth');
  put(join(dir, 'credentials/bridge-token'), 'access');
  put(join(dir, 'credentials/bridge-token.refresh'), 'refresh');
  const exe = join(dir, 'bin/ham-bridge');
  put(exe, [
    '#!/bin/sh', 'set -eu',
    'base="$(dirname "$HOME")"',
    'test -d "$base/home"',
    'test -f "$base/data/bridge/profile-secrets/key.bin"',
    'printf "%s\\n" "$*" > "$base/vault-args"',
    'test "$HOME" = "$base/home"',
    vaultFails ? 'exit 7' : 'exit 0',
    '',
  ].join('\n'));
  chmodSync(exe, 0o700);
  return dir;
}
function stop(root) {
  return spawnSync('bash', [script, 'stop', '--name', 'fixture', '--purge-home'], {
    env: { ...process.env, HEIMDALL_LOCAL_STATE_ROOT: root }, encoding: 'utf8',
  });
}

test('stop --purge-home removes vault scope before profiles/home and requires re-enrollment', () => {
  const root = mkdtempSync(join(tmpdir(), 'p1c-stop-'));
  try {
    const dir = localFixture(root);
    // A local instance can use --bin-dir outside its own state directory.
    const external = join(root, 'external-bin');
    mkdirSync(external);
    renameSync(join(dir, 'bin/ham-bridge'), join(external, 'ham-bridge'));
    writeFileSync(join(dir, 'instance.env'), 'BIN_DIR=' + external + '\n', { flag: 'a' });
    const result = stop(root);
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(readFileSync(join(dir, 'vault-args'), 'utf8'), /vault prune --remove-scope brg_abcdef --hub http:\/\/127\.0\.0\.1:1/);
    assert.equal(existsSync(join(dir, 'home')), false);
    assert.equal(existsSync(join(dir, 'data/bridge/profile-secrets')), false);
    assert.equal(existsSync(join(dir, 'data/bridge/provider_profiles.json')), false);
    assert.equal(existsSync(join(dir, 'credentials/bridge-token')), false);
    assert.equal(existsSync(join(dir, 'credentials/bridge-token.refresh')), false);
    assert.match(readFileSync(join(dir, 'config.toml'), 'utf8'), /daemon_id = \"\"/);
    assert.doesNotMatch(readFileSync(join(dir, 'config.toml'), 'utf8'), /brg_abcdef/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('stop --purge-home refuses shared-home instances and preserves state on vault purge failure', () => {
  for (const options of [{ isolated: false }, { isolated: true, vaultFails: true }]) {
    const root = mkdtempSync(join(tmpdir(), 'p1c-stop-refuse-'));
    try {
      const dir = localFixture(root, options);
      const result = stop(root);
      assert.notEqual(result.status, 0);
      assert.equal(existsSync(join(dir, 'home/auth.json')), true);
      assert.equal(existsSync(join(dir, 'data/bridge/profile-secrets/key.bin')), true);
      assert.equal(existsSync(join(dir, 'credentials/bridge-token')), true);
      if (!options.isolated) assert.equal(existsSync(join(dir, 'vault-args')), false);
    } finally { rmSync(root, { recursive: true, force: true }); }
  }
});
