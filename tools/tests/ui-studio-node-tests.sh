#!/bin/bash
# Checks UI Studio's Node preload (MarkView/Resources/Editor/vendor/js/markview-ui-studio-node.cjs), which a development
# server is started with so that its Node processes share the page's test clock, time zone and locale: Date, TZ and the
# locale defaults, a running process picking up a rewritten clock file, the Set-Cookie Expires conversion on a real HTTP
# server, forked children and worker threads, a second copy of the preload, and no change without a clock file.
# Uses the node on PATH (no packages) and skips without one.
#   tools/tests/ui-studio-node-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
if ! command -v node >/dev/null 2>&1; then
  echo "skip: node is not on PATH, the UI Studio Node checks did not run."
  exit 0
fi
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
# The driver itself keeps the real clock, whatever the surrounding shell was started with.
unset NODE_OPTIONS MARKVIEW_STUDIO_CLOCK MARKVIEW_STUDIO_ORIGINAL_TZ
node tools/tests/ui-studio-node.test.js "$PWD/MarkView/Resources/Editor/vendor/js/markview-ui-studio-node.cjs" "$out"
