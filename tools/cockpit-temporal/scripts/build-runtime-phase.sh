#!/bin/bash
set -euo pipefail
: "${SRCROOT:?}"
: "${TARGET_BUILD_DIR:?}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
# Ordinary CI jobs compile the app; the dedicated cockpit job checks its runtime once.
# A release explicitly opts in even when it is built on CI.
if [ "${CI:-}" = "true" ] && [ "${MARKVIEW_BUILD_COCKPIT_RUNTIME:-0}" != "1" ]; then
    destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Cockpit"
    if [ -d "$destination" ]; then /usr/bin/find "$destination" -depth -delete; fi
    echo "Cockpit runtime is checked separately in CI"
    exit 0
fi
"$SRCROOT/tools/cockpit-temporal/scripts/build-runtime.sh"
