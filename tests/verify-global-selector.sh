#!/usr/bin/env bash
# Focused selector verification. Uses an existing npm toolchain; never installs dependencies.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
if [[ ! -d node_modules ]]; then
  echo "Missing node_modules: provision the existing project toolchain before verification." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain=v1)" ]]; then
  echo "Verification requires a clean committed source tree." >&2
  exit 1
fi
source_head="$(git rev-parse HEAD)"
evidence_dir="${SELECTOR_VERIFY_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/heimdall-global-selector.XXXXXX")}"
mkdir -p "$evidence_dir"
evidence_dir="$(cd "$evidence_dir" && pwd)"
echo "Selector verification source: $source_head"
echo "Evidence: $evidence_dir"
git status --porcelain=v1 > "$evidence_dir/status.before"
node --version | tee "$evidence_dir/node-version.txt"
npm --version | tee "$evidence_dir/npm-version.txt"

node --import ./tests/helpers/vaultEndpointHarness.ts --test --test-reporter=tap \
  tests/ui_global_chain_selector_test.ts \
  tests/ui_task_chain_selector_test.ts \
  tests/ui_home_chain_search_test.ts \
  tests/ui_pane_switchers_test.ts \
  tests/ui_global_title_search_test.ts \
  tests/ui_scoped_search_test.ts \
  tests/ui_search_boxes_armor_shield_test.ts \
  | tee "$evidence_dir/ui-tests.tap"
npm run typecheck 2>&1 | tee "$evidence_dir/typecheck.log"
node node_modules/vite/bin/vite.js build --outDir "$evidence_dir/ui" --emptyOutDir \
  2>&1 | tee "$evidence_dir/vite-build.log"

test "$source_head" = "$(git rev-parse HEAD)"
git status --porcelain=v1 > "$evidence_dir/status.after"
cmp "$evidence_dir/status.before" "$evidence_dir/status.after"
node --input-type=module - "$evidence_dir" "$source_head" <<'JS'
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
const [evidenceDir, head] = process.argv.slice(2);
const hash = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const sources = [
  'src/ui/components/workbench/AgentChatPane.tsx',
  'src/ui/components/chains/TaskChainSelectorModal.tsx',
  'src/ui/components/chains/taskChainSelectorLogic.ts',
  'tests/ui_global_chain_selector_test.ts',
  'tests/ui_task_chain_selector_test.ts',
  'tests/verify-global-selector.sh',
  'package.json', 'package-lock.json',
];
const walk = (dir) => fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
  const full = path.join(dir, entry.name);
  return entry.isDirectory() ? walk(full) : [full];
});
const tap = fs.readFileSync(path.join(evidenceDir, 'ui-tests.tap'), 'utf8');
const count = (label) => Number(tap.match(new RegExp('^# ' + label + ' (\\d+)$', 'm'))?.[1] ?? NaN);
if (!count('tests') || count('pass') !== count('tests') || count('fail') !== 0 ||
    count('skipped') !== 0 || count('cancelled') !== 0) throw new Error('Incomplete UI test result');
const manifest = {
  head, clean: true, repo: process.cwd(), node: process.version,
  nodeModules: fs.realpathSync('node_modules'),
  tests: { total: count('tests'), passed: count('pass'), failed: count('fail'), skipped: count('skipped') },
  typecheck: 'passed', productionUiBuild: 'passed',
  sourceSha256: Object.fromEntries(sources.map((file) => [file, hash(file)])),
  artifactSha256: Object.fromEntries(walk(path.join(evidenceDir, 'ui')).sort().map((file) => [path.relative(evidenceDir, file), hash(file)])),
};
fs.writeFileSync(path.join(evidenceDir, 'artifact-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
console.log(JSON.stringify({ head, tests: manifest.tests, manifest: path.join(evidenceDir, 'artifact-manifest.json') }));
JS
