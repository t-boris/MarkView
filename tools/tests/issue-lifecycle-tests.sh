#!/bin/bash
# Checks the issue lifecycle modules (docs/features/issue-lifecycle-management): the transition policy, the history and
# service, the delivery evidence, verified completion and reconciliation, the GitHub sync planner, the AI context and the
# Lifecycle section's display model.
# The app has no XCTest target: each suite is compiled on its own with a test main and run.
#   tools/tests/issue-lifecycle-tests.sh [suite ...]      suites: policy log evidence completion github context display store
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
base=("$M/FeatureVocabulary.swift" "$M/IssueListing.swift" "$M/IssueLifecycle.swift" tools/tests/IssueChecksSupport.swift)

run() {  # name, checks file, extra sources...
    local name=$1 checks=$2; shift 2
    [ -f "tools/tests/$checks" ] || { echo "skip $name (no $checks yet)"; return 0; }
    cp "tools/tests/$checks" "$out/main.swift"
    swiftc -O -o "$out/$name" "${base[@]}" "$@" "$out/main.swift"
    "$out/$name"
}

want=("$@"); [ ${#want[@]} -eq 0 ] && want=(policy log evidence completion github context display store)
for suite in "${want[@]}"; do
    case $suite in
        policy)     run policy IssueLifecyclePolicyChecks.swift ;;
        log)        run log IssueTransitionLogChecks.swift "$M/IssueTransitionLog.swift" tools/tests/IssueLogSupport.swift ;;
        evidence)   run evidence IssueEvidenceChecks.swift "$M/IssueLifecycleEvidence.swift" ;;
        completion) run completion IssueCompletionChecks.swift "$M/IssueTransitionLog.swift" tools/tests/IssueLogSupport.swift "$M/IssueCompletion.swift" "$M/IssueReconciler.swift" ;;
        github)     run github IssueGitHubSyncChecks.swift "$M/IssueTransitionLog.swift" tools/tests/IssueLogSupport.swift "$M/IssueCompletion.swift" "$M/IssueSync.swift" "$M/IssueGitHubSync.swift" ;;
        context)    run context IssueContextChecks.swift "$M/IssueTransitionLog.swift" "$M/IssueCompletion.swift" "$M/IssueLifecycleContext.swift" ;;
        display)    run display IssueDisplayChecks.swift "$M/IssueTransitionLog.swift" "$M/IssueLifecycleDisplay.swift" ;;
        store)      run store IssueStoreChecks.swift "$M/FrontMatter.swift" "$M/IssueTransitionLog.swift" "$M/IssueCompletion.swift" "$M/IssueReconciler.swift" "$M/MarkdownIssueStatusStore.swift" ;;
        *) echo "unknown suite $suite"; exit 2 ;;
    esac
done
