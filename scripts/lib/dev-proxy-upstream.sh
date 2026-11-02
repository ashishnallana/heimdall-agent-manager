# shellcheck shell=bash
# dev_proxy_upstream: the ham-dev-proxy a preview script forwards /api/v1 to.
# Sourced by scripts/dev-preview.sh and scripts/ui-preview.sh, never executed.
#
# First match wins:
#   1. $HEIMDALL_PREVIEW_UPSTREAM
#   2. a running scripts/local-hub.sh instance: $HEIMDALL_LOCAL_HUB (default
#      "default") first, then any other instance whose proxy answers
#   3. scripts/dev-stack.sh's proxy ($HAM_DEV_PROXY_ADDR, default 127.0.0.1:8080)
# Prints nothing (and returns 1) when none answers.

_dev_proxy_answers() { # <base-url>
  curl -s -o /dev/null -m 2 "$1/api/v1/health" 2>/dev/null
}

dev_proxy_upstream() {
  if [ -n "${HEIMDALL_PREVIEW_UPSTREAM:-}" ]; then
    printf '%s\n' "${HEIMDALL_PREVIEW_UPSTREAM%/}"
    return 0
  fi
  local root="${HEIMDALL_LOCAL_STATE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/heimdall-local}"
  local preferred="$root/hubs/${HEIMDALL_LOCAL_HUB:-default}/instance.env" env url
  for env in "$preferred" "$root"/hubs/*/instance.env; do
    [ -f "$env" ] || continue
    url="$(grep -E '^PROXY_URL=' "$env" | tail -1 | cut -d= -f2-)"
    if [ -n "$url" ] && _dev_proxy_answers "$url"; then
      printf '%s\n' "$url"
      return 0
    fi
  done
  url="http://${HAM_DEV_PROXY_ADDR:-127.0.0.1:8080}"
  if _dev_proxy_answers "$url"; then
    printf '%s\n' "$url"
    return 0
  fi
  return 1
}
