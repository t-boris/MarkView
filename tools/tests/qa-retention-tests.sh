#!/bin/bash
# Feature end-to-end-qa: which runs are kept and which are deleted (Q-010): the rule (Models/QARunRetention.swift), the run deletion of
# Models/QAStore.swift, the pruning and the question before a deletion (Models/QARunCleanup.swift), and the bug reports that name runs
# (QABugIndex in Models/QABugFiler.swift, the reports written by BugReportWriter.swift). Foundation only; compiled on its own with a test
# main (no XCTest target exists). The Run panel's list (Views/QARunReportViews.swift) is checked by the app build.
#   tools/tests/qa-retention-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
cp tools/tests/QARetentionChecks.swift "$out/main.swift"
swiftc -O -o "$out/qaretention" "$M/QAAPI.swift" "$M/QAScenario.swift" "$M/QARun.swift" "$M/QAEffort.swift" "$M/QATriage.swift" "$M/QAStore.swift" "$M/QABugs.swift" "$M/QABugFiler.swift" "$M/FrontMatter.swift" "$M/BugReportWriter.swift" "$M/FeatureVocabulary.swift" "$M/QARunRetention.swift" "$M/QARunCleanup.swift" "$M/CockpitPlan.swift" "$M/CockpitResults.swift" tools/tests/IssueChecksSupport.swift "$out/main.swift"
"$out/qaretention"
