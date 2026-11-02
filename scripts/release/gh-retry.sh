# shellcheck shell=bash
# Sourced by the release workflow's Publish job. GitHub's release API
# occasionally answers a correctly-permissioned job token with
# "HTTP 403: Resource not accessible by integration", 5xx, or a dropped
# connection (release run 41329637092). retry_transient re-runs one command
# with bounded exponential backoff on those errors only; any other failure
# (bad flags, missing files, real 404/422) returns at once with its status.
#
# The command may be a shell function: it runs in the current shell (stderr is
# redirected, not piped), so functions can set globals. Callers under `set -e`
# must use `retry_transient ... || rc=$?`; errexit is suppressed inside.

GH_RETRY_TRANSIENT_PATTERN='HTTP 403: Resource not accessible by integration|HTTP 429|HTTP 5[0-9][0-9]|secondary rate limit|rate limit exceeded|connection reset|connection refused|connection lost|unexpected EOF|i/o timeout|TLS handshake timeout|timed out|timeout awaiting|no such host|network is unreachable|server error'

# retry_transient <description> <command> [args...]
retry_transient() {
  local description="$1"
  shift
  local max_attempts="${HEIMDALL_GH_RETRY_MAX_ATTEMPTS:-5}"
  local delay="${HEIMDALL_GH_RETRY_DELAY_SECONDS:-10}"
  local max_delay="${HEIMDALL_GH_RETRY_MAX_DELAY_SECONDS:-60}"
  case "$max_attempts:$delay:$max_delay" in
    *[!0-9:]*|0:*|:*|*::*|*:)
      echo "gh retry settings must be non-negative integers and attempts must be greater than zero." >&2
      return 2
      ;;
  esac
  local err_file attempt=1 status
  err_file="$(mktemp)"
  while :; do
    echo "$description (attempt $attempt/$max_attempts)"
    status=0
    "$@" 2>"$err_file" || status=$?
    cat "$err_file" >&2
    if [ "$status" -eq 0 ]; then
      rm -f "$err_file"
      return 0
    fi
    if ! grep -Eqi "$GH_RETRY_TRANSIENT_PATTERN" "$err_file"; then
      echo "$description failed with a non-transient error (exit $status); not retrying." >&2
      rm -f "$err_file"
      return "$status"
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "$description failed after $max_attempts attempts on transient errors (last exit $status)." >&2
      rm -f "$err_file"
      return "$status"
    fi
    echo "$description hit a transient error (exit $status); retrying in ${delay}s." >&2
    sleep "$delay"
    delay=$((delay * 2))
    if [ "$delay" -gt "$max_delay" ]; then
      delay="$max_delay"
    fi
    attempt=$((attempt + 1))
  done
}

# gh_release_exists <tag>: 0 = exists (gh also resolves drafts), 1 = not found
# (silent, so retry_transient does not retry it), 2 = lookup error.
gh_release_exists() {
  local tag="$1" out status=0
  out="$(gh release view "$tag" --json tagName 2>&1 >/dev/null)" || status=$?
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  if printf '%s\n' "$out" | grep -qi 'release not found'; then
    return 1
  fi
  printf '%s\n' "$out" >&2
  return 2
}

# gh_release_delete_asset_if_present <tag> <asset>: a retried delete whose
# first attempt succeeded server-side sees "not found"; treat that as done.
gh_release_delete_asset_if_present() {
  local tag="$1" asset="$2" out status=0
  out="$(gh release delete-asset "$tag" "$asset" --yes 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    [ -z "$out" ] || printf '%s\n' "$out"
    return 0
  fi
  if printf '%s\n' "$out" | grep -qi 'not found'; then
    echo "Asset $asset already absent from $tag."
    return 0
  fi
  printf '%s\n' "$out" >&2
  return "$status"
}
