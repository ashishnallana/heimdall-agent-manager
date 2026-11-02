#!/usr/bin/env node
// Seed an isolated provider home for one local bridge instance (REQ-ISOHOME-2).
//
//   node scripts/local-runtime/provider-home.mjs seed --real-home <dir> --home <dir>
//        [--providers claude,codex,gemini,pi,git] [--trust-root <abs-path>]...
//
// An isolated local bridge runs every provider CLI with HOME=<instance>/home, so
// extensions installed from a local or preview hub land there and never in the
// developer's real ~/.claude, ~/.codex, ... This copies in what a provider needs to
// start already signed in and without first-run dialogs: auth files, account and
// onboarding state, the consent to skip permission prompts, and per-project trust.
// Plugins, marketplaces, hooks, MCP servers, status-line commands, history and
// sessions are NOT copied: nothing that runs code on the real side follows the
// agents into the instance, and the instance starts with no extensions.
//
// The real home is only ever read. Re-running (`local-bridge.sh reseed-auth`)
// re-applies the real values on top of the instance's files and keeps what the
// instance added itself (its installed extensions, its own project trust). Every
// file written is recorded in <home>/.heimdall-home-manifest.json with the source
// path and both checksums, so a test can prove the real home is untouched.
//
// Provider OAuth refresh tokens may rotate on use: a copy that refreshes can end
// the real CLI's session, or the other way round. When that happens, sign in again
// on the real side and reseed. Env credentials (ANTHROPIC_API_KEY,
// CLAUDE_CODE_OAUTH_TOKEN, OPENAI_API_KEY) are passed through by the launcher and
// avoid the problem entirely.
import { createHash } from 'node:crypto';
import {
  accessSync, chmodSync, constants as fsConstants, existsSync, lstatSync, mkdirSync, readFileSync, readlinkSync, realpathSync, renameSync,
  rmSync, symlinkSync, writeFileSync,
} from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const MANIFEST = '.heimdall-home-manifest.json';

// claude: .claude.json keys that carry the signed-in account and skip onboarding.
const CLAUDE_JSON_KEYS = [
  'oauthAccount', 'userID', 'hasCompletedOnboarding', 'lastOnboardingVersion',
  'customApiKeyResponses', 'bypassPermissionsModeAccepted', 'migrationVersion',
  'opusProMigrationComplete', 'sonnet1m45MigrationComplete', 'firstStartTime',
];
// claude: settings.json keys that install or run code (plugins, hooks, MCP servers,
// the status-line command). The real values are dropped; the instance keeps its own.
const CLAUDE_PLUGIN_SETTINGS = ['enabledPlugins', 'extraKnownMarketplaces', 'hooks', 'mcpServers', 'statusLine'];
// gemini CLI / Antigravity settings: MCP servers, hooks, extensions and the tool
// discovery/call commands (current nested and legacy top-level spellings).
const GEMINI_CODE_SETTINGS = [
  'mcpServers', 'hooks', 'hooksConfig', 'extensions', 'plugins', 'toolDiscoveryCommand', 'toolCallCommand',
  'tools.discoveryCommand', 'tools.callCommand', 'mcp',
];
// pi settings: extension packages.
const PI_CODE_SETTINGS = ['packages', 'extensions'];
// JSON settings files filtered by those lists. `nest` also applies the list one
// level down (gemini config/config.json keeps its settings under userSettings).
const JSON_FILTERS = {
  'claude-settings': { drop: CLAUDE_PLUGIN_SETTINGS },
  'gemini-settings': { drop: GEMINI_CODE_SETTINGS, nest: ['userSettings'] },
  'pi-settings': { drop: PI_CODE_SETTINGS },
};
// codex: config.toml tables that install or run code, with the same rule.
const CODEX_PLUGIN_TABLE = /^\[\[?(plugins|marketplaces|hooks|mcp_servers)([.\]])/;

// Per provider: the files seeded. kind copy = verbatim (symlinks into a read-only
// store, e.g. home-manager's /nix/store files, are recreated as symlinks); the
// filter kinds merge real values into the instance's file.
export const PROVIDERS = {
  claude: [
    { path: '.claude/.credentials.json', kind: 'copy' },
    { path: '.claude.json', kind: 'claude-json' },
    { path: '.claude/settings.json', kind: 'claude-settings' },
    { path: '.claude/CLAUDE.md', kind: 'copy' },
  ],
  codex: [
    { path: '.codex/auth.json', kind: 'copy' },
    { path: '.codex/config.toml', kind: 'codex-toml' },
    { path: '.codex/AGENTS.md', kind: 'copy' },
  ],
  // gemini CLI and Antigravity (agy) share ~/.gemini.
  gemini: [
    { path: '.gemini/oauth_creds.json', kind: 'copy' },
    { path: '.gemini/google_accounts.json', kind: 'copy' },
    { path: '.gemini/settings.json', kind: 'gemini-settings' },
    { path: '.gemini/config/config.json', kind: 'gemini-settings' },
    { path: '.gemini/antigravity-cli/antigravity-oauth-token', kind: 'copy' },
    { path: '.gemini/antigravity-cli/settings.json', kind: 'gemini-settings' },
    { path: '.gemini/GEMINI.md', kind: 'copy' },
    { path: '.gemini/CLAUDE.md', kind: 'copy' },
    { path: '.gemini/CODEX.md', kind: 'copy' },
    { path: '.gemini/PI.md', kind: 'copy' },
  ],
  pi: [
    { path: '.pi/agent/auth.json', kind: 'copy' },
    { path: '.pi/agent/settings.json', kind: 'pi-settings' },
  ],
  // git keeps working for agents: identity, ignore rules and https credentials.
  // ssh remotes use the developer's agent (SSH_AUTH_SOCK is passed through).
  git: [
    { path: '.gitconfig', kind: 'copy' },
    { path: '.config/git/config', kind: 'copy' },
    { path: '.config/git/ignore', kind: 'copy' },
    { path: '.git-credentials', kind: 'copy' },
    { path: '.config/gh/hosts.yml', kind: 'copy' },
    { path: '.config/gh/config.yml', kind: 'copy' },
  ],
};
export const ALL_PROVIDERS = Object.keys(PROVIDERS);

const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');

function writeAtomic(file, data) {
  mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.tmp-${process.pid}`;
  writeFileSync(tmp, data, { mode: 0o600 });
  chmodSync(tmp, 0o600);
  renameSync(tmp, file);
}

/** claude .claude.json: account/onboarding/consent keys + project trust flags. */
export function mergeClaudeJson(real, current, trustRoots = []) {
  const out = { ...current };
  for (const key of CLAUDE_JSON_KEYS) if (key in real) out[key] = real[key];
  const projects = { ...(current.projects || {}) };
  const trusted = Object.entries(real.projects || {})
    .filter(([, p]) => p && p.hasTrustDialogAccepted === true).map(([path]) => path);
  for (const path of [...trusted, ...trustRoots]) {
    projects[path] = { ...(projects[path] || {}), hasTrustDialogAccepted: true };
  }
  out.projects = projects;
  return out;
}

function getPath(obj, path) {
  return path.split('.').reduce((o, k) => (o && typeof o === 'object' && k in o ? o[k] : undefined), obj);
}

function setPath(obj, path, value) {
  const keys = path.split('.');
  let o = obj;
  for (const k of keys.slice(0, -1)) {
    if (!o[k] || typeof o[k] !== 'object') {
      if (value === undefined) return; // nothing to remove below a missing parent
      o[k] = {};
    }
    o = o[k];
  }
  if (value === undefined) delete o[keys[keys.length - 1]];
  else o[keys[keys.length - 1]] = value;
}

/**
 * A settings file: the real settings, except the code-running keys `drop` (dotted
 * paths), which come from the instance's own file instead.
 */
export function mergeJsonSettings(real, current, { drop, nest = [] }) {
  const out = structuredClone(real);
  const paths = [...drop, ...nest.flatMap((n) => drop.map((d) => `${n}.${d}`))];
  for (const path of paths) setPath(out, path, getPath(current, path));
  return out;
}

/** claude settings.json: the real settings, but the instance's own plugins and hooks. */
export const mergeClaudeSettings = (real, current) => mergeJsonSettings(real, current, JSON_FILTERS['claude-settings']);

/** Remove `key = ...` (including a multi-line array value) from top-level lines. */
function dropTomlKey(lines, key) {
  const out = [];
  let depth = 0;
  let skipping = false;
  for (const line of lines) {
    if (!skipping && new RegExp(`^${key}\\s*=`).test(line)) skipping = true;
    if (skipping) {
      for (const ch of line.replace(/"(?:[^"\\]|\\.)*"/g, '')) {
        if (ch === '[') depth += 1;
        else if (ch === ']') depth -= 1;
      }
      if (depth <= 0) { skipping = false; depth = 0; }
      continue;
    }
    out.push(line);
  }
  return out;
}

/** Split TOML text into a preamble and [table] blocks (header line + body). */
function tomlBlocks(text) {
  const blocks = [{ header: '', lines: [] }];
  for (const line of text.split('\n')) {
    // A header starts in column 0; an indented `[` continues a multi-line array.
    if (/^\[/.test(line)) blocks.push({ header: line.trim(), lines: [line] });
    else blocks[blocks.length - 1].lines.push(line);
  }
  return blocks;
}

/**
 * codex config.toml: the real config without its plugin tables, plus the
 * instance's own plugin tables and any project trust the instance added.
 * trustRoots get [projects."<path>"] trust_level = "trusted".
 */
export function mergeCodexToml(realText, currentText = '', trustRoots = []) {
  const real = tomlBlocks(realText).filter((b) => !CODEX_PLUGIN_TABLE.test(b.header));
  // Top-level `notify` runs a program on every turn: the real one stays real-side.
  if (real[0] && !real[0].header) real[0] = { ...real[0], lines: dropTomlKey(real[0].lines, 'notify') };
  const headers = new Set(real.map((b) => b.header));
  const kept = tomlBlocks(currentText).filter((b) => b.header
    && (CODEX_PLUGIN_TABLE.test(b.header) || (/^\[projects\./.test(b.header) && !headers.has(b.header))));
  for (const b of kept) headers.add(b.header);
  const extra = trustRoots
    .map((path) => `[projects.${JSON.stringify(path)}]`)
    .filter((h) => !headers.has(h))
    .map((h) => ({ header: h, lines: [h, 'trust_level = "trusted"', ''] }));
  const body = [...real, ...kept, ...extra].map((b) => b.lines.join('\n')).join('\n');
  return body.endsWith('\n') ? body : `${body}\n`;
}

/**
 * A symlink into a read-only store (home-manager's /nix/store files) is recreated as
 * the same symlink. Any other link is copied: a writable target outside the real
 * home (a dotfiles checkout, /etc) would let the instance write back through it.
 */
export function storeLinkTarget(src) {
  if (!lstatSync(src).isSymbolicLink()) return '';
  let target;
  try { target = realpathSync(src); } catch { return ''; }
  if (target.startsWith('/nix/store/')) return target;
  try { accessSync(target, fsConstants.W_OK); return ''; } catch { return target; }
}

/**
 * seed({ realHome, home, providers, trustRoots }) -> manifest. Reads realHome only.
 */
export function seed({ realHome, home, providers = ALL_PROVIDERS, trustRoots = [] }) {
  const realAbs = resolve(realHome);
  const homeAbs = resolve(home);
  if (realAbs === homeAbs || !relative(homeAbs, realAbs).startsWith('..')) {
    throw new Error(`refusing to seed: home ${homeAbs} is the real home or contains it`);
  }
  for (const p of providers) if (!PROVIDERS[p]) throw new Error(`unknown provider '${p}' (${ALL_PROVIDERS.join(', ')})`);
  mkdirSync(homeAbs, { recursive: true, mode: 0o700 });
  const files = [];
  for (const provider of providers) {
    for (const { path, kind } of PROVIDERS[provider]) {
      const src = join(realAbs, path);
      const dst = join(homeAbs, path);
      if (!existsSync(src)) continue;
      const srcBytes = readFileSync(src);
      const link = kind === 'copy' ? storeLinkTarget(src) : '';
      mkdirSync(dirname(dst), { recursive: true, mode: 0o700 });
      if (link) {
        rmSync(dst, { force: true });
        symlinkSync(link, dst);
      } else if (kind === 'copy') {
        writeAtomic(dst, srcBytes);
      } else {
        const current = existsSync(dst) && !lstatSync(dst).isSymbolicLink() ? readFileSync(dst, 'utf8') : '';
        let text;
        if (kind === 'claude-json') {
          text = `${JSON.stringify(mergeClaudeJson(JSON.parse(srcBytes), current ? JSON.parse(current) : {}, trustRoots), null, 2)}\n`;
        } else if (JSON_FILTERS[kind]) {
          text = `${JSON.stringify(mergeJsonSettings(JSON.parse(srcBytes), current ? JSON.parse(current) : {}, JSON_FILTERS[kind]), null, 2)}\n`;
        } else if (kind === 'codex-toml') {
          text = mergeCodexToml(srcBytes.toString('utf8'), current, trustRoots);
        } else {
          throw new Error(`unknown kind ${kind}`);
        }
        if (existsSync(dst) && lstatSync(dst).isSymbolicLink()) rmSync(dst);
        writeAtomic(dst, text);
      }
      files.push({
        provider, path, kind: link ? 'link' : kind, source: src,
        source_sha256: sha256(srcBytes), sha256: sha256(readFileSync(dst)),
        ...(link ? { target: link } : {}),
      });
    }
  }
  // A reseed of some providers keeps the record of the others it did not touch.
  const manifestPath = join(homeAbs, MANIFEST);
  const previous = existsSync(manifestPath) ? JSON.parse(readFileSync(manifestPath, 'utf8')).files || [] : [];
  const allFiles = [...previous.filter((f) => !providers.includes(f.provider)), ...files];
  const manifest = {
    version: 1, real_home: realAbs, home: homeAbs, seeded_at: new Date().toISOString(),
    providers: [...new Set(allFiles.map((f) => f.provider))], requested: providers, files: allFiles,
  };
  writeAtomic(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  return manifest;
}

function main(argv) {
  const [cmd, ...rest] = argv;
  const a = { 'trust-root': [] };
  for (let i = 0; i < rest.length; i += 2) {
    const key = rest[i].replace(/^--/, '');
    if (key === 'trust-root') a[key].push(rest[i + 1]); else a[key] = rest[i + 1];
  }
  if (cmd !== 'seed') throw new Error('usage: provider-home.mjs seed --real-home <dir> --home <dir> [--providers a,b] [--trust-root <path>]...');
  for (const k of ['real-home', 'home']) if (!a[k]) throw new Error(`missing --${k}`);
  const providers = a.providers ? a.providers.split(',').map((s) => s.trim()).filter(Boolean) : ALL_PROVIDERS;
  const m = seed({ realHome: a['real-home'], home: a.home, providers, trustRoots: a['trust-root'] });
  const by = Object.fromEntries(m.requested.map((p) => [p, m.files.filter((f) => f.provider === p).length]));
  console.log(`provider home: ${Object.entries(by).map(([p, n]) => `${p}=${n ? `${n} file${n === 1 ? '' : 's'}` : 'none found'}`).join(' ')}`);
}

if (process.argv[1] && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1])) {
  try { main(process.argv.slice(2)); } catch (err) { console.error(`provider-home: ${err.message}`); process.exit(1); }
}
