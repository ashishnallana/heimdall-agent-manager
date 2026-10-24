#!/usr/bin/env bash
# scripts/release/bump-version.sh
# Synchronizes the application version, git commit, and build timestamp across
# flake.nix and src/contracts/protocol.odin (REQ-REL-VER-SYNC-1).
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: bump-version.sh [--version-only] <version> [commit_sha] [build_timestamp]

Arguments:
  <version>          Semver version string (e.g. "0.3.3" or "v0.3.3")
  [commit_sha]       Optional git commit short SHA (default: git rev-parse --short HEAD)
  [build_timestamp]  Optional ISO 8601 UTC timestamp (default: current UTC time)

Options:
  --version-only     Update durable version fields without changing build metadata

Examples:
  ./scripts/release/bump-version.sh 0.3.3
  ./scripts/release/bump-version.sh --version-only 0.3.3
  ./scripts/release/bump-version.sh v0.3.3 abcdef12 2026-10-01T12:00:00Z
USAGE
}

# Portable in-place sed helper supporting Darwin (BSD sed) and Linux (GNU sed).
sed_i() {
  if [ "$(uname -s)" = "Darwin" ]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

VERSION_ONLY=false
if [ "${1:-}" = "--version-only" ]; then
  VERSION_ONLY=true
  shift
fi

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "$#" -lt 1 ]; then
  usage
  exit 0
fi

RAW_VERSION="$1"
CLEAN_VERSION="${RAW_VERSION#v}"

# Validate semantic version syntax (e.g. 0.3.3, 0.3.3-beta.1)
if ! [[ "$CLEAN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "ERROR: Invalid semantic version format: '$RAW_VERSION'" >&2
  exit 1
fi

COMMIT_SHA="${2:-}"
if [ "$VERSION_ONLY" = false ] && [ -z "$COMMIT_SHA" ]; then
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    COMMIT_SHA="$(git rev-parse --short=8 HEAD 2>/dev/null || true)"
  fi
fi

TIMESTAMP="${3:-}"
if [ "$VERSION_ONLY" = false ] && [ -z "$TIMESTAMP" ]; then
  TIMESTAMP="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

echo "==> Stamping version across Heimdall project files:"
echo "    Version:         $CLEAN_VERSION (tag: v$CLEAN_VERSION)"
if [ "$VERSION_ONLY" = true ]; then
  echo "    Build metadata:  unchanged"
else
  echo "    Commit SHA:      ${COMMIT_SHA:-'(none)'}"
  echo "    Build Timestamp: $TIMESTAMP"
fi

# Stamp provider manifests/marketplaces and append a registered forward catalog
# migration when the release minimum changes. Historical SQL stays immutable.
if [ -d extensions ]; then
  python3 scripts/release/stamp-provider-versions.py "$CLEAN_VERSION"
  echo "    [ok] Synchronized provider packages and catalog release minimum"
fi

# 1. Update flake.nix appVersion
if [ -f "flake.nix" ]; then
  sed_i "s/appVersion = \".*\";/appVersion = \"$CLEAN_VERSION\";/" flake.nix
  echo "    [ok] Updated flake.nix (appVersion = \"$CLEAN_VERSION\")"
fi

# 2. Update src/contracts/protocol.odin defaults
if [ -f "src/contracts/protocol.odin" ]; then
  sed_i "s/APP_VERSION :: #config(HAM_APP_VERSION, \".*\")/APP_VERSION :: #config(HAM_APP_VERSION, \"$CLEAN_VERSION\")/" src/contracts/protocol.odin
  if [ "$VERSION_ONLY" = false ] && [ -n "$COMMIT_SHA" ]; then
    sed_i "s/GIT_COMMIT :: #config(HAM_GIT_COMMIT, \".*\")/GIT_COMMIT :: #config(HAM_GIT_COMMIT, \"$COMMIT_SHA\")/" src/contracts/protocol.odin
  fi
  if [ "$VERSION_ONLY" = false ]; then
    sed_i "s/BUILD_TIMESTAMP :: #config(HAM_BUILD_TIMESTAMP, \".*\")/BUILD_TIMESTAMP :: #config(HAM_BUILD_TIMESTAMP, \"$TIMESTAMP\")/" src/contracts/protocol.odin
  fi
  echo "    [ok] Updated src/contracts/protocol.odin"
fi

# package.json/package-lock.json deliberately keep their dependency-manifest
# version. Changing only their root package version changes package-lock.json
# byte-for-byte without changing any dependency, which makes Nix reject the
# existing fetchNpmDeps output as stale on every release bump. Runtime binaries
# receive their version from HAM_APP_VERSION above.

echo "==> Version synchronization complete."
