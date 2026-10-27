#!/usr/bin/env bash
# REQ-DMG-4: Apple's CloudKit ticket-delivery endpoint is occasionally
# unavailable after notarization has already succeeded. Retry only the safe,
# idempotent staple operation, then fail closed if the bounded window expires.
set -u

artifact="${1:-}"
max_attempts="${HEIMDALL_STAPLE_MAX_ATTEMPTS:-8}"
delay_seconds="${HEIMDALL_STAPLE_RETRY_DELAY_SECONDS:-15}"
max_delay_seconds="${HEIMDALL_STAPLE_RETRY_MAX_DELAY_SECONDS:-60}"

if [ -z "$artifact" ]; then
  echo "usage: $0 <app-or-dmg>" >&2
  exit 2
fi
if [ ! -e "$artifact" ]; then
  echo "Staple target does not exist: $artifact" >&2
  exit 2
fi
case "$max_attempts:$delay_seconds:$max_delay_seconds" in
  *[!0-9:]*|0:*|*::*)
    echo "Staple retry settings must be non-negative integers and attempts must be greater than zero." >&2
    exit 2
    ;;
esac

attempt=1
current_delay="$delay_seconds"
while [ "$attempt" -le "$max_attempts" ]; do
  echo "Stapling $artifact (attempt $attempt/$max_attempts)"
  if xcrun stapler staple -v "$artifact"; then
    exit 0
  fi
  if [ "$attempt" -ge "$max_attempts" ]; then
    break
  fi
  echo "Stapling failed; retrying in ${current_delay}s." >&2
  sleep "$current_delay"
  if [ "$current_delay" -lt "$max_delay_seconds" ]; then
    current_delay=$((current_delay * 2))
    if [ "$current_delay" -gt "$max_delay_seconds" ]; then
      current_delay="$max_delay_seconds"
    fi
  fi
  attempt=$((attempt + 1))
done

echo "Stapling failed after $max_attempts attempts: $artifact" >&2
exit 1
