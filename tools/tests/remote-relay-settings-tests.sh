#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
test_id=$(uuidgen)
test_service="MarkView relay credentials tests $test_id"
test_suite="com.markview.relay-credentials-tests.$test_id"
cleanup() {
    if [ -x "$out/relay-settings-tests" ]; then
        "$out/relay-settings-tests" cleanup "$test_service" "$test_suite"
    fi
    rm -rf "$out"
}
trap cleanup EXIT
swiftc -parse-as-library -module-cache-path "${TMPDIR:-/tmp}/markview-remote-test-modules" \
    MarkView/Models/Remote/RemoteProtocol.swift MarkView/Models/Remote/RemoteRelaySettings.swift \
    tools/tests/RemoteRelaySettingsTests.swift -o "$out/relay-settings-tests"
"$out/relay-settings-tests" write "$test_service" "$test_suite"
"$out/relay-settings-tests" read "$test_service" "$test_suite"
