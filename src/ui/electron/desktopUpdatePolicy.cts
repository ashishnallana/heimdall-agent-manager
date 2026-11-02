const fs = require('node:fs');
const path = require('node:path');
// js-yaml is electron-updater's pinned runtime dependency. Parse data, never code.
const yaml = require('js-yaml');
const { execFileSync } = require('node:child_process');
const { UUID } = require('builder-util-runtime');
// Same deterministic identity used by pinned electron-builder 26 NSIS.
const NSIS_GUID = UUID.v5('works.earendil.heimdall', UUID.parse('50e065bc-3134-11e6-9bab-38c9862bdaf3'));

type Eligibility = { supported: boolean; reason: string; currentVersion: string; platform: string; distribution: string };

function evaluatePolicy(input: {
  platform: string; arch: string; isPackaged: boolean; currentVersion: string;
  executable: string; resources: string; writable: boolean; policy: any; feed: any;
  installed?: boolean;
}): Eligibility {
  const result = (reason: string, supported = false): Eligibility => ({
    supported, reason, currentVersion: input.currentVersion, platform: input.platform,
    distribution: typeof input.policy?.distribution === 'string' ? input.policy.distribution : 'unknown',
  });
  if ([input.executable, input.resources].some(p => /(?:^|\/)nix\/store(?:\/|$)/.test(p.replace(/\\/g, '/')))) return result('package-managed');
  if (!input.isPackaged) return result('development');
  if (!['darwin', 'win32'].includes(input.platform)) return result('package-managed');
  if (!(input.platform === 'darwin' ? ['arm64', 'x64'] : ['x64']).includes(input.arch)) return result('unsupported-architecture');
  if (!input.writable || (input.platform === 'darwin' && /^\/Volumes\//.test(input.executable))) return result('read-only-install');
  const policy = input.policy;
  if (!policy || policy.schemaVersion !== 1 || typeof policy.updatesEnabled !== 'boolean') return result('missing-policy');
  if (Object.keys(policy).some(k => !['schemaVersion', 'distribution', 'updatesEnabled', 'publisherName'].includes(k))) return result('invalid-policy');
  if (!policy.updatesEnabled) return result('signing-unavailable');
  if (policy.distribution !== (input.platform === 'darwin' ? 'mac-app' : 'windows-nsis')) return result('unsupported-distribution');
  const feed = input.feed;
  if (!feed || feed.provider !== 'github' || feed.owner !== 'tanmayv' || feed.repo !== 'heimdall-agent-manager'
    || Object.keys(feed).some(key => !['provider', 'owner', 'repo', 'updaterCacheDirName', 'publisherName', 'verifyUpdateCodeSignature', 'channel'].includes(key))
    || feed.token || feed.host || feed.protocol || feed.url || (feed.channel && feed.channel !== 'latest')) return result('invalid-feed');
  if (input.platform === 'win32') {
    if (input.installed !== true) return result('unsupported-distribution');
    const publishers = (v: any): string[] | null => Array.isArray(v) && v.length && v.every(p => typeof p === 'string' && p.trim()) ? v : null;
    const expected = publishers(policy.publisherName);
    const configured = publishers(typeof feed.publisherName === 'string' ? [feed.publisherName] : feed.publisherName);
    if (!expected || !configured || feed.verifyUpdateCodeSignature === false
      || expected.length !== configured.length || !expected.every(p => configured.includes(p))) return result('signing-unavailable');
  }
  return result('signed-install', true);
}

function readEligibility(app: any, runtime: any = process): Eligibility {
  let policy: any = null;
  let feed: any = null;
  let writable = false;
  const executable = app.getPath('exe');
  let resolvedExecutable = executable;
  let resolvedResources = runtime.resourcesPath || '';
  try { resolvedExecutable = fs.realpathSync(executable); resolvedResources = fs.realpathSync(resolvedResources); } catch (_error) { /* Original paths still enforce fail-closed policy below. */ }
  try {
    const policyText = fs.readFileSync(path.join(runtime.resourcesPath, 'desktop-update-policy.json'), 'utf8');
    if (policyText.length < 8192) policy = JSON.parse(policyText);
  } catch (_error) { /* Missing/malformed policy fails closed. */ }
  try {
    const feedText = fs.readFileSync(path.join(runtime.resourcesPath, 'app-update.yml'), 'utf8');
    if (feedText.length < 32768) feed = yaml.load(feedText);
  } catch (_error) { /* Missing/malformed feed fails closed. */ }
  try {
    const installDir = runtime.platform === 'darwin' ? path.resolve(executable, '../../..') : path.dirname(executable);
    fs.accessSync(installDir, fs.constants.W_OK);
    fs.accessSync(path.dirname(installDir), fs.constants.W_OK);
    writable = true;
  } catch (_error) { /* Protected installation fails closed. */ }
  return evaluatePolicy({ platform: runtime.platform, arch: runtime.arch, isPackaged: app.isPackaged,
    currentVersion: app.getVersion(), executable: resolvedExecutable, resources: resolvedResources, writable, policy, feed,
    installed: runtime.platform !== 'win32' || (!runtime.windowsStore && !runtime.env?.PORTABLE_EXECUTABLE_DIR
      && app.isPackaged && policy?.updatesEnabled === true && windowsInstalled(executable, runtime.env)) });
}

function windowsInstalled(executable: string, env: any, execute: any = execFileSync, exists: any = fs.existsSync): boolean {
  const directory = path.win32.dirname(executable);
  if (!env?.SystemRoot || !exists(path.win32.join(directory, 'Uninstall Ninjy.exe'))) return false;
  const reg = path.win32.join(env.SystemRoot, 'System32', 'reg.exe');
  for (const hive of ['HKCU', 'HKLM']) {
    try {
      const output = execute(reg, ['query', `${hive}\\Software\\${NSIS_GUID}`, '/v', 'InstallLocation', '/reg:64'],
        { encoding: 'utf8', timeout: 1500, maxBuffer: 16384, windowsHide: true });
      const match = /^\s*InstallLocation\s+REG_SZ\s+(.+)$/mi.exec(output);
      if (match && path.win32.resolve(match[1].trim()).toLowerCase() === path.win32.resolve(directory).toLowerCase()) return true;
    } catch (_error) { /* Missing registration and unsupported copies fail closed. */ }
  }
  return false;
}

module.exports = { evaluatePolicy, readEligibility, windowsInstalled, NSIS_GUID };
