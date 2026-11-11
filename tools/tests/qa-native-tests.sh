#!/bin/bash
# Feature end-to-end-qa: the native macOS player (Models/QANativeTree.swift: what the assistant is shown for an application's tree, its limits, the
# keys, the evidence; QANativeAccessibility.swift, QANativeCapture.swift, QANativeActor.swift, QANativeFactory.swift: launching, reading and
# operating an application, its pictures, its permissions). Compiled on its own with a test main (no XCTest target exists). The first part is pure.
# The live part (on by default, about 15 s) builds the fixture application (Tests/Fixtures/qa-native-demo), registers it with Launch Services
# under a folder of the repository's ignored build/ directory (Launch Services does not list applications in temporary folders), drives it with a
# real QANativeActor without bringing it to the front, and ends it, unregistering it afterwards. It needs the Accessibility and Screen Recording
# permissions of the process that runs this script and is skipped, with a message, when either is missing. Nothing reads the Keychain.
#   tools/tests/qa-native-tests.sh              pure and live
#   QA_NATIVE_LIVE=0 tools/tests/qa-native-tests.sh    pure only
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
fixtures="${QA_NATIVE_FIXTURE_ROOT:-build}/qa-native-demo-$$"
lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
cleanup() {
    if [ -d "$fixtures/QANativeDemo.app" ]; then "$lsregister" -u "$fixtures/QANativeDemo.app" >/dev/null 2>&1 || true; fi
    rm -rf "$out" "$fixtures"
}
trap cleanup EXIT
M=MarkView/Models
cp tools/tests/QANativeChecks.swift "$out/main.swift"
swiftc -target "$(uname -m)-apple-macos13.0" -o "$out/qa-native" \
    "$M/QANativeTree.swift" "$M/QANativeAccessibility.swift" "$M/QANativeCapture.swift" "$M/QANativeActor.swift" "$M/QANativeFactory.swift" tools/tests/QANativeKeychainStub.swift \
    "$M/QAAPI.swift" "$M/QAScenario.swift" "$M/QARun.swift" "$M/QAStore.swift" "$M/QAGeneration.swift" "$M/QAGenerator.swift" "$M/QAPlan.swift" "$M/QAGate.swift" "$M/QAEffort.swift" \
    "$M/QATriage.swift" "$M/QAActions.swift" "$M/QARunner.swift" "$M/QALanguage.swift" "$M/QAPageEvidence.swift" "$M/QACredentials.swift" "$M/QAScenarioEdit.swift" "$M/QAAttachments.swift" \
    "$M/QAGraphLayout.swift" tools/tests/IssueChecksSupport.swift "$out/main.swift"
app=""
if [ "${QA_NATIVE_LIVE:-1}" != "0" ]; then
    mkdir -p "$fixtures"
    app=$(Tests/Fixtures/qa-native-demo/build.sh "$fixtures" | tail -1)
    "$lsregister" -f "$app"
fi
"$out/qa-native" "$app"
