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
base=("$M/Lifecycle/FeatureVocabulary.swift" "$M/Lifecycle/IssueListing.swift" "$M/Lifecycle/ProjectWorkflow.swift" "$M/Lifecycle/IssueLifecycle.swift" tools/tests/IssueChecksSupport.swift Packages/MarkViewCore/Sources/MarkViewCore/CoreFiles.swift Packages/MarkViewCore/Sources/MarkViewCore/AppLog.swift)

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
        workflow)   run workflow ProjectWorkflowChecks.swift tools/tests/StoreTestSupport.swift "$M/Lifecycle/IssueLifecycleEvidence.swift" "$M/Lifecycle/WorkflowFlow.swift" "$M/Lifecycle/WorkflowTemplate.swift" "$M/Lifecycle/ProjectWorkflowStore.swift" "$M/Lifecycle/DefinitionOfDone.swift" MarkView/Models/Workspace/SchemaVersionedStore.swift ;;
        events)     run events WorkflowEventChecks.swift "$M/Lifecycle/WorkflowEvents.swift" ;;
        description) run description WorkflowDescriptionChecks.swift "$M/Lifecycle/WorkflowEvents.swift" "$M/Lifecycle/WorkflowDescription.swift" ;;
        proposal)   run proposal WorkflowProposalChecks.swift "$M/Lifecycle/WorkflowEvents.swift" "$M/Lifecycle/WorkflowDescription.swift" "$M/Lifecycle/WorkflowProposal.swift" "$M/Lifecycle/ProjectWorkflowStore.swift" "$M/Lifecycle/IssueLifecycleEvidence.swift" "$M/Lifecycle/WorkflowFlow.swift" "$M/Lifecycle/WorkflowTemplate.swift" "$M/Lifecycle/DefinitionOfDone.swift" MarkView/Models/Workspace/SchemaVersionedStore.swift ;;
        policy)     run policy IssueLifecyclePolicyChecks.swift ;;
        log)        run log IssueTransitionLogChecks.swift "$M/Lifecycle/IssueTransitionLog.swift" tools/tests/IssueLogSupport.swift "$M/Lifecycle/WorkflowEvents.swift" ;;
        evidence)   run evidence IssueEvidenceChecks.swift "$M/Lifecycle/IssueLifecycleEvidence.swift" ;;
        collector) swiftc -parse-as-library -O -o "$out/collector" "${base[@]}" "$M/Lifecycle/IssueLifecycleEvidence.swift" "$M/Lifecycle/IssueEvidenceCollector.swift" tools/tests/IssueCollectorChecks.swift; "$out/collector" ;;
        completion) run completion IssueCompletionChecks.swift "$M/Lifecycle/IssueTransitionLog.swift" tools/tests/IssueLogSupport.swift "$M/Lifecycle/IssueCompletion.swift" "$M/Lifecycle/IssueReconciler.swift" ;;
        github)     run github IssueGitHubSyncChecks.swift "$M/Lifecycle/IssueTransitionLog.swift" tools/tests/IssueLogSupport.swift "$M/Lifecycle/IssueCompletion.swift" "$M/Lifecycle/IssueSync.swift" "$M/Lifecycle/IssueGitHubSync.swift" ;;
        context)    run context IssueContextChecks.swift "$M/Lifecycle/IssueTransitionLog.swift" "$M/Lifecycle/IssueCompletion.swift" "$M/Lifecycle/IssueLifecycleContext.swift" ;;
        display)    run display IssueDisplayChecks.swift "$M/Lifecycle/IssueTransitionLog.swift" "$M/Lifecycle/IssueLifecycleDisplay.swift" ;;
        store)      run store IssueStoreChecks.swift "$M/Workspace/FrontMatter.swift" "$M/Lifecycle/IssueTransitionLog.swift" "$M/Lifecycle/IssueCompletion.swift" "$M/Lifecycle/IssueReconciler.swift" "$M/Lifecycle/MarkdownIssueStatusStore.swift" ;;
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
