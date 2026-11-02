#!/usr/bin/env bash
# ui-preview.sh — build the renderer and serve it in a ham-ctl shell session so a
# user can open the running UI from Heimdall's preview pane.
#
# What this gets you
# ------------------
# A real browser session against a REAL Hub API (not mocks, not fixtures): the
# bundle talks to `/api/v1/...`, which this preview forwards to a `ham-dev-proxy`
# in front of a running hub. Users sign in only with OIDC (locally via
# tools/mock-oidc); the preview strips hub cookies, so the proxy signs in on your
# behalf and you are its selected dev user (docs/auth-oidc.md, "Local development").
# Anything you click WRITES to that hub — point it at a throwaway or QA hub, never
# at production.
#
# Why a built bundle and not `vite dev`
# ------------------------------------
# A shell session is reachable only under a path prefix the app never sees:
#
#     http://127.0.0.1:<local_endpoint_port>/proxy/<session_id>/<path>
#
# The bridge strips that prefix before dialling the port, so the server sees plain
# paths — but the BROWSER does not, and any URL the page requests at an absolute
# path loses the prefix and 404s. A built bundle with `base: './'` emits relative
# asset URLs that inherit the prefix; `vite dev` emits absolute `/@vite/`, `/src/*`
# and an HMR socket URL that cannot. So: build, then serve.
#
# `/api/v1/...` is the one absolute path a build cannot make relative on its own —
# hence `VITE_API_BASE=.` (see src/ui/api/apiBase.ts). It is opt-in and build-time
# only: a plain `npm run build` sets nothing and emits the usual absolute paths.
#
# Usage:
#   scripts/ui-preview.sh                 # build + serve + verify
#   scripts/ui-preview.sh --no-build      # reuse the existing dist-preview
#   scripts/ui-preview.sh --stop          # kill the session this script started
#
# Env:
#   HEIMDALL_PREVIEW_UPSTREAM  ham-dev-proxy to forward /api/v1 to (default: the
#                              running local-hub.sh instance, else dev-stack.sh's
#                              :8080; see scripts/lib/dev-proxy-upstream.sh)
#   HEIMDALL_PREVIEW_PORT      port the preview server binds       (default 45180)
#   HEIMDALL_PREVIEW_DIR       build output dir                    (default dist-preview)
#   HEIMDALL_PREVIEW_CHAIN     file the session under this task chain   (default: ham-ctl context)
#   HEIMDALL_PREVIEW_PROJECT   file the session under this project      (optional)
#   HAM_CTL                    ham-ctl binary (default: $HEIMDALL_CTL_BIN, else PATH)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# shellcheck source=lib/dev-proxy-upstream.sh
. "$REPO/scripts/lib/dev-proxy-upstream.sh"
PORT="${HEIMDALL_PREVIEW_PORT:-45180}"
DIST="${HEIMDALL_PREVIEW_DIR:-dist-preview}"
HAM_CTL="${HAM_CTL:-${HEIMDALL_CTL_BIN:-ham-ctl}}"
LABEL="ui-preview"
STATE="$REPO/.ui-preview-session"
# preview-server.mjs reads the session's preview_url here to trust the preview origin.
URL_STATE="$REPO/.ui-preview-url"

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

json() { python3 -c 'import json,sys;d,_=json.JSONDecoder().raw_decode(sys.stdin.read().lstrip());exec(sys.argv[1])' "$1"; }

command -v python3 >/dev/null || die "python3 is required (used to read ham-ctl JSON)"

# --- stop ------------------------------------------------------------------
if [[ "${1:-}" == "--stop" ]]; then
  [[ -f "$STATE" ]] || die "no session recorded in $STATE"
  sid="$(cat "$STATE")"
  "$HAM_CTL" shell kill "$sid" >/dev/null && rm -f "$STATE" "$URL_STATE"
  log "killed session $sid"
  exit 0
fi

NO_BUILD=0
[[ "${1:-}" == "--no-build" ]] && NO_BUILD=1

# --- 1. upstream must be up before anything else ---------------------------
# A preview whose API 502s is worse than no preview: it looks like the UI broke.
UPSTREAM="$(dev_proxy_upstream)" \
  || die "no ham-dev-proxy found. Start a local hub (scripts/local-hub.sh start) or set HEIMDALL_PREVIEW_UPSTREAM"
log "checking upstream $UPSTREAM"
# /_dev/api/users is answered by ham-dev-proxy only, so a hub or an unrelated service
# on that port fails here instead of as a broken preview.
code="$(curl -s -o /dev/null -w '%{http_code}' "$UPSTREAM/_dev/api/users" || true)"
[[ "$code" == "2"* ]] \
  || die "$UPSTREAM is not a ham-dev-proxy (GET /_dev/api/users -> '$code'). Start a local hub (scripts/local-hub.sh start) or set HEIMDALL_PREVIEW_UPSTREAM"

# --- 2. build --------------------------------------------------------------
# Separate outDir so a preview build never clobbers the real `dist/`.
if (( NO_BUILD )); then
  log "skipping build (--no-build), using $DIST"
  [[ -f "$DIST/index.html" ]] || die "$DIST/index.html does not exist; run without --no-build"
else
  log "building renderer -> $DIST (VITE_API_BASE=.)"
  VITE_API_BASE=. npx vite build --outDir "$DIST" --emptyOutDir
fi

# --- 3. (re)start the shell session ----------------------------------------
# Replace only this checkout's recorded server. If a start response fails before
# recording it, inspect the Hub's sessions and recover that exact session rather
# than terminating other previews on the same chain.
prev=""
# A chain can contain previews owned by other checkouts. Only replace the session
# recorded by this checkout, never every server sharing a label in the chain.
[[ -f "$STATE" ]] && prev="$(cat "$STATE")"

if [[ -n "$prev" ]]; then
  log "killing previous session(s): $prev"
  for old in $prev; do "$HAM_CTL" shell kill "$old" >/dev/null 2>&1 || true; done
  rm -f "$STATE" "$URL_STATE"
fi

# The kill is asynchronous, and so is a previous run's own shutdown. Starting the
# replacement while anything still holds $PORT gives an EADDRINUSE exit that looks
# like a broken script, so wait for the port to actually go quiet either way.
for _ in $(seq 1 20); do
  (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null || break
  exec 3>&- 3<&-
  sleep 0.5
done
if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
  exec 3>&- 3<&-
  die "port $PORT is still held after 10s — something outside this script is on it:
    ss -ltnp | grep $PORT"
fi

log "starting shell session on port $PORT"
BRIDGE="$("$HAM_CTL" bridge list --scope configured | json 'print(d["data"]["bridges"][0]["daemon_id"])')"
ENDPOINT_PORT="$("$HAM_CTL" bridge list --scope configured | json 'print(d["data"]["bridges"][0]["local_endpoint_port"])')"

# Optional: file the session under a chain/project so it shows up alongside the
# work it belongs to in Heimdall's shells view.
EXTRA=()
# The Hub requires a chain for a server session; default to the caller's own.
CHAIN="${HEIMDALL_PREVIEW_CHAIN:-$("$HAM_CTL" context 2>/dev/null | json 'print(d.get("data",{}).get("data",{}).get("chain_id",""))' 2>/dev/null || true)}"
[[ -n "$CHAIN" ]] && EXTRA+=(--chain "$CHAIN")
[[ -n "${HEIMDALL_PREVIEW_PROJECT:-}" ]] && EXTRA+=(--project "$HEIMDALL_PREVIEW_PROJECT")

# The bridge runs --cmd as `sh -c "exec <cmd>"`. So the command must be a single
# program: no leading `exec` of our own, and the environment goes through `env`
# rather than a `VAR=v` prefix — `exec` would take that prefix for the program name
# and fail with `exec: HEIMDALL_PREVIEW_PORT=45180: not found`.
# Kept as raw text first: if the Hub refuses the start, its JSON error is the only
# thing that explains why, and piping straight into the parser would replace it
# with a KeyError traceback.
START_RESPONSE="$("$HAM_CTL" shell start \
  --bridge "$BRIDGE" \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  --kind server \
  --port "$PORT" \
  --label "$LABEL" \
  --cwd "$REPO" \
  --cmd "env HEIMDALL_PREVIEW_PORT=$PORT HEIMDALL_PREVIEW_UPSTREAM=$UPSTREAM HEIMDALL_PREVIEW_URL_FILE=$URL_STATE HAM_CTL=$HAM_CTL node scripts/preview-server.mjs --dir $DIST")"
SID="$(printf '%s' "$START_RESPONSE" | json 'print(d.get("data",{}).get("data",{}).get("session",{}).get("session_id",""))')"
[[ -n "$SID" ]] || die "shell start returned no session_id. Response was:
$START_RESPONSE"
echo "$SID" > "$STATE"
PREVIEW_URL="$(printf '%s' "$START_RESPONSE" | json 'print(d.get("data",{}).get("data",{}).get("session",{}).get("preview_url",""))')"
[[ -n "$PREVIEW_URL" ]] || die "shell start returned no preview_url for $SID"
printf '%s\n' "$PREVIEW_URL" > "$URL_STATE"

BASE="http://127.0.0.1:$ENDPOINT_PORT/proxy/$SID"

# The session needs a moment to bind before the bridge can dial it. Until then the
# local endpoint answers 409, which is a success as far as curl's exit status is
# concerned — so poll on the status code, not on curl succeeding.
for _ in $(seq 1 40); do
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/")" == "200" ]] && break
  sleep 0.5
done

# --- 4. verify THROUGH the proxy prefix, never the raw port ----------------
# A raw-port check proves nothing about what the user will open.
log "verifying through $BASE"
fail=0
check() { # name expected url
  local got; got="$(curl -s -o /dev/null -w '%{http_code}' "$3" || echo 000)"
  if [[ "$got" == "$2" ]]; then printf '  ok   %-28s %s\n' "$1" "$got"
  else printf '  FAIL %-28s got %s want %s\n' "$1" "$got" "$2"; fail=1; fi
}
ASSET="$(sed -n 's/.*src="\.\/\(assets\/[^"]*\.js\)".*/\1/p' "$DIST/index.html" | head -1)"
check "index.html"  200 "$BASE/"
[[ -n "$ASSET" ]] && check "hashed asset" 200 "$BASE/$ASSET"
check "/api/v1/me" 200 "$BASE/api/v1/me"

# A missing trailing slash (API calls resolve one level up and 404) and a missing
# hash (the router falls back to the prefixed pathname and shows "route not found")
# both paint a loaded-looking page with no data. Neither is fixable server-side — the
# bridge forwards `/proxy/<sid>` and `/proxy/<sid>/` as the same `GET /`, and the hash
# never reaches a server — so preview-server.mjs injects a guard that corrects both in
# the browser. Assert it is present in what the relay actually serves.
if curl -s "$BASE" | grep -q 'data-heimdall-preview-guard'; then
  printf '  ok   %-28s guard present\n' "entry URL self-corrects"
else
  printf '  FAIL %-28s no URL guard in index.html\n' "entry URL self-corrects"; fail=1
fi

log "session:  $SID"
log "preview:  $PREVIEW_URL"
(( fail == 0 )) || die "verification failed — see above"
