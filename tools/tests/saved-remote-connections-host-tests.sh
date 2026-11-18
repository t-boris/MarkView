#!/bin/bash
# Exercise saved connections in distinct isolated app hosts and remove their test Keychain items.
set -euo pipefail
cd "$(dirname "$0")/../.."
if (( $# )); then echo "usage: $0" >&2; exit 2; fi
scratch=$(mktemp -d /tmp/mvsaved-test-XXXXXX)
mkdir -p "$scratch/home"
test_id=$(uuidgen)
test_service="MarkView saved connection host tests $test_id"
relay_service="MarkView saved connection relay host tests $test_id"
test_suite="com.markview.saved-connection-host-tests.$test_id"
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
relay_pid=''
relay=''
remove_item() {
    local service=$1 account=$2 status
    /usr/bin/security find-generic-password -s "$service" -a "$account" >/dev/null 2>&1
    status=$?
    if (( status == 0 )); then
        /usr/bin/security delete-generic-password -s "$service" -a "$account" >/dev/null 2>&1 || return 1
        /usr/bin/security find-generic-password -s "$service" -a "$account" >/dev/null 2>&1
        status=$?
    fi
    (( status == 44 ))
}
cleanup() {
    local status=$? command
    trap - EXIT INT TERM
    set +e
    if ! remove_item "$test_service" 'saved-connections-v1'; then
        echo 'Could not verify cleanup of the isolated saved-connection Keychain item' >&2; status=1
    fi
    if [[ -n "$relay" ]] && ! remove_item "$relay_service" "$relay"; then
        echo 'Could not verify cleanup of the isolated relay Keychain item' >&2; status=1
    fi
    if [[ -n "$relay_pid" ]]; then
        command=$(ps -p "$relay_pid" -o command= 2>/dev/null)
        case "$command" in *saved-remote-relay.py*"$scratch"*) kill "$relay_pid" 2>/dev/null ;; esac
        wait "$relay_pid" 2>/dev/null
    fi
    rm -rf "$scratch"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python3 Tests/Fixtures/saved-remote-relay.py "$scratch" >"$scratch/relay.log" 2>&1 &
relay_pid=$!
for _ in {1..100}; do
    [[ -s "$scratch/relay.port" ]] && break
    kill -0 "$relay_pid" 2>/dev/null || { echo 'Offline relay fixture exited' >&2; exit 1; }
    sleep 0.05
done
[[ -s "$scratch/relay.port" ]] || { echo 'Offline relay fixture did not start' >&2; exit 1; }
port=$(cat "$scratch/relay.port")
[[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port <= 65535 )) || { echo 'Invalid fixture port' >&2; exit 1; }
relay="http://127.0.0.1:$port"
export TEST_RUNNER_CFFIXED_USER_HOME="$scratch/home"
export TEST_RUNNER_MARKVIEW_SAVED_TEST_HOME="$scratch/home"
export TEST_RUNNER_MARKVIEW_SAVED_TEST_SERVICE="$test_service"
export TEST_RUNNER_MARKVIEW_SAVED_TEST_RELAY_SERVICE="$relay_service"
export TEST_RUNNER_MARKVIEW_SAVED_TEST_SUITE="$test_suite"
export TEST_RUNNER_MARKVIEW_SAVED_TEST_RELAY="$relay"
for phase in write read cleanup; do
    kill -0 "$relay_pid" 2>/dev/null || { echo 'Offline relay fixture stopped unexpectedly' >&2; exit 1; }
    TEST_RUNNER_MARKVIEW_SAVED_TEST_PHASE="$phase" MARKVIEW_SOCKET_DIR="$scratch" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$scratch" \
      xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
      -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled YES \
      -only-testing:MarkViewHostedTests/SavedRemoteConnectionsHostTests/testSavedConnections test 2>&1 | tee "$scratch/$phase.log"
    grep -F "Test Case '-[MarkViewHostedTests.SavedRemoteConnectionsHostTests testSavedConnections]' passed" "$scratch/$phase.log" >/dev/null || {
        echo "The saved-connection $phase test did not run successfully" >&2; exit 1;
    }
done
