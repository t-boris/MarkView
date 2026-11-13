#!/bin/bash
# Sign every packaged executable and dynamic library before signing the enclosing app.
set -euo pipefail
: "${1:?App bundle path required}"
: "${2:?Developer ID signing identity required}"
runtime="$1/Contents/Resources/Cockpit"
[ -d "$runtime" ] || { echo "Cockpit runtime missing from app" >&2; exit 1; }
while IFS= read -r -d '' binary; do
    if /usr/bin/file -b "$binary" | /usr/bin/grep -q 'Mach-O'; then
        /usr/bin/codesign --force --options runtime --timestamp --sign "$2" "$binary"
    fi
done < <(/usr/bin/find "$runtime" -type f -print0)
