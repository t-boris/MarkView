#!/bin/bash
# Feature end-to-end-qa, REQ-008: the step-by-step review. The schema, the prompt and the reading of what the AI wrote, and the one-line
# summary of a branch's effort (Models/QAReview.swift), and the reading and summary of what the runner measures in the page
# (Models/QAPageEvidence.swift). Foundation only; compiled on its own with a test main (no XCTest target exists). The measuring script
# itself is run in WebKit by tools/tests/qa-evidence-web-tests.sh.
#   tools/tests/qa-review-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
cp tools/tests/QAReviewChecks.swift "$out/main.swift"
swiftc -O -o "$out/qa-review" "$M/QAEffort.swift" "$M/QATriage.swift" "$M/QAAPI.swift" "$M/QAScenario.swift" "$M/QAPageEvidence.swift" "$M/QAReview.swift" tools/tests/IssueChecksSupport.swift "$out/main.swift"
"$out/qa-review"
