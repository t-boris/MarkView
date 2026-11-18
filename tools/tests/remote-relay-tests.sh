#!/bin/bash
# Relay settings and Node integration; the workspace itself runs in the isolated app host.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [ "${MARKVIEW_REMOTE_SKIP_DUPLICATE_PURE:-0}" != 1 ]; then
    bash tools/tests/remote-relay-settings-tests.sh
fi
node --test tools/remote-relay/*.test.mjs
