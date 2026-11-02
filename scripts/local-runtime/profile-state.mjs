// Instance-local snapshots/cleanup. ham-bridge vault prune removes OS keys first.
import { cpSync, existsSync, readFileSync, writeFileSync, mkdirSync, renameSync, rmSync, realpathSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export function syncExtensions(checkout, instance) {
  const source = join(checkout, 'extensions');
  if (!existsSync(source)) throw new Error('checkout extensions missing: ' + source);
  const data = join(instance, 'data');
  const target = join(data, 'extensions');
  const temp = target + '.new', backup = target + '.bak';
  mkdirSync(data, { recursive: true });
  rmSync(temp, { recursive: true, force: true });
  cpSync(source, temp, { recursive: true, dereference: true });
  rmSync(backup, { recursive: true, force: true });
  if (existsSync(target)) renameSync(target, backup);
  try { renameSync(temp, target); }
  catch (error) {
    if (existsSync(backup) && !existsSync(target)) renameSync(backup, target);
    throw error;
  }
  rmSync(backup, { recursive: true, force: true });
}

export function purgeProfiles(instance) {
  const data = join(instance, 'data', 'bridge');
  if (existsSync(data)) {
    for (const name of readdirSync(data)) {
      if (name === 'provider_models.json.probe' || name.startsWith('provider_models.json.probe-')) {
        rmSync(join(data, name), { recursive: true, force: true });
      }
    }
  }
  for (const name of ['provider_profiles.json', 'provider_profiles.json.tmp', 'profile-secrets', 'provider_paths.json', 'provider_models.json']) {
    rmSync(join(data, name), { recursive: true, force: true });
  }
  // Vault scope is already pruned. The saved enrolled ID must not survive
  // deletion of its identity/credential pair, or enrollment treats this managed
  // config as an existing bridge instead of creating a fresh one.
  const config = join(instance, 'config.toml');
  if (existsSync(config)) {
    const before = readFileSync(config, 'utf8');
    const after = before.replace(/^(\s*daemon_id\s*=\s*)"brg_[^"]*"/m, (_match, prefix) => prefix + '""');
    if (after !== before) {
      const temp = config + '.purge-' + process.pid;
      try {
        writeFileSync(temp, after, { mode: 0o600, flag: 'wx' });
        renameSync(temp, config);
      } finally { rmSync(temp, { force: true }); }
    }
  }
}

function main(argv) {
  const [action, ...args] = argv;
  const opts = {};
  for (let i = 0; i < args.length; i += 2) opts[args[i].replace(/^--/, '')] = args[i+1];
  if (!opts.instance || !['sync', 'purge'].includes(action)) throw new Error('profile-state.mjs sync|purge --instance DIR [--checkout DIR]');
  const instance = resolve(opts.instance);
  if (action === 'sync') {
    if (!opts.checkout) throw new Error('sync requires --checkout');
    syncExtensions(resolve(opts.checkout), instance);
  } else { purgeProfiles(instance); }
}
if (process.argv[1] && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1])) {
  try { main(process.argv.slice(2)); } catch (error) { console.error('profile-state: ' + error.message); process.exit(1); }
}
