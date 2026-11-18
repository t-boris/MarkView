#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d /tmp/mvpersist-test-XXXXXX)
mkdir -p "$out/home"
export CFFIXED_USER_HOME="$out/home"
relay_pid=''
cleanup() {
    local status=$? command
    trap - EXIT INT TERM
    set +e
    if [[ -n "$relay_pid" ]]; then
        command=$(ps -p "$relay_pid" -o command= 2>/dev/null)
        case "$command" in *persistent-remote-relay.mjs*"$out"*) kill "$relay_pid" 2>/dev/null ;; esac
        wait "$relay_pid" 2>/dev/null
    fi
    rm -rf "$out"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
swiftc -parse-as-library -o "$out/persistent-remote-session-tests" Packages/MarkViewCore/Sources/MarkViewCore/*.swift \
    MarkView/Models/AgentTools/BrowserAgentTools.swift MarkView/Models/Remote/RemoteProtocol.swift \
    MarkView/Models/Terminal/RemoteConnectionState.swift MarkView/Models/Remote/RemoteChannel.swift \
    MarkView/Models/Remote/RemoteFraming.swift MarkView/Models/Remote/RemoteWorkspace.swift \
    MarkView/Models/Remote/RemoteCommand.swift MarkView/Models/AI/Providers/*.swift \
    MarkView/Models/Remote/RemoteWorkspaceTools.swift MarkView/Models/Remote/RemoteToolBridge.swift \
    MarkView/Models/Remote/RemoteToolRequests.swift MarkView/Models/Remote/RemoteProviderConfiguration.swift \
    MarkView/Models/Remote/RemoteHostController.swift MarkView/Models/Remote/RemoteTerminalConnection.swift \
    tools/tests/PersistentRemoteSessionTests.swift
node tools/tests/persistent-remote-relay.mjs "$out" > "$out/relay.log" 2>&1 &
relay_pid=$!
for i in {1..100}; do
    [[ -s "$out/relay.port" ]] && break
    kill -0 "$relay_pid" 2>/dev/null || { echo 'Persistent relay fixture exited' >&2; exit 1; }
    sleep 0.05
done
[[ -s "$out/relay.port" ]] || { echo 'Persistent relay fixture did not start' >&2; exit 1; }
port=$(cat "$out/relay.port")
[[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port <= 65535 )) || { echo 'Invalid fixture port' >&2; exit 1; }
export MARKVIEW_PERSISTENT_RELAY_URL="http://127.0.0.1:$port"
"$out/persistent-remote-session-tests"
