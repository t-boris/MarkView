#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
phase="$PWD/tools/cockpit-temporal/scripts/build-runtime-phase.sh"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/source/tools/cockpit-temporal/scripts" "$out/product/App/Contents/Resources/Cockpit"
printf '#!/bin/bash\ntouch "$TARGET_BUILD_DIR/built"\n' > "$out/source/tools/cockpit-temporal/scripts/build-runtime.sh"
chmod +x "$out/source/tools/cockpit-temporal/scripts/build-runtime.sh"
touch "$out/product/App/Contents/Resources/Cockpit/stale"
export SRCROOT="$out/source" TARGET_BUILD_DIR="$out/product" UNLOCALIZED_RESOURCES_FOLDER_PATH="App/Contents/Resources"
CI=true "$phase"
[ ! -e "$out/product/built" ] && [ ! -e "$out/product/App/Contents/Resources/Cockpit" ]
CI=true MARKVIEW_BUILD_COCKPIT_RUNTIME=1 "$phase"
[ -f "$out/product/built" ]
rm "$out/product/built"
CI=false "$phase"
[ -f "$out/product/built" ]
echo 'Cockpit CI and release build phase checks passed'
