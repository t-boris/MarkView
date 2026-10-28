#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
test_service="MarkView saved connection tests $(uuidgen)"
trap 'if [[ -x "$out/saved-remote-connections-tests" ]]; then "$out/saved-remote-connections-tests" --clear "$test_service"; fi; rm -rf "$out"' EXIT
swiftc -parse-as-library -o "$out/saved-remote-connections-tests" \
    MarkView/Models/Remote/RemoteProtocol.swift MarkView/Models/Remote/RemoteConnectionState.swift \
    MarkView/Models/Remote/RemoteChannel.swift MarkView/Models/Remote/RemoteFraming.swift \
    MarkView/Models/Remote/RemoteRelaySettings.swift MarkView/Models/Remote/RemoteConnectionsStore.swift \
    tools/tests/SavedRemoteConnectionsTests.swift
"$out/saved-remote-connections-tests" --run "$test_service"
