#!/bin/bash
# Isolated app image with test-only registrations: verifies real runtime discovery.
set -euo pipefail
cd "$(dirname "$0")/../.."
derived="${MARKVIEW_BACKDROP_HOSTED_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewBackdropHosted}"
tmp=$(mktemp -d /tmp/mvbackdrophost.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
MARKVIEW_SOCKET_DIR="$tmp" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$tmp" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MARKVIEW_HOSTED_TEST_HOST MARKVIEW_BACKDROP_FIXTURE' \
  -test-timeouts-enabled YES -only-testing:MarkViewHostedTests/BackdropRegistryHostTests/testRuntimeDiscovery test | tee "$tmp/test.log"
python3 - "$tmp/test.log" <<'PY'
import pathlib,sys
log=pathlib.Path(sys.argv[1]).read_text(errors='replace')
if "BackdropRegistryHostTests testRuntimeDiscovery]' passed" not in log:
    sys.exit('Backdrop runtime-discovery test was not executed and passed')
PY
