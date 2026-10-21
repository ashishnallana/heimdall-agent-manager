#!/usr/bin/env bash
# Installs the repo's pre-commit checks into .git/hooks/pre-commit (shared by
# every worktree). Leaves other hooks and any existing pre-commit content alone;
# re-running is a no-op.
set -euo pipefail

hooks="$(git rev-parse --git-common-dir)/hooks"
hook="$hooks/pre-commit"
marker="# heimdall: check-npm-deps-hash"

mkdir -p "$hooks"
if [[ -f "$hook" ]] && grep -qF "$marker" "$hook"; then
  echo "pre-commit hook already installed: $hook"
  exit 0
fi
[[ -f "$hook" ]] || printf '#!/bin/sh\n' >"$hook"
cat >>"$hook" <<EOF

$marker
script="\$(git rev-parse --show-toplevel)/scripts/check-npm-deps-hash.sh"
if [ -x "\$script" ]; then "\$script" --staged || exit 1; fi
EOF
chmod +x "$hook"
echo "installed pre-commit hook: $hook"
