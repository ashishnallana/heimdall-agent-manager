#!/usr/bin/env bash
# Outbound HTTP boundary check (src/lib/httpc/README.md).
#
# Fails when:
#   1. src/lib/http_client (the deleted hand-written client) exists again, or any
#      Odin file imports it;
#   2. any Odin package (src, tests, tools) other than src/lib/httpc imports vendor:curl, foreign-
#      imports libcurl (any "…curl….so/.dylib/.lib/.a" path), declares curl_* bindings
#      or binds a curl_* symbol via link_name;
#   3. httpc's forwarding escape hatches (Request.relay_target, relay_json_body)
#      are used outside the files allowed to forward peer-supplied targets/bodies;
#   4. production code outside the approved packages writes a raw HTTP/1.x request
#      line (an HTTP client hand-rolled over core:net).
#
# Approved raw-request writers (not outbound API clients):
#   src/lib/ws/                                     WebSocket upgrade handshake
#   src/hub/transport/http/shell_session_handlers.odin  preview reverse proxy over the bridge tunnel
#   src/dev_proxy/                                  local development reverse proxy
#
# Usage: scripts/check-http-boundary.sh [repo-root]
#        scripts/check-http-boundary.sh --self-test
set -euo pipefail

RELAY_ALLOWED=(
	src/lib/httpc/
	src/bridge/wrapper_endpoint.odin   # agent.rest.request / agent-actions relay
	src/bridge/hub_runtime_client.odin # hub-relative update download target
)
RAW_HTTP_ALLOWED=(
	src/lib/ws/
	src/hub/transport/http/shell_session_handlers.odin
	src/dev_proxy/
)

allowed() { # path prefix-list...
	local path=$1; shift
	local prefix
	for prefix in "$@"; do
		[[ $path == "$prefix"* ]] && return 0
	done
	return 1
}

check() {
	local root=$1 failures=0 file
	cd "$root"
	if [[ -e src/lib/http_client ]]; then
		echo "FAIL: src/lib/http_client exists; outbound HTTP belongs in src/lib/httpc" >&2
		failures=$((failures + 1))
	fi
	while IFS= read -r file; do
		echo "FAIL: $file imports lib/http_client (deleted; use odin_test:lib/httpc)" >&2
		failures=$((failures + 1))
	done < <(grep -rlE --include='*.odin' 'lib/http_client"' src tests 2>/dev/null || true)

	while IFS= read -r file; do
		allowed "$file" src/lib/httpc/ && continue
		echo "FAIL: $file touches libcurl directly; only src/lib/httpc may (import httpc instead)" >&2
		failures=$((failures + 1))
	done < <(grep -rlE --include='*.odin' \
		-e '"vendor:curl"' \
		-e 'foreign[[:space:]]+import.*curl' \
		-e '"system:(lib)?curl' \
		-e '(^|[^A-Za-z0-9_])curl_[a-z_]+[[:space:]]*::[[:space:]]*proc' \
		-e 'link_name[[:space:]]*=[[:space:]]*"curl_' \
		-e '"[^"]*curl[^"]*\.(so|dylib|lib|a)[^"]*"' \
		src tests tools 2>/dev/null || true)

	while IFS= read -r file; do
		allowed "$file" "${RELAY_ALLOWED[@]}" && continue
		[[ $file == *_test.odin ]] && continue
		echo "FAIL: $file uses httpc relay_target/relay_json_body; build requests from path segments, query params and json_body instead" >&2
		failures=$((failures + 1))
	done < <(grep -rlE --include='*.odin' -e 'relay_target[[:space:]]*=' -e 'relay_json_body[[:space:]]*\(' src 2>/dev/null || true)

	while IFS= read -r file; do
		[[ $file == *_test.odin ]] && continue
		allowed "$file" "${RAW_HTTP_ALLOWED[@]}" && continue
		echo "FAIL: $file writes a raw HTTP request line; outbound HTTP must go through src/lib/httpc" >&2
		failures=$((failures + 1))
	done < <(grep -rlE --include='*.odin' 'HTTP/1\.[01]\\r\\n' src 2>/dev/null || true)

	if ((failures > 0)); then
		echo "check-http-boundary: $failures violation(s)" >&2
		return 1
	fi
	echo "check-http-boundary: OK"
}

self_test() {
	local tmp
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' RETURN
	mkdir -p "$tmp/src/lib/httpc" "$tmp/src/hub" "$tmp/tests"
	echo 'foreign import libcurl "system:curl"' >"$tmp/src/lib/httpc/curl_bindings.odin"
	echo 'package hub' >"$tmp/src/hub/ok.odin"
	check "$tmp" >/dev/null || { echo "self-test: a clean tree was rejected" >&2; return 1; }
	local -a cases=(
		'src/lib/http_client/x.odin|package http_client'
		'src/hub/a.odin|import http "odin_test:lib/http_client"'
		'src/hub/b.odin|import curl "vendor:curl"'
		'src/hub/c.odin|foreign import lc "system:curl"'
		'src/hub/d.odin|curl_easy_init :: proc() -> rawptr ---'
		'src/hub/e.odin|req.relay_target = path'
		'src/hub/f.odin|w(&b, " HTTP/1.1\r\nHost: x\r\n")'
		'tests/g.odin|import curl "vendor:curl"'
		'src/hub/h.odin|@(link_name = "curl_easy_perform") perform :: proc(h: rawptr) -> i32 ---'
		'src/hub/i.odin|	"/usr/lib/x86_64-linux-gnu/libcurl.so.4",'
		'src/bridge/l.odin|foreign import lc "/nix/store/x-curl-static/lib/libcurl.a"'
		'src/ctl/m.odin|	"system:libcurl.lib",'
		'src/manager/n.odin|foreign import lc { "system:curl", "system:ssl" }'
		'tools/j/k.odin|foreign import lc "system:curl"'
	)
	local entry rel content
	for entry in "${cases[@]}"; do
		rel=${entry%%|*}
		content=${entry#*|}
		mkdir -p "$tmp/$(dirname "$rel")"
		printf '%s\n' "$content" >"$tmp/$rel"
		if check "$tmp" >/dev/null 2>&1; then
			echo "self-test: violation not detected: $rel" >&2
			return 1
		fi
		rm -f "$tmp/$rel"
		rmdir "$tmp/src/lib/http_client" 2>/dev/null || true
	done
	echo "check-http-boundary self-test: OK (${#cases[@]} violations detected)"
}

if [[ ${1:-} == --self-test ]]; then
	self_test
else
	check "${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
fi
