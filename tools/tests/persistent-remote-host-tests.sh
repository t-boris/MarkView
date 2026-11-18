#!/bin/bash
# Run persistent remote integration against an isolated app host, echo process and local relay.
set -euo pipefail
cd "$(dirname "$0")/../.."
if (( $# )); then echo "usage: $0" >&2; exit 2; fi
scratch=$(mktemp -d /tmp/mvpersist-test-XXXXXX)
mkdir -p "$scratch/home" "$scratch/fixture"
cp Tests/Fixtures/assistant-persistent-echo.sh "$scratch/fixture/echo.sh"
chmod 755 "$scratch/fixture/echo.sh"
relay_pid=''
cleanup() {
    local status=$? command pid group
    trap - EXIT INT TERM
    set +e
    if [[ -f "$scratch/children.pid" ]]; then
        while IFS= read -r pid; do
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            command=$(ps -p "$pid" -o command= 2>/dev/null)
            case "$command" in
                *"$scratch/fixture/echo.sh"*)
                    group=$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d ' ')
                    if [[ "$group" == "$pid" ]]; then kill -KILL -- "-$pid" 2>/dev/null; else kill -KILL "$pid" 2>/dev/null; fi
                    ;;
            esac
        done < "$scratch/children.pid"
    fi
    if [[ -n "$relay_pid" ]]; then
        command=$(ps -p "$relay_pid" -o command= 2>/dev/null)
        case "$command" in *persistent-remote-relay.mjs*"$scratch"*) kill "$relay_pid" 2>/dev/null ;; esac
        wait "$relay_pid" 2>/dev/null
    fi
    rm -rf "$scratch"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
node tools/tests/persistent-remote-relay.mjs "$scratch" >"$scratch/relay.log" 2>&1 &
relay_pid=$!
for _ in {1..100}; do
    [[ -s "$scratch/relay.port" ]] && break
    kill -0 "$relay_pid" 2>/dev/null || { echo 'Persistent relay fixture exited' >&2; exit 1; }
    sleep 0.05
done
[[ -s "$scratch/relay.port" ]] || { echo 'Persistent relay fixture did not start' >&2; exit 1; }
port=$(cat "$scratch/relay.port")
[[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port <= 65535 )) || { echo 'Invalid fixture port' >&2; exit 1; }
export TEST_RUNNER_HOME="$scratch/home"
export TEST_RUNNER_CFFIXED_USER_HOME="$scratch/home"
export TEST_RUNNER_SHELL=/bin/sh
export TEST_RUNNER_ZDOTDIR="$scratch/home"
export TEST_RUNNER_MARKVIEW_PERSISTENT_TEST_HOME="$scratch/home"
export TEST_RUNNER_MARKVIEW_PERSISTENT_TEST_FIXTURE="$scratch/fixture/echo.sh"
export TEST_RUNNER_MARKVIEW_PERSISTENT_TEST_RELAY="http://127.0.0.1:$port"
export TEST_RUNNER_MARKVIEW_PERSISTENT_TEST_ID="$(uuidgen)"
export TEST_RUNNER_MARKVIEW_SOCKET_DIR="$scratch"
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
MARKVIEW_SOCKET_DIR="$scratch" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$scratch" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled YES \
  -only-testing:MarkViewHostedTests/PersistentRemoteHostTests/testPersistentRemoteSessions test 2>&1 | tee "$scratch/test.log"
grep -F "Test Case '-[MarkViewHostedTests.PersistentRemoteHostTests testPersistentRemoteSessions]' passed" "$scratch/test.log" >/dev/null || {
    echo 'The persistent remote host test did not run successfully' >&2; exit 1;
}
