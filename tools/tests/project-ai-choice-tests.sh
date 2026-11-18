#!/bin/bash
# Isolated preferences and recovery files; an optional live Antigravity check is explicit.
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp=$(mktemp -d /tmp/mvaichoice.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/home"
export TEST_RUNNER_CFFIXED_USER_HOME="$tmp/home"
export TEST_RUNNER_MARKVIEW_AI_TEST_HOME="$tmp/home"
unset TEST_RUNNER_MARKVIEW_LIVE_ANTIGRAVITY
if [[ "${MARKVIEW_LIVE_ANTIGRAVITY:-}" == "1" ]]; then export TEST_RUNNER_MARKVIEW_LIVE_ANTIGRAVITY=1; fi
derived="${MARKVIEW_HOSTED_TEST_DERIVED_DATA:-${TMPDIR:-/tmp}/MarkViewHostedTestsDerived}"
MARKVIEW_SOCKET_DIR="$tmp" TEST_RUNNER_MARKVIEW_SOCKET_DIR="$tmp" xcodebuild -project MarkView.xcodeproj -scheme MarkView -configuration HostedTests \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -test-timeouts-enabled YES \
  -only-testing:MarkViewHostedTests/ProjectAIChoiceHostTests/testProjectAssistantChoices test | tee "$tmp/test.log"
python3 - "$tmp/test.log" <<'PY'
import pathlib,sys
log=pathlib.Path(sys.argv[1]).read_text(errors='replace')
if "ProjectAIChoiceHostTests testProjectAssistantChoices]' passed" not in log:
    sys.exit('Project assistant-choice test was not executed and passed')
PY
