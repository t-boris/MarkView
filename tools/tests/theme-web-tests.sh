#!/bin/bash
# Web-theme regression and optional classic capture in an isolated app-host process.
# Usage: theme-web-tests.sh [editor-folder] | capture <editor-folder> <output.json>
set -euo pipefail
cd "$(dirname "$0")/../.."
unset TEST_RUNNER_MARKVIEW_THEME_EDITOR TEST_RUNNER_MARKVIEW_THEME_CAPTURE MARKVIEW_THEME_EDITOR MARKVIEW_THEME_CAPTURE
case "$#:${1:-}" in
  0:) ;;
  1:capture) echo 'Usage: theme-web-tests.sh capture <editor-folder> <output.json>' >&2; exit 2 ;;
  1:*) export TEST_RUNNER_MARKVIEW_THEME_EDITOR="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1")" ;;
  3:capture)
    export TEST_RUNNER_MARKVIEW_THEME_EDITOR="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$2")"
    export TEST_RUNNER_MARKVIEW_THEME_CAPTURE="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$3")" ;;
  *) echo 'Usage: theme-web-tests.sh [editor-folder] | capture <editor-folder> <output.json>' >&2; exit 2 ;;
esac
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
socket_dir=$(mktemp -d /tmp/mvthemehost.XXXXXX)
trap 'rm -rf "$socket_dir"' EXIT
MARKVIEW_SOCKET_DIR="$socket_dir" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$socket_dir" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled YES \
  -only-testing:MarkViewHostedTests/ThemeWebHostTests/testWebThemes test
