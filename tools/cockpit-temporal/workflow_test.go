package cockpit

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"go.temporal.io/sdk/activity"
	"go.temporal.io/sdk/testsuite"
	"go.temporal.io/sdk/worker"
	"go.temporal.io/sdk/workflow"
)

func TestApprovalAndPrerequisiteRetry(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	var calls atomic.Int32
	env.RegisterActivityWithOptions(func(_ context.Context, task StepTask) (Result, error) {
		n := calls.Add(1)
		if n == 3 && (task.PlanFingerprint != "reviewed" || len(task.PriorResults) != 2) {
			t.Error("the next agent did not receive prior results and their plan")
		}
		if task.Step.Prerequisite && n == 1 {
			return Result{Passed: false, Detail: "unavailable"}, nil
		}
		return Result{Passed: true, Detail: "done", Build: "build-1"}, nil
	}, activity.RegisterOptions{Name: "cockpit.run-step"})
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "wrong", Step: 0}) }, time.Second)
	env.RegisterDelayedCallback(func() {
		if calls.Load() != 0 {
			t.Error("activity ran without matching approval")
		}
		env.SignalWorkflow("approve", Start{Fingerprint: "reviewed", Step: 0})
	}, 2*time.Second)
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("control", "retry") }, 3*time.Second)
	env.ExecuteWorkflow(Execute, Plan{Fingerprint: "reviewed", Steps: []Step{
		{ID: "pre", Title: "Step", Agent: "Codex", Assignment: "Check", CompletionCondition: "Done", Prerequisite: true},
		{ID: "work", Title: "Step", Agent: "Claude", Assignment: "Do work", CompletionCondition: "Done"},
	}})
	if err := env.GetWorkflowError(); err != nil {
		t.Fatal(err)
	}
	var state State
	if err := env.GetWorkflowResult(&state); err != nil {
		t.Fatal(err)
	}
	if state.Status != "finished" || calls.Load() != 3 || len(state.Results) != 3 || state.Results[0].Result.Passed {
		t.Fatalf("unexpected state: %+v, calls %d", state, calls.Load())
	}
}

func TestInterruptedActivityIsNotRetried(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	var calls atomic.Int32
	env.RegisterActivityWithOptions(func(_ context.Context, _ StepTask) (Result, error) {
		calls.Add(1)
		return Result{}, errors.New("connection lost")
	}, activity.RegisterOptions{Name: "cockpit.run-step"})
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "x", Step: 0}) }, time.Second)
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("control", "resume") }, 2*time.Second)
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("control", "stop") }, 3*time.Second)
	env.ExecuteWorkflow(Execute, Plan{Fingerprint: "x", Steps: []Step{{ID: "one", Title: "Step", Agent: "Codex", Assignment: "Change", CompletionCondition: "Done"}}})
	if err := env.GetWorkflowError(); err != nil {
		t.Fatal(err)
	}
	var state State
	if err := env.GetWorkflowResult(&state); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 || state.Status != "stopped" {
		t.Fatalf("activity was replayed or did not stop: %+v, calls %d", state, calls.Load())
	}
}

func TestSelectedStepSkipsPrevious(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	var called string
	env.RegisterActivityWithOptions(func(_ context.Context, task StepTask) (Result, error) {
		called = task.Step.ID
		return Result{Passed: true}, nil
	}, activity.RegisterOptions{Name: "cockpit.run-step"})
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "x", Step: 1}) }, time.Second)
	env.ExecuteWorkflow(Execute, Plan{Fingerprint: "x", Steps: []Step{
		{ID: "pre", Title: "Step", Agent: "Codex", Assignment: "Check", CompletionCondition: "Done", Prerequisite: true},
		{ID: "work", Title: "Step", Agent: "Codex", Assignment: "Work", CompletionCondition: "Done"},
	}})
	if err := env.GetWorkflowError(); err != nil {
		t.Fatal(err)
	}
	if called != "work" {
		t.Fatalf("wrong step: %s", called)
	}
}

func TestStopBeforeApproval(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("control", "stop") }, time.Second)
	env.ExecuteWorkflow(Execute, Plan{Fingerprint: "x", Steps: []Step{{ID: "one", Title: "Step", Agent: "Codex", Assignment: "Work", CompletionCondition: "Done"}}})
	if err := env.GetWorkflowError(); err != nil {
		t.Fatal(err)
	}
	var state State
	if err := env.GetWorkflowResult(&state); err != nil {
		t.Fatal(err)
	}
	if state.Status != "stopped" {
		t.Fatalf("unexpected state: %+v", state)
	}
}

func TestPauseInterruptsActiveStep(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	env.SetWorkerOptions(worker.Options{MaxHeartbeatThrottleInterval: time.Millisecond})
	var calls, cancelled atomic.Int32
	release := make(chan struct{})
	defer close(release)
	env.SetOnActivityCanceledListener(func(*activity.Info) { cancelled.Add(1) })
	env.RegisterActivityWithOptions(func(ctx context.Context, _ StepTask) (Result, error) {
		calls.Add(1)
		for {
			activity.RecordHeartbeat(ctx, "running")
			select {
			case <-ctx.Done():
				return Result{}, ctx.Err()
			case <-release:
				return Result{}, errors.New("test ended")
			case <-time.After(10 * time.Millisecond):
			}
		}
	}, activity.RegisterOptions{Name: "cockpit.run-step"})
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "x", Step: 0}) }, time.Second)
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("control", "pause") }, 2*time.Second)
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("control", "resume") }, 3*time.Second)
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("control", "stop") }, 4*time.Second)
	env.ExecuteWorkflow(Execute, Plan{Fingerprint: "x", Steps: []Step{{ID: "one", Title: "Step", Agent: "Codex", Assignment: "Work", CompletionCondition: "Done"}}})
	if err := env.GetWorkflowError(); err != nil {
		t.Fatal(err)
	}
	var state State
	if err := env.GetWorkflowResult(&state); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 1 || cancelled.Load() != 1 || state.Status != "stopped" {
		t.Fatalf("active step was not interrupted exactly once: %+v, calls %d, cancellations %d", state, calls.Load(), cancelled.Load())
	}
}

func TestApprovedRevisionWaitsForStepBoundary(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	release := make(chan struct{})
	var called []string
	env.RegisterActivityWithOptions(func(_ context.Context, task StepTask) (Result, error) {
		called = append(called, task.Step.ID+":"+task.PlanFingerprint)
		if task.Step.ID == "old" {
			<-release
		}
		return Result{Passed: true}, nil
	}, activity.RegisterOptions{Name: "cockpit.run-step"})
	old := Plan{Fingerprint: "old-plan", Steps: []Step{
		{ID: "old", Title: "Old", Agent: "Codex", Assignment: "Work", CompletionCondition: "Done"},
		{ID: "obsolete", Title: "Obsolete", Agent: "Codex", Assignment: "Work", CompletionCondition: "Done"},
	}}
	next := Plan{Fingerprint: "new-plan", Steps: []Step{
		{ID: "new", Title: "New", Agent: "Codex", Assignment: "New work", CompletionCondition: "Done"},
	}}
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "old-plan", Step: 0}) }, time.Second)
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("replan", Revision{ExpectedFingerprint: "wrong", Plan: next, Step: 0}) }, 1500*time.Millisecond)
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("replan", Revision{ExpectedFingerprint: "old-plan", Plan: next, Step: 0}) }, 2*time.Second)
	env.RegisterDelayedCallback(func() { close(release) }, 3*time.Second)
	env.ExecuteWorkflow(Execute, old)
	if err := env.GetWorkflowError(); err != nil {
		t.Fatal(err)
	}
	var state State
	if err := env.GetWorkflowResult(&state); err != nil {
		t.Fatal(err)
	}
	if len(called) != 2 || called[0] != "old:old-plan" || called[1] != "new:new-plan" || len(state.Results) != 2 ||
		state.Results[0].PlanFingerprint != "old-plan" || state.Results[1].PlanFingerprint != "new-plan" || state.Fingerprint != "new-plan" {
		t.Fatalf("revision did not apply at the boundary: %+v, calls %v", state, called)
	}
}

func TestContinuationCarriesInterruptedEvidence(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	var received []Entry
	env.RegisterActivityWithOptions(func(_ context.Context, task StepTask) (Result, error) {
		received = task.PriorResults
		return Result{Passed: true}, nil
	}, activity.RegisterOptions{Name: "cockpit.run-step"})
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "resume", Step: 0}) }, time.Second)
	plan := Plan{Fingerprint: "resume", Steps: []Step{{ID: "step", Title: "Continue", Agent: "Codex", Assignment: "Work", CompletionCondition: "Done"}},
		InitialResults: []Entry{{StepID: "earlier", PlanFingerprint: "old", Result: Result{Interrupted: true, Detail: "partial", Progress: &Progress{PassNumber: 1, Activity: "changed"}}}}}
	env.ExecuteWorkflow(Execute, plan)
	if err := env.GetWorkflowError(); err != nil {
		t.Fatal(err)
	}
	if len(received) != 1 || !received[0].Result.Interrupted || received[0].Result.Progress == nil || received[0].Result.Progress.Activity != "changed" {
		t.Fatalf("continuation lost interrupted evidence: %+v", received)
	}
}

func TestFailedPrerequisiteRevisionCannotBypassUnpassedPrerequisite(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	var called []string
	var prereqCalls atomic.Int32
	env.RegisterActivityWithOptions(func(_ context.Context, task StepTask) (Result, error) {
		called = append(called, task.Step.ID+":"+task.PlanFingerprint)
		if task.Step.Prerequisite && prereqCalls.Add(1) == 1 {
			return Result{Passed: false, Detail: "Redirected to sign-in", NeededInput: "Supply a production test account"}, nil
		}
		return Result{Passed: true, Detail: "ok"}, nil
	}, activity.RegisterOptions{Name: "cockpit.run-step"})

	initial := Plan{Fingerprint: "fp-1", Steps: []Step{
		{ID: "pre-1", Title: "Check login", Agent: "Codex", Assignment: "Check", CompletionCondition: "Signed in", Prerequisite: true},
		{ID: "dep-1", Title: "Dependent work", Agent: "Codex", Assignment: "Work", CompletionCondition: "Done"},
	}}
	// Refined plan with new UUIDs where step 0 is still an unpassed prerequisite.
	bypassSameID := Plan{Fingerprint: "fp-bypass-same", Steps: []Step{
		{ID: "pre-1", Title: "Check login", Agent: "Codex", Assignment: "Check revised", CompletionCondition: "Signed in", Prerequisite: true},
		{ID: "dep-1", Title: "Dependent work", Agent: "Codex", Assignment: "Work", CompletionCondition: "Done"},
	}}
	bypassNewID := Plan{Fingerprint: "fp-bypass-new", Steps: []Step{
		{ID: "pre-2", Title: "Check login revised", Agent: "Codex", Assignment: "Check revised", CompletionCondition: "Signed in", Prerequisite: true},
		{ID: "dep-2", Title: "Dependent work", Agent: "Codex", Assignment: "Work", CompletionCondition: "Done"},
	}}
	validRevision := Plan{Fingerprint: "fp-valid", Steps: []Step{
		{ID: "pre-2", Title: "Check login revised", Agent: "Codex", Assignment: "Use test account", CompletionCondition: "Signed in", Prerequisite: true},
		{ID: "dep-2", Title: "Dependent work", Agent: "Codex", Assignment: "Work", CompletionCondition: "Done"},
	}}

	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "fp-1", Step: 0}) }, time.Second)
	env.RegisterDelayedCallback(func() {
		// Both bypass revisions target Step 1 while Step 0 is still an unpassed prerequisite: both must be ignored.
		env.SignalWorkflow("replan", Revision{ExpectedFingerprint: "fp-1", Plan: bypassSameID, Step: 1})
		env.SignalWorkflow("replan", Revision{ExpectedFingerprint: "fp-1", Plan: bypassNewID, Step: 1})
	}, 2*time.Second)
	env.RegisterDelayedCallback(func() {
		value, err := env.QueryWorkflow("state")
		if err != nil {
			t.Errorf("query failed: %v", err)
			return
		}
		var state State
		if err := value.Get(&state); err != nil {
			t.Errorf("decode failed: %v", err)
			return
		}
		if state.Status != "paused" || state.Fingerprint != "fp-1" || state.NeededInput != "Supply a production test account" {
			t.Errorf("bypass revision should not resume paused prerequisite: %+v", state)
		}
		// Valid revision starts at the prerequisite (Step 0).
		env.SignalWorkflow("replan", Revision{ExpectedFingerprint: "fp-1", Plan: validRevision, Step: 0})
	}, 3*time.Second)

	env.ExecuteWorkflow(Execute, initial)
	if err := env.GetWorkflowError(); err != nil {
		t.Fatal(err)
	}
	var state State
	if err := env.GetWorkflowResult(&state); err != nil {
		t.Fatal(err)
	}
	wantCalled := []string{"pre-1:fp-1", "pre-2:fp-valid", "dep-2:fp-valid"}
	if len(called) != len(wantCalled) || called[0] != wantCalled[0] || called[1] != wantCalled[1] || called[2] != wantCalled[2] {
		t.Fatalf("unexpected execution order: got %v, want %v", called, wantCalled)
	}
	if state.Status != "finished" || len(state.Results) != 3 || state.Results[0].PlanFingerprint != "fp-1" || state.Results[1].PlanFingerprint != "fp-valid" {
		t.Fatalf("earlier result lost its original fingerprint: %+v", state)
	}
}

func TestFailedPrerequisiteRevisionAllowedWhenPrerequisiteRemoved(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	var called []string
	env.RegisterActivityWithOptions(func(_ context.Context, task StepTask) (Result, error) {
		called = append(called, task.Step.ID)
		if task.Step.ID == "pre-1" {
			return Result{Passed: false, Detail: "unavailable"}, nil
		}
		return Result{Passed: true, Detail: "ok"}, nil
	}, activity.RegisterOptions{Name: "cockpit.run-step"})

	initial := Plan{Fingerprint: "fp-1", Steps: []Step{
		{ID: "pre-1", Title: "Check", Agent: "Codex", Assignment: "Check", CompletionCondition: "Ok", Prerequisite: true},
		{ID: "dep-1", Title: "Work", Agent: "Codex", Assignment: "Work", CompletionCondition: "Done"},
	}}
	relaxed := Plan{Fingerprint: "fp-2", Steps: []Step{
		{ID: "pre-1", Title: "Check", Agent: "Codex", Assignment: "Check", CompletionCondition: "Ok", Prerequisite: false},
		{ID: "dep-1", Title: "Work", Agent: "Codex", Assignment: "Work", CompletionCondition: "Done"},
	}}

	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "fp-1", Step: 0}) }, time.Second)
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("replan", Revision{ExpectedFingerprint: "fp-1", Plan: relaxed, Step: 1}) }, 2*time.Second)

	env.ExecuteWorkflow(Execute, initial)
	if err := env.GetWorkflowError(); err != nil {
		t.Fatal(err)
	}
	if len(called) != 2 || called[0] != "pre-1" || called[1] != "dep-1" {
		t.Fatalf("expected revision with removed prerequisite to run step 1, got %v", called)
	}
}

func TestFailedPrerequisiteBoundedRecoverySucceedsAndReruns(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	var attempts []string
	prereqRuns := 0
	env.RegisterActivityWithOptions(func(_ context.Context, task StepTask) (Result, error) {
		if task.RecoveryAttempt > 0 {
			attempts = append(attempts, "recover:"+task.Step.Assignment)
			if len(task.PriorResults) != 1 || task.PriorResults[0].Result.Passed {
				t.Errorf("recovery did not receive failed prerequisite evidence: %+v", task.PriorResults)
			}
			return Result{Passed: true, Detail: "Created test account"}, nil
		}
		attempts = append(attempts, "step:"+task.Step.ID)
		if task.Step.ID == "pre" {
			prereqRuns++
			if prereqRuns == 1 {
				return Result{Passed: false, Detail: "Sign-in required", NeededInput: "Need account"}, nil
			}
		}
		return Result{Passed: true, Detail: "Passed"}, nil
	}, activity.RegisterOptions{Name: "cockpit.run-step"})

	plan := Plan{Fingerprint: "fp-rec", Steps: []Step{
		{ID: "pre", Title: "Check chat", Agent: "Codex", Assignment: "Send test chat", CompletionCondition: "Reply received", Prerequisite: true,
			Recovery: &StepRecovery{Assignment: "Create disposable test account", MaxAttempts: 1}},
		{ID: "dep", Title: "Run QA", Agent: "Codex", Assignment: "Run QA", CompletionCondition: "Done"},
	}}
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "fp-rec", Step: 0}) }, time.Second)

	env.ExecuteWorkflow(Execute, plan)
	if err := env.GetWorkflowError(); err != nil {
		t.Fatal(err)
	}
	var state State
	if err := env.GetWorkflowResult(&state); err != nil {
		t.Fatal(err)
	}
	want := []string{"step:pre", "recover:Create disposable test account", "step:pre", "step:dep"}
	if len(attempts) != len(want) || attempts[0] != want[0] || attempts[1] != want[1] || attempts[2] != want[2] || attempts[3] != want[3] {
		t.Fatalf("unexpected bounded recovery sequence: got %v, want %v", attempts, want)
	}
	if state.Status != "finished" || len(state.Results) != 4 || state.Results[1].Result.RecoveryAttempt != 1 {
		t.Fatalf("unexpected final state after recovery: %+v", state)
	}
	for _, entry := range state.Results {
		if entry.PlanFingerprint != "fp-rec" {
			t.Fatalf("expected original plan fingerprint on all entries, got %+v", entry)
		}
	}
}

func TestFailedPrerequisiteBoundedRecoveryExhaustedKeepsDependentPaused(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	var sequence []string
	var retried atomic.Bool
	env.RegisterActivityWithOptions(func(_ context.Context, task StepTask) (Result, error) {
		if task.RecoveryAttempt > 0 {
			sequence = append(sequence, "recover")
			return Result{Passed: true, Detail: "Attempted sign-in"}, nil
		}
		sequence = append(sequence, task.Step.ID)
		if task.Step.ID == "pre" && !retried.Load() {
			return Result{Passed: false, Detail: "MFA required", NeededInput: "Provide MFA code"}, nil
		}
		return Result{Passed: true, Detail: "Passed"}, nil
	}, activity.RegisterOptions{Name: "cockpit.run-step"})

	plan := Plan{Fingerprint: "fp-exhaust", Steps: []Step{
		{ID: "pre", Title: "Check chat", Agent: "Codex", Assignment: "Check", CompletionCondition: "Ok", Prerequisite: true,
			Recovery: &StepRecovery{Assignment: "Try saved login", MaxAttempts: 1}},
		{ID: "dep", Title: "Dependent", Agent: "Codex", Assignment: "Work", CompletionCondition: "Done"},
	}}
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "fp-exhaust", Step: 0}) }, time.Second)
	env.RegisterDelayedCallback(func() {
		value, err := env.QueryWorkflow("state")
		if err != nil {
			t.Errorf("query failed: %v", err)
			return
		}
		var state State
		if err := value.Get(&state); err != nil {
			t.Errorf("decode failed: %v", err)
			return
		}
		if state.Status != "paused" || state.NeededInput != "Provide MFA code" {
			t.Errorf("expected paused state requesting MFA code, got %+v", state)
		}
		retried.Store(true)
		env.SignalWorkflow("control", "retry")
	}, 3*time.Second)

	env.ExecuteWorkflow(Execute, plan)
	if err := env.GetWorkflowError(); err != nil {
		t.Fatal(err)
	}
	want := []string{"pre", "recover", "pre", "pre", "dep"}
	if len(sequence) != len(want) || sequence[0] != want[0] || sequence[1] != want[1] || sequence[2] != want[2] || sequence[3] != want[3] || sequence[4] != want[4] {
		t.Fatalf("unexpected sequence: got %v, want %v", sequence, want)
	}
}

func TestFailedNonPrerequisiteStepIsRecordedAndTheRunGoesOn(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	var sequence []string
	env.RegisterActivityWithOptions(func(_ context.Context, task StepTask) (Result, error) {
		sequence = append(sequence, task.Step.ID)
		if task.ContinuesAfterFailure != (task.Step.ID != "gate") {
			t.Errorf("the host must learn before step %s whether a failure stops the run", task.Step.ID)
		}
		if task.Step.ID == "qa" {
			// A host that claims the run goes on is not trusted: the workflow decides.
			return Result{Passed: false, Detail: "QA blocked at n3", NeededInput: "Open application A"}, nil
		}
		if task.Step.ID == "gate" {
			return Result{Passed: false, Detail: "CI is red", ContinuedAfterFailure: true}, nil
		}
		if task.Step.ID == "fix" && (len(task.PriorResults) != 1 || task.PriorResults[0].Result.Passed || task.PriorResults[0].Result.Detail != "QA blocked at n3") {
			t.Error("the next step did not receive the failed step's result")
		}
		return Result{Passed: true, Detail: "Fixed"}, nil
	}, activity.RegisterOptions{Name: "cockpit.run-step"})

	plan := Plan{Fingerprint: "fp-nonpre", Steps: []Step{
		{ID: "qa", Title: "Discovery QA", Agent: "Codex", Assignment: "Run QA", CompletionCondition: "Every branch reported"},
		{ID: "fix", Title: "Fix what QA found", Agent: "Codex", Assignment: "Fix", CompletionCondition: "Fixed"},
		{ID: "gate", Title: "CI", Agent: "Codex", Assignment: "Check CI", CompletionCondition: "Green", Prerequisite: true},
	}}
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "fp-nonpre", Step: 0}) }, time.Second)
	pausedAtGate := false
	env.RegisterDelayedCallback(func() {
		var paused State
		if value, err := env.QueryWorkflow("state"); err == nil && value.Get(&paused) == nil {
			pausedAtGate = paused.Status == "paused" && paused.Current == 2
		}
		env.SignalWorkflow("control", "stop")
	}, 2*time.Second)

	env.ExecuteWorkflow(Execute, plan)
	if err := env.GetWorkflowError(); err != nil {
		t.Fatal(err)
	}
	var state State
	if err := env.GetWorkflowResult(&state); err != nil {
		t.Fatal(err)
	}
	if !pausedAtGate || state.Status != "stopped" || state.Current != 2 || len(sequence) != 3 || sequence[0] != "qa" || sequence[1] != "fix" || sequence[2] != "gate" {
		t.Fatalf("a failed step that is not a prerequisite must not stop the run, a failed prerequisite must: %+v, sequence %v", state, sequence)
	}
	if len(state.Results) != 3 || state.Results[0].Result.Passed || state.Results[0].Result.NeededInput != "Open application A" ||
		!state.Results[0].Result.ContinuedAfterFailure || !state.Results[1].Result.Passed || state.Results[2].Result.ContinuedAfterFailure {
		t.Fatalf("the failure must stay in the results, marked as gone past: %+v", state.Results)
	}
	if state.Reason != "CI is red" {
		t.Fatalf("the run pauses on the prerequisite with its reason: %+v", state)
	}
}

func TestRunStartedBeforeTheChangeStillPausesOnAFailedStep(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	env.OnGetVersion(nonPrerequisiteFailureContinues, workflow.DefaultVersion, 1).Return(workflow.DefaultVersion)
	var calls atomic.Int32
	env.RegisterActivityWithOptions(func(_ context.Context, _ StepTask) (Result, error) {
		if calls.Add(1) == 1 {
			return Result{Passed: false, Detail: "Temporary error", NeededInput: "Confirm retry"}, nil
		}
		return Result{Passed: true, Detail: "Fixed"}, nil
	}, activity.RegisterOptions{Name: "cockpit.run-step"})

	plan := Plan{Fingerprint: "fp-old", Steps: []Step{
		{ID: "work", Title: "Work", Agent: "Codex", Assignment: "Do work", CompletionCondition: "Done", Prerequisite: false},
	}}
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "fp-old", Step: 0}) }, time.Second)
	env.RegisterDelayedCallback(func() {
		var paused State
		if value, err := env.QueryWorkflow("state"); err != nil || value.Get(&paused) != nil || paused.Status != "paused" || paused.NeededInput != "Confirm retry" {
			t.Errorf("a run of the earlier version pauses on the failed step: %+v %v", paused, err)
		}
		env.SignalWorkflow("control", "retry")
	}, 2*time.Second)

	env.ExecuteWorkflow(Execute, plan)
	if err := env.GetWorkflowError(); err != nil {
		t.Fatal(err)
	}
	var state State
	if err := env.GetWorkflowResult(&state); err != nil {
		t.Fatal(err)
	}
	if state.Status != "finished" || calls.Load() != 2 {
		t.Fatalf("the retried step of an earlier run must pass: %+v, calls %d", state, calls.Load())
	}
}
