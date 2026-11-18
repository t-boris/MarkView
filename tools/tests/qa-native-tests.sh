#!/bin/bash
# Manual native QA fixture checks in the app host. The fixture needs this host's
# Accessibility and Screen Recording permissions. QA_NATIVE_LIVE=0 runs only
# the non-interactive behavior checks; these also run in the automatic GUI suite.
set -euo pipefail
cd "$(dirname "$0")/../.."
fixtures=""
lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
socket_dir=$(mktemp -d /tmp/mvnative.XXXXXX)
cleanup() {
    if [ -n "$fixtures" ]; then
        if [ -d "$fixtures/QANativeDemo.app" ]; then "$lsregister" -u "$fixtures/QANativeDemo.app" >/dev/null 2>&1 || true; fi
        if [ -d "$fixtures/QANativeSingle.app" ]; then "$lsregister" -u "$fixtures/QANativeSingle.app" >/dev/null 2>&1 || true; fi
        rm -rf "$fixtures"
    fi
    rm -rf "$socket_dir"
}
trap cleanup EXIT
export TEST_RUNNER_MARKVIEW_MANUAL_NATIVE_QA=1
unset TEST_RUNNER_MARKVIEW_NATIVE_FIXTURE TEST_RUNNER_MARKVIEW_NATIVE_SINGLE_FIXTURE
unset TEST_RUNNER_QA_NATIVE_EXISTING_RUN TEST_RUNNER_QA_NATIVE_EXISTING_BUNDLE
if [ -n "${QA_NATIVE_EXISTING_RUN:-}" ]; then export TEST_RUNNER_QA_NATIVE_EXISTING_RUN="$QA_NATIVE_EXISTING_RUN"; fi
if [ -n "${QA_NATIVE_EXISTING_BUNDLE:-}" ]; then export TEST_RUNNER_QA_NATIVE_EXISTING_BUNDLE="$QA_NATIVE_EXISTING_BUNDLE"; fi
if [ "${QA_NATIVE_LIVE:-1}" != "0" ]; then
    mkdir -p "${QA_NATIVE_FIXTURE_ROOT:-build}"
    fixtures=$(mktemp -d "${QA_NATIVE_FIXTURE_ROOT:-build}/qa-native-demo.XXXXXX")
    fixtures=$(cd "$fixtures" && pwd -P)
    app=$(Tests/Fixtures/qa-native-demo/build.sh "$fixtures" | tail -1)
    "$lsregister" -f "$app"
    single="$fixtures/QANativeSingle.app"
    ditto "$app" "$single"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.markview.qa-native-single' "$single/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :LSMultipleInstancesProhibited bool true' "$single/Contents/Info.plist"
    codesign --force --sign - "$single" >/dev/null 2>&1
    "$lsregister" -f "$single"
    export TEST_RUNNER_MARKVIEW_NATIVE_FIXTURE="$app"
    export TEST_RUNNER_MARKVIEW_NATIVE_SINGLE_FIXTURE="$single"
fi
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
MARKVIEW_SOCKET_DIR="$socket_dir" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$socket_dir" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled NO \
  -only-testing:MarkViewHostedTests/ManualNativeQAHostTests/testManualNativeQA test 2>&1 | tee "$socket_dir/test.log"
grep -F "Test Case '-[MarkViewHostedTests.ManualNativeQAHostTests testManualNativeQA]' passed" "$socket_dir/test.log" >/dev/null || {
    echo "The manual native QA test did not run successfully" >&2; exit 1;
}
