#!/usr/bin/env bash
set -euo pipefail
cd /home/tanmay/hamwt/tool-stream-preview
git diff --check
bash -n scripts/ui-preview.sh
node --check scripts/preview-server.mjs
git diff --exit-code 263cdff81db41e067d00711a6aa99fd58a639bf0 HEAD -- src/hub src/bridge src/ctl src/lib src/dev_proxy
diff -qr extensions/claude-code /home/tanmay/.claude/plugins/cache/heimdall/heimdall/0.1.0
diff -qr extensions/codex /home/tanmay/.codex/plugins/cache/heimdall-codex/heimdall/0.1.0
node scripts/tool-stream-preview-smoke.mjs "$@"
