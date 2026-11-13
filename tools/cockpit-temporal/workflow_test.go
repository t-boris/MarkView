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
