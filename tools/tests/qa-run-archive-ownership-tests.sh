#!/bin/bash
# Checks who owns the deletion of runs the Run panel offers (AR-19): the shipping QARunArchive over real run folders in a temporary project.
# The archive works out what a deletion removes, asks, deletes and reads the list again; one at a time; the folder or the window ending
# stops it and nothing is written after. Foundation only; compiled on its own with a test main.
#   tools/tests/qa-run-archive-ownership-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
cp tools/tests/QARunArchiveOwnershipTests.swift "$out/main.swift"
swiftc -O -o "$out/qa-run-archive-ownership" "$M/QA/QAAPI.swift" "$M/QA/QAScenario.swift" "$M/QA/QARun.swift" "$M/QA/QAEffort.swift" "$M/QA/QATriage.swift" "$M/QA/QAStore.swift" "$M/QA/QABugs.swift" "$M/QA/QABugFiler.swift" "$M/Shared/FrontMatter.swift" "$M/Lifecycle/BugReportWriter.swift" "$M/Lifecycle/FeatureVocabulary.swift" "$M/QA/QARunRetention.swift" "$M/QA/QARunCleanup.swift" "$M/Cockpit/CockpitPlan.swift" "$M/Cockpit/CockpitResults.swift" "$M/QA/QARunArchive.swift" "$M/QA/QATriageService.swift" MarkView/Models/Shared/SchemaVersionedStore.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift Packages/MarkViewCore/Sources/MarkViewCore/StoredJSON.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift Packages/MarkViewCore/Sources/MarkViewCore/TaskBag.swift "$out/main.swift"
"$out/qa-run-archive-ownership"
