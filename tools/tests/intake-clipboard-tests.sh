#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/IntakeClipboardTests.swift "$out/main.swift"
swiftc -O -o "$out/intake-clipboard-tests" MarkView/Models/Appearance/AppFontScale.swift MarkView/Views/Appearance/AppFontScaleView.swift MarkView/Models/Appearance/AppTheme.swift MarkView/Models/Appearance/WindowTheme.swift MarkView/Views/Appearance/AppPalette.swift MarkView/Views/Lifecycle/IntakeTextEditor.swift "$out/main.swift"
"$out/intake-clipboard-tests" "$@"
