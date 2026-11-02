#!/usr/bin/env node
// Offline agent boundary for the profile integration test. Real Claude handles
// plugin operations; managed agent launches record their argv/env and signal
// start-success through the real bridge endpoint, without a cloud model call.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
const args = process.argv.slice(2);
if (args.includes('--version') || args.includes('-v')) {
  console.log('2.1.295 (profile integration shim)');
  process.exit(0);
}
const configDir = process.env.CLAUDE_CONFIG_DIR || path.join(process.env.HOME, '.claude');
fs.mkdirSync(configDir, { recursive: true, mode: 0o700 });
if (args[0] === 'plugin') {
  if (!process.env.P4_REAL_CLAUDE) throw new Error('P4_REAL_CLAUDE is required');
  fs.appendFileSync(
    path.join(configDir, '.p4-plugin-events.jsonl'),
    JSON.stringify({ args, home: process.env.HOME, configDir }) + '\n',
    { mode: 0o600 },
  );
  try {
    execFileSync(process.env.P4_REAL_CLAUDE, args, {
      stdio: 'inherit',
      timeout: 20000,
      env: {
        ...process.env,
        DISABLE_AUTOUPDATER: '1',
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
      },
    });
    process.exit(0);
  } catch (error) {
    process.exit(error.status || 1);
  }
}
const record = {
  args,
  home: process.env.HOME,
  configDir,
  cwd: process.cwd(),
  account: process.env.P4_PROFILE_ACCOUNT,
  xdgConfig: process.env.XDG_CONFIG_HOME,
  xdgData: process.env.XDG_DATA_HOME,
  instanceId: process.env.HEIMDALL_AGENT_INSTANCE_ID,
};
fs.writeFileSync(path.join(configDir, '.p4-launch.json'), JSON.stringify(record), { mode: 0o600 });
execFileSync(process.env.HEIMDALL_CTL_BIN, ['start-success'], { timeout: 10000, stdio: 'ignore' });
console.log('Profile integration agent ready (offline model boundary).');
setInterval(() => {}, 5000);
setTimeout(() => process.exit(0), 120000).unref();
