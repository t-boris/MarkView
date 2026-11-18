#!/bin/bash
# Manual: uses the selected provider's installed CLI login and normal allowance.
# Usage: book-pdf-live.sh [claude|codex] [output parent] [both|russian|short]
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "$#" -le 3 ] || { echo "usage: $0 [claude|codex] [output parent] [both|russian|short]" >&2; exit 2; }
provider="${1:-claude}"; variant="${3:-both}"
case "$provider" in claude|codex) ;; *) echo "Unknown provider: $provider" >&2; exit 2;; esac
case "$variant" in both|russian|short) ;; *) echo "Unknown variant: $variant" >&2; exit 2;; esac
parent="${2:-/private/tmp/markview-book-live}"
mkdir -p "$parent"
parent=$(cd "$parent" && pwd -P)
root=$(mktemp -d "$parent/book.XXXXXX")
echo "Live book artifacts: $root"
export TEST_RUNNER_MARKVIEW_MANUAL_BOOK_PDF=1 TEST_RUNNER_MARKVIEW_MANUAL_BOOK_PROVIDER="$provider"
export TEST_RUNNER_MARKVIEW_MANUAL_BOOK_ROOT="$root" TEST_RUNNER_MARKVIEW_MANUAL_BOOK_ENTRY="$PWD/MarkView/Resources/Editor/book.html"
export TEST_RUNNER_MARKVIEW_MANUAL_BOOK_VARIANT="$variant"
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
socket_dir=$(mktemp -d /tmp/mvbook.XXXXXX)
trap 'rm -rf "$socket_dir"' EXIT
MARKVIEW_SOCKET_DIR="$socket_dir" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$socket_dir" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled NO \
  -only-testing:MarkViewHostedTests/ManualProviderLiveHostTests/testManualBookPDF test 2>&1 | tee "$socket_dir/test.log"
grep -F "Test Case '-[MarkViewHostedTests.ManualProviderLiveHostTests testManualBookPDF]' passed" "$socket_dir/test.log" >/dev/null || {
    echo "The manual Book PDF test did not run successfully" >&2; exit 1;
}
