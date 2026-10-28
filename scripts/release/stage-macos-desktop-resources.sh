#!/usr/bin/env bash
set -euo pipefail

# REQ-DMG-1: stage the architecture-matched, already Developer ID-signed Bridge
# archive beside the desktop app. electron-builder copies this directory into
# Contents/Resources/bridge without modifying the verified archive.
usage() {
  echo 'usage: stage-macos-desktop-resources.sh <darwin-arm64|darwin-amd64> <bundle.tar.gz> <version> [out-dir]' >&2
}

[ "$#" -ge 3 ] && [ "$#" -le 4 ] || { usage; exit 2; }
target="$1"
bundle="$2"
version="$3"
out_dir="${4:-release-assets/bridge}"

case "$target" in darwin-arm64|darwin-amd64) ;; *) usage; exit 2 ;; esac
[ -f "$bundle" ] || { echo "missing Bridge bundle: $bundle" >&2; exit 1; }
# Fail before building/publishing a DMG whose embedded installer cannot deliver
# the provider extensions, including hidden marketplace and plugin manifests.
bash scripts/release/verify-bundled-extensions.sh "$bundle" scripts/install.sh

archive="heimdall-local-$target.tar.gz"
rm -rf "$out_dir"
mkdir -p "$out_dir"
install -m 0755 scripts/install.sh "$out_dir/install.sh"
install -m 0644 "$bundle" "$out_dir/$archive"

case "$(uname -s)" in
  Darwin) hash="$(shasum -a 256 < "$bundle")" ;;
  *) hash="$(sha256sum < "$bundle")" ;;
esac
hash="${hash%% *}"
printf '%s  %s\n' "$hash" "$archive" > "$out_dir/SHA256SUMS"

tar -xOf "$bundle" METADATA.json > "$out_dir/METADATA.json"
metadata_version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$out_dir/METADATA.json" | head -n 1)"
[ "${metadata_version#v}" = "${version#v}" ] || {
  echo "bundle metadata version $metadata_version does not match requested $version" >&2
  exit 1
}
grep -q '"developer_id_signed"[[:space:]]*:[[:space:]]*true' "$out_dir/METADATA.json" || {
  echo 'bundle metadata says its macOS binaries are not Developer ID signed' >&2
  exit 1
}

echo "$out_dir"
