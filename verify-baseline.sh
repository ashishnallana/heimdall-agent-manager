#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p "$HOME/.cache/heimdall-tests"
scratch=$(mktemp -d "$HOME/.cache/heimdall-tests/call-baseline.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
nix develop -c odin build tests/call_reduction_baseline.odin -file -collection:odin_test=src -out:"$scratch/replay"
nix develop -c "$scratch/replay" "$scratch/fixture.db"
