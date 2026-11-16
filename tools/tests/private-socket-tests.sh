#!/bin/bash
# The protection every MarkView local socket server shares (Packages/MarkViewCore PrivateSocket, AR-40): private socket
# and token file, 256-bit token, the kernel's account of the peer, cleanup. Foundation only; compiled on its own with a
# test main. The three servers are checked over real sockets in cockpit-host-bridge-tests, remote-workspace-tests and
# remote-browser-tests.
#   tools/tests/private-socket-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/PrivateSocketTests.swift "$out/main.swift"
swiftc -o "$out/private-socket-tests" Packages/MarkViewCore/Sources/MarkViewCore/PrivateSocket.swift "$out/main.swift"
"$out/private-socket-tests"
