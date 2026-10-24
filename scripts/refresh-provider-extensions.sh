#!/usr/bin/env bash
# Replace shipped packages as complete generations, retaining unrelated entries.
# Sourced by the update supervisor; executable for installers and Cloudtop.
set -euo pipefail

prepare_provider_extensions() {
  local source="$1" destination="$2" prepared="$3" item parent
  for item in antigravity/plugin.json claude-code/.claude-plugin/plugin.json \
    codex/.codex-plugin/plugin.json .claude-plugin/marketplace.json .agents/plugins/marketplace.json \
    antigravity/hooks.json antigravity/hooks/hooks.json claude-code/hooks/hooks.json codex/hooks/hooks.json; do
    [ -f "$source/$item" ] || { echo "Incomplete provider extension bundle: $source/$item" >&2; return 1; }
  done
  # Never traverse user-created links while replacing nested marketplace files.
  for item in "$destination" "$destination/.claude-plugin" "$destination/.agents" "$destination/.agents/plugins"; do
    [ ! -L "$item" ] || { echo "Refusing symlinked extension destination: $item" >&2; return 1; }
  done
  mkdir -p "$prepared"
  if [ -d "$destination" ]; then
    cp -R -P -p "$destination/." "$prepared/"
  elif [ -e "$destination" ]; then
    echo "Extension destination is not a directory: $destination" >&2
    return 1
  fi
  for item in antigravity claude-code codex; do
    rm -rf "$prepared/$item"
    cp -R -P -p "$source/$item" "$prepared/$item"
  done
  for item in .claude-plugin/marketplace.json .agents/plugins/marketplace.json; do
    parent="${item%/*}"
    mkdir -p "$prepared/$parent"
    rm -f "$prepared/$item"
    cp -P -p "$source/$item" "$prepared/$item"
  done
}

swap_provider_extensions() {
  local prepared="$1" destination="$2" backup="$3"
  if [ -e "$destination" ]; then
    mv "$destination" "$backup"
  fi
  if ! mv "$prepared" "$destination"; then
    if [ -d "$backup" ]; then mv "$backup" "$destination"; fi
    echo "Failed to activate provider extensions: $destination" >&2
    return 1
  fi
}

cleanup_provider_extension_transaction() {
  local transaction="$1" destination="$2"
  # An interruption between the two renames must not delete the only old copy.
  if [ -d "$transaction/old" ] && [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
    if ! mv "$transaction/old" "$destination"; then
      echo "Extension backup retained for recovery: $transaction/old" >&2
      return 1
    fi
  fi
  rm -rf "$transaction"
}

refresh_provider_extensions() (
  local source="$1" destination="$2" transaction
  mkdir -p "$(dirname "$destination")"
  transaction="$(mktemp -d "$(dirname "$destination")/.extensions-refresh.XXXXXX")"
  trap 'cleanup_provider_extension_transaction "$transaction" "$destination"' EXIT
  prepare_provider_extensions "$source" "$destination" "$transaction/new"
  swap_provider_extensions "$transaction/new" "$destination" "$transaction/old"
)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <bundled-extensions> <installed-extensions>" >&2
    exit 2
  fi
  refresh_provider_extensions "$1" "$2"
fi
