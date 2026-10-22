#!/usr/bin/env bash
set -euo pipefail
S=$HOME/.cache/heimdall-tests/cri-timing
for side in base:$S/base int:/home/tanmay/hamwt/call-reduction-integration; do
  n=${side%%:*}; d=${side#*:}
  (cd "$d" && nix develop -c odin build tests/call_reduction_baseline.odin -file -collection:odin_test=src -out:"$S/replay-$n")
done
cd /home/tanmay/hamwt/call-reduction-integration
for i in $(seq 1 15); do
  for n in base int; do
    rm -f "$S/fx-$n.db"*
    nix develop -c "$S/replay-$n" "$S/fx-$n.db" > "$S/out-$n-$i.txt"
  done
done
echo done
