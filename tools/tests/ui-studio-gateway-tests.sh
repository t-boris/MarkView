#!/bin/bash
# Runs UI Studio's loopback gateway (MarkView/Models/UIStudioGateway.swift) for real: two variables on 127.0.0.1, real
# HTTP requests through URLSession and raw sockets, the handler's answers, the Host and browser guards, 100-continue,
# chunked bodies, held (hang) answers released by Reset, delays, the head timeout, the connection limit, no listener on
# other interfaces, and closing and reopening.
#   tools/tests/ui-studio-gateway-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/UIStudioGatewayTests.swift "$out/main.swift"
swiftc -o "$out/ui-studio-gateway-tests" MarkView/Models/UIStudioGateway.swift MarkView/Models/UIStudioGatewayStreams.swift "$out/main.swift"
"$out/ui-studio-gateway-tests"
