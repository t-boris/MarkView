#!/bin/bash
# Exercise durable relay credentials in distinct app-host processes and clean their isolated test service.
set -euo pipefail
cd "$(dirname "$0")/../.."
if (( $# )); then echo "usage: $0" >&2; exit 2; fi
scratch=$(mktemp -d /tmp/mvrelay-test-XXXXXX)
mkdir -p "$scratch/home"
test_id=$(uuidgen)
test_service="MarkView relay credentials tests $test_id"
test_suite="com.markview.relay-credentials-tests.$test_id"
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
export TEST_RUNNER_CFFIXED_USER_HOME="$scratch/home"
export TEST_RUNNER_MARKVIEW_RELAY_TEST_HOME="$scratch/home"
export TEST_RUNNER_MARKVIEW_RELAY_TEST_SERVICE="$test_service"
export TEST_RUNNER_MARKVIEW_RELAY_TEST_SUITE="$test_suite"
cleanup_done=0
interrupted=0
run_phase() {
    local phase=$1
    TEST_RUNNER_MARKVIEW_RELAY_TEST_PHASE="$phase" MARKVIEW_SOCKET_DIR="$scratch" \
      xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
      -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled YES \
      -only-testing:MarkViewHostedTests/RemoteRelaySettingsHostTests/testRelayCredentials test 2>&1 | tee "$scratch/$phase.log" || return 1
    grep -F "Test Case '-[MarkViewHostedTests.RemoteRelaySettingsHostTests testRelayCredentials]' passed" "$scratch/$phase.log" >/dev/null || {
        echo "The relay credential $phase test did not run successfully" >&2; return 1;
    }
}
remove_keychain_fallback() {
    local account status failed=0
    for account in 'https://relay-a.example.invalid' 'https://relay-b.example.invalid/prefix'; do
        /usr/bin/security find-generic-password -s "$test_service" -a "$account" >/dev/null 2>&1
        status=$?
        if (( status == 0 )); then
            /usr/bin/security delete-generic-password -s "$test_service" -a "$account" >/dev/null 2>&1 || failed=1
            /usr/bin/security find-generic-password -s "$test_service" -a "$account" >/dev/null 2>&1
            status=$?
        fi
        if (( status != 44 )); then failed=1; fi
    done
    if (( failed )); then echo "Could not verify cleanup of isolated relay test credentials" >&2; return 1; fi
}
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    if (( ! cleanup_done )); then
        if (( ! interrupted )) && run_phase cleanup; then
            cleanup_done=1
        elif ! remove_keychain_fallback; then
            status=1
        fi
    fi
    rm -rf "$scratch"
    exit "$status"
}
trap cleanup EXIT
trap 'interrupted=1; exit 130' INT
trap 'interrupted=1; exit 143' TERM
run_phase write
run_phase read
run_phase cleanup
cleanup_done=1
