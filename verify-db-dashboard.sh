#!/usr/bin/env bash
# Verify the Grafana dashboards for the phase-1 DB telemetry (Hub DB).
# Static only: no Grafana, no live Prometheus, nothing deployed or written
# outside a temp dir.
set -euo pipefail
cd "$(dirname "$0")"
root=$(pwd)
graf=tools/telemetry/hub/grafana
tmp=$(mktemp -d "${TMPDIR:-/tmp}/db-dashboard-verify.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

echo "== 1. generator reproducibility"
python3 -m py_compile $graf/gen_dashboards.py $graf/check_dashboards.py
# Run a copy so the committed JSON is not touched.
mkdir -p "$tmp/grafana"
cp $graf/gen_dashboards.py "$tmp/grafana/"
python3 "$tmp/grafana/gen_dashboards.py" >/dev/null
for f in "$tmp"/grafana/dashboards/*.json; do
  name=$(basename "$f")
  if ! cmp -s "$f" "$graf/dashboards/$name"; then
    diff -u "$graf/dashboards/$name" "$f" | head -40
    echo "FAIL: $name differs from gen_dashboards.py output (re-run the generator and commit)"
    exit 1
  fi
done
echo "generated: $(ls "$tmp"/grafana/dashboards | tr '\n' ' ')- byte-identical to committed JSON"

echo "== 2. JSON, UIDs, panel ids, datasource, metrics/labels vs src/ and the reference"
python3 $graf/check_dashboards.py "$root" "$tmp/dashboard-rules.yml"

echo "== 3. PromQL syntax (promtool check rules; no server queried)"
if command -v promtool >/dev/null 2>&1; then
  promtool check rules "$tmp/dashboard-rules.yml"
else
  nix shell nixpkgs#prometheus.cli --command promtool check rules "$tmp/dashboard-rules.yml"
fi

echo "verify-db-dashboard: ALL PASS"
