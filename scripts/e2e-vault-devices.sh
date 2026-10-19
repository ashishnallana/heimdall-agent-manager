#!/usr/bin/env bash
# P2.5 passwordless-vault API end-to-end test (docs/plans/passwordless-vault.md §2).
# Builds ham-hub from this tree into $HOME/.cache/heimdall-e2e, then runs
# tests/e2e/vault_devices_api_e2e.mjs, which starts a THROWAWAY hub (ephemeral port,
# temp DB and dirs) and never touches a running dev hub/bridge or the OS keystore.
#
#   bash scripts/e2e-vault-devices.sh [--skip-build]
# Env: ODIN (odin binary), HEIMDALL_SQLITE_LIBPATH (Windows/Git Bash: dir holding sqlite3.lib).
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${HOME}/.cache/heimdall-e2e"
mkdir -p "$out_dir"
extra=()
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    odin="${ODIN:-${LOCALAPPDATA:-}/Programs/Odin/dist/odin.exe}"
    hub="$out_dir/ham-hub-e2e.exe"
    libpath="${HEIMDALL_SQLITE_LIBPATH:-${USERPROFILE:-$HOME}/heimdall-win-build/deps/lib}"
    extra=("-extra-linker-flags:/LIBPATH:${libpath//\\//}")
    ;;
  *)
    odin="${ODIN:-odin}"
    hub="$out_dir/ham-hub-e2e"
    ;;
esac

if [[ "${1:-}" != "--skip-build" ]]; then
  echo "building hub -> $hub"
  "$odin" build "$repo/src/hub" "-collection:odin_test=$repo/src" "${extra[@]}" "-out:$hub" || { echo "FAIL hub build"; exit 1; }
fi

cd "$repo"
HEIMDALL_E2E_HUB_BIN="$hub" \
HEIMDALL_E2E_MIGRATIONS_DIR="$repo/src/hub/repository/sqlite/migrations" \
  exec node --import ./tests/helpers/vaultEndpointHarness.ts tests/e2e/vault_devices_api_e2e.mjs
