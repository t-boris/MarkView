#!/bin/bash
# Structural rule (AR-25): every child process of the app is started through MarkViewCore.Subprocess
# (Packages/MarkViewCore/Sources/MarkViewCore/Subprocess*.swift), which drains the pipes concurrently, bounds the
# output, ends the whole process group on a timeout and never blocks a thread in waitUntilExit.
#   - `Process()` outside the Subprocess sources: must be 0
#   - `waitUntilExit` outside the Subprocess sources: must be 0
# Scope: the application (MarkView/) and the Core package sources. Test programs under tools/tests/ are not part
# of the shipping app and may use Process directly; the pseudo-terminals of TerminalSession (forkpty) are not a
# Process and are out of scope.
#   tools/tests/no-process-outside-subprocess-lint.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

# violations <root>...: "file:line: text" for each offending line (comment-only lines are skipped).
violations() {
    grep -rnE --include='*.swift' '\bProcess\(\)|\bwaitUntilExit\b' "$@" 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' \
        | grep -vE '^[^:]*/Subprocess[A-Za-z]*\.swift:' || true
}

# The rule must be able to fail: a fixture with the forbidden calls is reported.
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
printf 'import Foundation\nlet p = Process()\np.waitUntilExit()\n// Process() in a comment is not a call\n' > "$fixture/Offender.swift"
printf 'import Foundation\nlet q = Process()\n' > "$fixture/Subprocess.swift"
found=$(violations "$fixture" | wc -l | tr -d ' ')
if [ "$found" != "2" ]; then
    echo "FAIL the lint does not see the forbidden calls in its own fixture (saw $found of 2)"
    exit 1
fi
echo "ok   the lint reports Process() and waitUntilExit and skips comments and the Subprocess sources"

result=$(violations MarkView Packages/MarkViewCore/Sources)
if [ -n "$result" ]; then
    echo "FAIL a child process is started outside MarkViewCore.Subprocess:"
    echo "$result"
    exit 1
fi
echo "ok   Process() and waitUntilExit outside Subprocess: 0"
