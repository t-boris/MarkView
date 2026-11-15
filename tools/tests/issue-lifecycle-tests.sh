#!/bin/bash
# Checks the issue lifecycle modules (docs/features/issue-lifecycle-management): the transition policy, the history and
# service, the delivery evidence, verified completion and reconciliation, the GitHub sync planner, the AI context and the
# Lifecycle section's display model, and the project workflow they run on (docs/features/feature-3).
# The app has no XCTest target: each suite is compiled on its own with a test main and run.
#   tools/tests/issue-lifecycle-tests.sh [suite ...]      suites: workflow events description proposal policy log evidence collector completion github context display store
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
M=MarkView/Models
base=("$M/FeatureVocabulary.swift" "$M/IssueListing.swift" "$M/ProjectWorkflow.swift" "$M/IssueLifecycle.swift" tools/tests/IssueChecksSupport.swift)

run() {  # name, checks file, extra sources...
    local name=$1 checks=$2; shift 2
    [ -f "tools/tests/$checks" ] || { echo "skip $name (no $checks yet)"; return 0; }
    mkdir -p "$out/$name"
    cp "tools/tests/$checks" "$out/$name/main.swift"
    swiftc -O -o "$out/$name/bin" "${base[@]}" "$@" "$out/$name/main.swift"
    "$out/$name/bin"
}

run_suite() {
    local suite=$1
    case $suite in
        workflow)   run workflow ProjectWorkflowChecks.swift "$M/IssueLifecycleEvidence.swift" "$M/WorkflowFlow.swift" "$M/WorkflowTemplate.swift" "$M/ProjectWorkflowStore.swift" ;;
        events)     run events WorkflowEventChecks.swift "$M/WorkflowEvents.swift" ;;
        description) run description WorkflowDescriptionChecks.swift "$M/WorkflowEvents.swift" "$M/WorkflowDescription.swift" ;;
        proposal)   run proposal WorkflowProposalChecks.swift "$M/WorkflowEvents.swift" "$M/WorkflowDescription.swift" "$M/WorkflowProposal.swift" "$M/ProjectWorkflowStore.swift" "$M/IssueLifecycleEvidence.swift" "$M/WorkflowFlow.swift" "$M/WorkflowTemplate.swift" ;;
        policy)     run policy IssueLifecyclePolicyChecks.swift ;;
        log)        run log IssueTransitionLogChecks.swift "$M/IssueTransitionLog.swift" tools/tests/IssueLogSupport.swift "$M/WorkflowEvents.swift" ;;
        evidence)   run evidence IssueEvidenceChecks.swift "$M/IssueLifecycleEvidence.swift" ;;
        collector) swiftc -parse-as-library -O -o "$out/collector" "${base[@]}" "$M/IssueLifecycleEvidence.swift" "$M/IssueEvidenceCollector.swift" tools/tests/IssueCollectorChecks.swift; "$out/collector" ;;
        completion) run completion IssueCompletionChecks.swift "$M/IssueTransitionLog.swift" tools/tests/IssueLogSupport.swift "$M/IssueCompletion.swift" "$M/IssueReconciler.swift" ;;
        github)     run github IssueGitHubSyncChecks.swift "$M/IssueTransitionLog.swift" tools/tests/IssueLogSupport.swift "$M/IssueCompletion.swift" "$M/IssueSync.swift" "$M/IssueGitHubSync.swift" ;;
        context)    run context IssueContextChecks.swift "$M/IssueTransitionLog.swift" "$M/IssueCompletion.swift" "$M/IssueLifecycleContext.swift" ;;
        display)    run display IssueDisplayChecks.swift "$M/IssueTransitionLog.swift" "$M/IssueLifecycleDisplay.swift" ;;
        store)      run store IssueStoreChecks.swift "$M/FrontMatter.swift" "$M/IssueTransitionLog.swift" "$M/IssueCompletion.swift" "$M/IssueReconciler.swift" "$M/MarkdownIssueStatusStore.swift" ;;
        *) echo "unknown suite $suite"; exit 2 ;;
    esac
}

want=("$@"); [ ${#want[@]} -eq 0 ] && want=(workflow events description proposal policy log evidence collector completion github context display store)

pids=()
suites_batch=()
flush_batch() {
    local batch_failed=0 i pid s
    if [ ${#pids[@]} -eq 0 ]; then return 0; fi
    for i in "${!pids[@]}"; do
        pid="${pids[$i]}"
        s="${suites_batch[$i]}"
        if wait "$pid"; then
            cat "$out/$s.log"
        else
            cat "$out/$s.log" >&2
            batch_failed=1
        fi
    done
    pids=()
    suites_batch=()
    [ "$batch_failed" -eq 0 ] || exit 1
}

max_jobs=4
for suite in "${want[@]}"; do
    run_suite "$suite" > "$out/$suite.log" 2>&1 &
    pids+=("$!")
    suites_batch+=("$suite")
    if [ ${#pids[@]} -ge "$max_jobs" ]; then
        flush_batch
    fi
done
flush_batch
