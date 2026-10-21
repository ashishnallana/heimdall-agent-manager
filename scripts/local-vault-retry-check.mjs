#!/usr/bin/env node
// Focused check for device-vault registration under auth failures: runs only the
// device-vault suites through the node:test harness `npm test` uses, never the full UI
// suite. Run from the repository root (after `npm ci --legacy-peer-deps`):
//
//   node scripts/local-vault-retry-check.mjs

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const TESTS = [
  'tests/ui_vault_retry_test.ts',
  'tests/ui_vault_pairing_flow_test.ts',
  'tests/ui_device_vault_test.ts',
  'tests/ui_vault_device_gate_test.ts',
  'tests/ui_vault_revoked_status_test.ts',
];

if (!fs.existsSync(path.join(root, 'node_modules', 'esbuild'))) {
  console.error(`local-vault-retry-check: no node_modules in ${root}; run 'npm ci --legacy-peer-deps' there first.`);
  process.exit(2);
}

const args = ['--import', './tests/helpers/vaultEndpointHarness.ts', '--test', ...TESTS];
console.log(`local-vault-retry-check: node ${args.join(' ')}`);
const res = spawnSync(process.execPath, args, { cwd: root, stdio: 'inherit' });
if (res.error) {
  console.error(`local-vault-retry-check: ${res.error.message}`);
  process.exit(1);
}
process.exit(res.status ?? 1);
