#!/bin/bash
# The window themes in the shipped web pages (editor, discussion thread, terminal), in real WebKit with hidden windows:
# every appearance paints the real elements with its tokens, text pairs are legible, an accent override and its reset
# work, a theme change restyles without reloading or losing text and scroll, two pages hold different appearances,
# and Classic Dark/Light still paint every sampled element as the page did before themes (DEC-003, DEC-004, DEC-006).
#   tools/tests/theme-web-tests.sh                       check the page in the working tree
#   tools/tests/theme-web-tests.sh <editor folder>       check another copy of the editor folder
#   tools/tests/theme-web-tests.sh capture <editor folder> <out.json>
#       write the computed colours of the Classic appearances (how Tests/Fixtures/themes/classic-computed.json was made,
#       from the editor folder of origin/main before the themes existed)
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
mkdir "$out/web"
cp tools/tests/ThemeWebTests.swift "$out/web/main.swift"
swiftc -O -o "$out/theme-web-tests" "$out/web/main.swift"
if [ "${1:-}" = "capture" ]; then
  "$out/theme-web-tests" capture "$2" "$3"
else
  "$out/theme-web-tests" "${1:-$PWD/MarkView/Resources/Editor}" "$PWD/Tests/Fixtures/themes/classic-computed.json"
fi
