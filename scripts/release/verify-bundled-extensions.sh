#!/usr/bin/env bash
# Exercise the shipped installer's extraction and extension activation against
# the real release archive. No provider login or host service is required.
set -euo pipefail
[ "$#" -eq 2 ] || { echo 'usage: verify-bundled-extensions.sh <bundle.tar.gz> <installer.sh>' >&2; exit 2; }
bundle="$1"
installer="$2"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
archive="$(basename "$bundle")"
cp "$bundle" "$work/$archive"
case "$(uname -s)" in
  Darwin) digest="$(shasum -a 256 < "$bundle")" ;;
  *) digest="$(sha256sum < "$bundle")" ;;
esac
printf '%s  %s\n' "${digest%% *}" "$archive" > "$work/SHA256SUMS"
# The final main invocation is the only top-level action in install.sh.
sed '/^main "\$@"$/d' "$installer" > "$work/installer-library.sh"
source "$work/installer-library.sh"
extract_bundle "$work" "$archive"
[ -f "$work/refresh-provider-extensions.sh" ] || { echo 'Bundle has no extension install helper' >&2; exit 1; }
source "$work/refresh-provider-extensions.sh"
source_extensions="$work/share/heimdall/extensions"
installed="$work/installed/extensions"
refresh_provider_extensions "$source_extensions" "$installed"
for asset in antigravity/plugin.json antigravity/hooks.json antigravity/hooks/hooks.json \
  claude-code/.claude-plugin/plugin.json claude-code/hooks/hooks.json \
  codex/.codex-plugin/plugin.json codex/hooks/hooks.json \
  .claude-plugin/marketplace.json .agents/plugins/marketplace.json; do
  cmp "$source_extensions/$asset" "$installed/$asset"
done
printf '%s\n' stale > "$installed/claude-code/removed-hook"
mkdir -p "$installed/user-plugin"
printf '%s\n' keep > "$installed/user-plugin/custom"
refresh_provider_extensions "$source_extensions" "$installed"
[ ! -e "$installed/claude-code/removed-hook" ]
[ "$(cat "$installed/user-plugin/custom")" = keep ]
echo 'Verified: release installer installs and refreshes all bundled provider extensions'
