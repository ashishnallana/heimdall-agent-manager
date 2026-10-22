#!/usr/bin/env node
// Put a local hub user on a billing plan without a payment provider.
//
//   node scripts/local-runtime/plans.mjs --db <hub.db> --user <name> --plan <free|hobbyist|...>
//
// Writes account_billing in the hub's own SQLite file, the same way an operator
// would. A paid plan is recorded with status 'custom' (an operator-granted plan
// that never expires); 'free' resets the account to the default. The hub
// recomputes the effective entitlements on its next account read and its
// entitlement cache expires within 30s. The user must already exist: make one
// request as that user through the dev proxy first. Idempotent.
// Shared by local-hub.sh (see CONTRACT.md).
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

export function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 2) {
    const k = argv[i].replace(/^--/, '');
    if (!['db', 'user', 'plan'].includes(k) || argv[i + 1] === undefined) throw new Error(`bad argument ${argv[i]}`);
    out[k] = argv[i + 1];
  }
  if (!out.db || !out.user || !out.plan) throw new Error('usage: plans.mjs --db <hub.db> --user <name> --plan <plan_id>');
  return out;
}

export function setPlan({ db, user, plan }) {
  const conn = new DatabaseSync(db);
  try {
    conn.exec('PRAGMA busy_timeout = 5000');
    if (!conn.prepare('SELECT 1 FROM billing_plans WHERE plan_id = ?').get(plan)) {
      throw new Error(`unknown plan '${plan}'`);
    }
    const status = plan === 'free' ? 'free' : 'custom';
    const r = conn.prepare("UPDATE account_billing SET plan_id = ?, status = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE user_id = ?").run(plan, status, user);
    if (r.changes !== 1) throw new Error(`user '${user}' has no billing account yet (make one request as that user first)`);
    return `${user} -> ${plan} (${status})`;
  } finally {
    conn.close();
  }
}

// Compared by real path: the checkout is often reached through a symlink
// (/home -> /var/home), and a plain URL comparison then silently skips main.
if (process.argv[1] && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1])) {
  try {
    console.log(`plans: ${setPlan(parseArgs(process.argv.slice(2)))}`);
  } catch (err) {
    console.error(`plans: ${err.message}`);
    process.exitCode = 1;
  }
}
