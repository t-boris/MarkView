#!/bin/bash
# Checks which language built-in dictation uses (DictationLanguage in
# MarkView/Models/OnDeviceSpeech.swift): the stored choice wins and is never replaced by another
# language, otherwise the system languages in order, with regional variants. Only the pure enum is
# compiled, not the app (it must stay the last declaration of the file).
#   tools/tests/dictation-language-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
{ echo 'import Foundation'; awk '/^enum DictationLanguage/,0' MarkView/Models/OnDeviceSpeech.swift; } > "$out/Language.swift"
cp tools/tests/DictationLanguageTests.swift "$out/main.swift"
swiftc -O -o "$out/dictation-language-tests" "$out/Language.swift" "$out/main.swift"
"$out/dictation-language-tests"
