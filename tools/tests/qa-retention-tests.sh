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
swiftc -O -o "$out/qaretention" "$M/QA/QAAPI.swift" "$M/QA/QAScenario.swift" "$M/QA/QARun.swift" "$M/QA/QAEffort.swift" "$M/QA/QATriage.swift" "$M/QA/QAStore.swift" "$M/QA/QABugs.swift" "$M/QA/QABugFiler.swift" "$M/Workspace/FrontMatter.swift" "$M/Lifecycle/BugReportWriter.swift" "$M/Lifecycle/FeatureVocabulary.swift" "$M/QA/QARunRetention.swift" "$M/QA/QARunCleanup.swift" "$M/Cockpit/CockpitPlan.swift" "$M/Cockpit/CockpitResults.swift" MarkView/Models/Workspace/SchemaVersionedStore.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift tools/tests/IssueChecksSupport.swift tools/tests/StoreTestSupport.swift "$out/main.swift"
"$out/qaretention"
