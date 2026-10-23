#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p "$HOME/.cache/heimdall-tests"
scratch=$(mktemp -d "$HOME/.cache/heimdall-tests/hotpath-writes.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
nix develop -c odin test tests/hotpath_writes_test.odin -file -collection:odin_test=src -out:"$scratch/tests" -define:ODIN_TEST_FANCY=false
bash verify-baseline.sh
nix develop -c odin build src/hub -collection:odin_test=src -out:"$scratch/hub"
printf "Hub build succeeded.\n"
