#!/bin/bash
# Feature end-to-end-qa: the bug reports a run asks for (Models/QABugs.swift) and the filer that writes them once (Models/QABugFiler.swift),
# with the writer of the project's bug files (BugReportWriter.swift, FrontMatter.swift) and the severity vocabulary. Foundation only;
# compiled on its own with a test main (no XCTest target exists). QAFeatureStoreBugSink.swift needs FeatureStore and is checked by the
# app build.
#   tools/tests/qa-bugs-tests.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
cp tools/tests/QABugsChecks.swift "$out/main.swift"
swiftc -O -o "$out/qabugs" "$M/QAAPI.swift" "$M/QAScenario.swift" "$M/QARun.swift" "$M/QAEffort.swift" "$M/QATriage.swift" "$M/QABugs.swift" "$M/QABugFiler.swift" "$M/FrontMatter.swift" "$M/BugReportWriter.swift" "$M/FeatureVocabulary.swift" tools/tests/IssueChecksSupport.swift "$out/main.swift"
"$out/qabugs"
