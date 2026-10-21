#!/usr/bin/env bash
# Scoped preview-isolation check: builds only the two Odin test packages that own
# preview transport and preview config, and runs only the preview security cases.
#
#   bash scripts/local-preview-security-check.sh          # from any cwd
#
# Covers:
#   - dedicated-origin forwarding keeps X-Heimdall-Device-{Id,Ts,Nonce,Sig}; the
#     legacy same-origin route drops them, hub cookies, identity headers and Bearer;
#   - the preview Host serves no Hub API/static route; the legacy route is a 404 once
#     --preview-origin is set (default) and a "/p/" path on the Hub origin is not the
#     dedicated transport;
#   - --preview-legacy-path defaults to false and the startup notice flags unsafe modes.
#
# odin comes from `nix develop` (re-exec'd automatically unless already inside it). Test binaries go under $HOME/.cache/heimdall-tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${HEIMDALL_TEST_OUT:-$HOME/.cache/heimdall-tests/preview-security}"

# Always build inside the pinned dev shell: a host odin (e.g. linuxbrew) may be on
# PATH and is too old for src/hub.
if [[ -z "${IN_NIX_SHELL:-}" ]]; then
	cd "$ROOT"
	exec nix develop "$ROOT" -c bash "$ROOT/scripts/local-preview-security-check.sh"
fi

mkdir -p "$OUT"
cd "$ROOT"

HTTP_TESTS=(
	test_preview_request_builder_allowlist_and_forward_context
	test_preview_request_builder_empty_forward_context
	test_preview_request_builder_websocket_passthrough
	test_preview_request_builder_dedicated_origin_forwards_device_signature
	test_preview_request_builder_legacy_drops_device_signature_cookie_and_bearer
	test_preview_request_builder_legacy_authorization_audit
	test_preview_origin_host_matching
	test_preview_origin_dispatch_precedes_all_hub_routing
	test_preview_origin_legacy_gate_and_owner_check
	test_preview_origin_foreign_and_missing_sessions_are_identical_404_without_tunnel_open
	test_preview_origin_cookie_filter
	test_preview_origin_referrer_policy_default
	test_preview_origin_host_serves_no_hub_api_or_static_routes
	test_preview_legacy_route_fails_closed_with_dedicated_origin
	test_csrf_decision_table
	test_metrics_preview_request_bytes_and_tunnel_gauge
)
APP_TESTS=(
	test_preview_origin_validation
	test_preview_legacy_path_defaults_closed_and_notice
)

# ODIN_TEST_NAMES is a build-time filter of package-qualified names.
qualify() { local pkg="$1"; shift; local IFS=,; local names=("${@/#/$pkg.}"); echo "${names[*]}"; }

run_pkg() {
	local dir="$1" bin="$2" names="$3"
	echo "== build $dir"
	odin build "$dir" -build-mode:test -collection:odin_test=src \
		-define:ODIN_TEST_NAMES="$names" -define:ODIN_TEST_FANCY=false -out:"$OUT/$bin"
	echo "== run $bin"
	timeout 300 "$OUT/$bin"
}

run_pkg src/hub/transport/http preview-security-http "$(qualify http "${HTTP_TESTS[@]}")"
run_pkg src/hub/app preview-security-app "$(qualify app "${APP_TESTS[@]}")"
echo "PASS: preview security scoped checks"
