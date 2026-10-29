#!/usr/bin/env bash
# Verify a Linux/macOS release tarball carries every provider extension asset
# that `ham-bridge setup` installs from share/heimdall/extensions (F10), including
# the hidden marketplace/plugin manifests, as regular files matching the source.
# No provider login, host service or installer run is required.
set -euo pipefail
[ "$#" -eq 1 ] || { echo 'usage: verify-bundled-extensions.sh <bundle.tar.gz>' >&2; exit 2; }
bundle="$1"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tar -xzf "$bundle" -C "$work" share/heimdall/extensions 2>/dev/null || true
installed="$work/share/heimdall/extensions"
for asset in antigravity/plugin.json antigravity/hooks.json antigravity/hooks/hooks.json \
  claude-code/.claude-plugin/plugin.json claude-code/hooks/hooks.json \
  codex/.codex-plugin/plugin.json codex/hooks/hooks.json \
  .claude-plugin/marketplace.json .agents/plugins/marketplace.json; do
  [ -f "$installed/$asset" ] || { echo "Incomplete provider extension bundle: $asset" >&2; exit 1; }
  if [ -f "$repo/extensions/$asset" ]; then
    cmp -s "$repo/extensions/$asset" "$installed/$asset" || { echo "Provider extension asset differs from source: $asset" >&2; exit 1; }
  fi
done
echo 'Verified: release bundle carries all provider extensions for ham-bridge setup'
