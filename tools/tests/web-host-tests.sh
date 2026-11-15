#!/bin/bash
# AR-27 in real WebKit (hidden windows): what WebHost.makeConfiguration and WebHost.makeWebView give a host (settings, user scripts, a
# scheme handler, handlers in their world, a handler with a reply) and that a host which owns its web view is released with it.
# The sources are compiled twice, as a Debug build (inspector on) and as a Release build (inspector off).
#   tools/tests/web-host-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp tools/tests/WebHostTests.swift "$out/main.swift"
for build in debug release; do
    flags=()
    [ "$build" = debug ] && flags=(-D DEBUG)
    swiftc -module-cache-path /private/tmp/markview-swift-cache ${flags[@]+"${flags[@]}"} -o "$out/web-host-tests-$build" \
        Packages/MarkViewCore/Sources/MarkViewCore/WebHost.swift "$out/main.swift"
    echo "--- $build build"
    "$out/web-host-tests-$build" "$build"
done
