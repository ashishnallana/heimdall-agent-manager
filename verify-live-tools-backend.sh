#!/usr/bin/env bash
# Compatibility entry point for the subscribed stream verification.
set -euo pipefail
exec bash "$(dirname -- "$0")/verify-tool-stream-backend.sh"
