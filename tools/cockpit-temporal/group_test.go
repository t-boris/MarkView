package cockpit

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"go.temporal.io/sdk/activity"
	"go.temporal.io/sdk/testsuite"
	"go.temporal.io/sdk/worker"
	"go.temporal.io/sdk/workflow"
)

// groupPlan has a group of two steps between a first and a last step that run on their own.
func groupPlan(fingerprint string, prerequisite bool) Plan {
	return Plan{Fingerprint: fingerprint, Steps: []Step{
		{ID: "first", Title: "First", Agent: "Codex", Assignment: "Prepare", CompletionCondition: "Done"},
		{ID: "a", Title: "Review A", Agent: "Claude", Assignment: "Review", CompletionCondition: "Done", Prerequisite: prerequisite, Group: "reviews"},
		{ID: "b", Title: "Review B", Agent: "Codex", Assignment: "Review", CompletionCondition: "Done", Prerequisite: prerequisite, Group: "reviews"},
		{ID: "last", Title: "Last", Agent: "Codex", Assignment: "Verify", CompletionCondition: "Done"},
	}}
}

// calls records which steps ran, the members each was started with and the prior results it saw.
type calls struct {
	mu      sync.Mutex
	order   []string
	members map[string][]string
	prior   map[string][]string
	count   map[string]int
}

func newCalls() *calls {
	return &calls{members: map[string][]string{}, prior: map[string][]string{}, count: map[string]int{}}
}

func (c *calls) note(task StepTask) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.order = append(c.order, task.Step.ID)
	c.members[task.Step.ID] = task.GroupMembers
	var prior []string
	for _, entry := range task.PriorResults {
		prior = append(prior, entry.StepID)
	}
	c.prior[task.Step.ID] = prior
	c.count[task.Step.ID]++
	return c.count[task.Step.ID]
}

func (c *calls) times(id string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.count[id]
}

func resultIDs(state State) []string {
	var ids []string
	for _, entry := range state.Results {
		ids = append(ids, entry.StepID)
	}
	return ids
}

func finish(t *testing.T, env *testsuite.TestWorkflowEnvironment) State {
	t.Helper()
	if err := env.GetWorkflowError(); err != nil {
		t.Fatal(err)
	}
	var state State
	if err := env.GetWorkflowResult(&state); err != nil {
		t.Fatal(err)
	}
	return state
}

func TestGroupMembersStartTogetherAndTheirResultsGoInPlanOrder(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	seen := newCalls()
	var running atomic.Int32
	bEnded := make(chan struct{})
	env.RegisterActivityWithOptions(func(_ context.Context, task StepTask) (Result, error) {
		seen.note(task)
		if task.Step.Group == "" {
			return Result{Passed: true, Detail: task.Step.ID}, nil
		}
		// Each member waits until the other has started: only members that run at the same time get past this.
		running.Add(1)
		deadline := time.Now().Add(time.Second)
		for running.Load() < 2 {
			if time.Now().After(deadline) {
				return Result{Passed: false, Detail: "the other member never started"}, nil
			}
			time.Sleep(5 * time.Millisecond)
		}
		// B ends first, A after it: the results must still be A, then B.
		if task.Step.ID == "b" {
			defer close(bEnded)
		} else {
			select {
			case <-bEnded:
			case <-time.After(time.Second):
				return Result{Passed: false, Detail: "B did not end"}, nil
			}
		}
		return Result{Passed: true, Detail: task.Step.ID}, nil
	}, activity.RegisterOptions{Name: "cockpit.run-step"})
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "fp", Step: 0}) }, time.Second)
	env.ExecuteWorkflow(Execute, groupPlan("fp", false))
	state := finish(t, env)
	if state.Status != "finished" || !reflect.DeepEqual(resultIDs(state), []string{"first", "a", "b", "last"}) {
		t.Fatalf("the group's results must follow the plan: %+v", resultIDs(state))
	}
	for _, entry := range state.Results {
		if !entry.Result.Passed {
			t.Fatalf("every step passes when the members run at the same time: %+v", entry)
		}
	}
	if !reflect.DeepEqual(seen.members["a"], []string{"a", "b"}) || !reflect.DeepEqual(seen.members["b"], []string{"a", "b"}) || seen.members["first"] != nil {
		t.Fatalf("each member is told whom it runs with, a step on its own is not: %+v", seen.members)
	}
	if !reflect.DeepEqual(seen.prior["a"], []string{"first"}) || !reflect.DeepEqual(seen.prior["b"], []string{"first"}) {
		t.Fatalf("each member receives the results from before the group: %+v", seen.prior)
	}
	if !reflect.DeepEqual(seen.prior["last"], []string{"first", "a", "b"}) {
		t.Fatalf("the next step receives the group's results in plan order: %+v", seen.prior["last"])
	}
}

func TestFailedPrerequisiteMemberPausesAndRetryRunsOnlyTheFailedMembers(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	seen := newCalls()
	env.RegisterActivityWithOptions(func(_ context.Context, task StepTask) (Result, error) {
		if seen.note(task) == 1 && task.Step.ID == "b" {
			return Result{Passed: false, Detail: "Review B found no diff", NeededInput: "Push the branch"}, nil
		}
		return Result{Passed: true, Detail: task.Step.ID}, nil
	}, activity.RegisterOptions{Name: "cockpit.run-step"})
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "fp", Step: 0}) }, time.Second)
	env.RegisterDelayedCallback(func() {
		var paused State
		if value, err := env.QueryWorkflow("state"); err != nil || value.Get(&paused) != nil {
			t.Errorf("state: %v", err)
		}
		if paused.Status != "paused" || paused.Current != 1 || paused.NeededInput != "Push the branch" || len(paused.Results) != 3 {
			t.Errorf("a failed prerequisite member pauses the run at its group after every member ended: %+v", paused)
		}
		if seen.times("last") != 0 {
			t.Error("no step after the group runs while the group is paused")
		}
		env.SignalWorkflow("control", "retry")
	}, 2*time.Second)
	env.ExecuteWorkflow(Execute, groupPlan("fp", true))
	state := finish(t, env)
	if state.Status != "finished" || seen.times("a") != 1 || seen.times("b") != 2 || seen.times("last") != 1 {
		t.Fatalf("a retry runs only the failed member again: %+v, calls %+v", state.Status, seen.count)
	}
	if !reflect.DeepEqual(resultIDs(state), []string{"first", "a", "b", "b", "last"}) || state.Results[2].Result.Passed || !state.Results[3].Result.Passed {
		t.Fatalf("unexpected results: %+v", state.Results)
	}
	if !reflect.DeepEqual(seen.members["b"], []string{"b"}) {
		t.Fatalf("the retried member runs with the members that run again, not with the passed one: %+v", seen.members["b"])
	}
}

func TestFailedMemberThatIsNotAPrerequisiteLetsTheRunGoOn(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	seen := newCalls()
	env.RegisterActivityWithOptions(func(_ context.Context, task StepTask) (Result, error) {
		seen.note(task)
		if task.Step.ID == "a" {
			if !task.ContinuesAfterFailure {
				t.Error("a member that is not a prerequisite is told the run goes on after its failure")
			}
			return Result{Passed: false, Detail: "Found three problems"}, nil
		}
		return Result{Passed: true}, nil
	}, activity.RegisterOptions{Name: "cockpit.run-step"})
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "fp", Step: 0}) }, time.Second)
	env.ExecuteWorkflow(Execute, groupPlan("fp", false))
	state := finish(t, env)
	if state.Status != "finished" || len(state.Results) != 4 || !state.Results[1].Result.ContinuedAfterFailure || state.Results[2].Result.ContinuedAfterFailure {
		t.Fatalf("the failure is recorded and the run goes on: %+v", state.Results)
	}
}

func TestPauseDuringAGroupCancelsEveryMember(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	env.SetWorkerOptions(worker.Options{MaxHeartbeatThrottleInterval: time.Millisecond})
	var cancelled atomic.Int32
	release := make(chan struct{})
	defer close(release)
	env.SetOnActivityCanceledListener(func(*activity.Info) { cancelled.Add(1) })
	seen := newCalls()
	env.RegisterActivityWithOptions(func(ctx context.Context, task StepTask) (Result, error) {
		seen.note(task)
		if task.Step.Group == "" {
			return Result{Passed: true}, nil
		}
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
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "fp", Step: 1}) }, time.Second)
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("control", "pause") }, 2*time.Second)
	env.RegisterDelayedCallback(func() {
		var interrupted State
		if value, err := env.QueryWorkflow("state"); err != nil || value.Get(&interrupted) != nil || interrupted.Status != "interrupted" {
			t.Errorf("a paused group leaves the run interrupted: %+v %v", interrupted, err)
		}
		env.SignalWorkflow("control", "stop")
	}, 3*time.Second)
	env.ExecuteWorkflow(Execute, groupPlan("fp", false))
	state := finish(t, env)
	if state.Status != "stopped" || cancelled.Load() != 2 || seen.times("a") != 1 || seen.times("b") != 1 || len(state.Results) != 0 {
		t.Fatalf("both members are cancelled once and nothing is recorded: %+v, cancellations %d, calls %+v", state, cancelled.Load(), seen.count)
	}
}

func TestAnActivityErrorInAGroupCancelsTheOtherMembers(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	env.SetWorkerOptions(worker.Options{MaxHeartbeatThrottleInterval: time.Millisecond})
	var cancelled atomic.Int32
	release := make(chan struct{})
	defer close(release)
	env.SetOnActivityCanceledListener(func(*activity.Info) { cancelled.Add(1) })
	env.RegisterActivityWithOptions(func(ctx context.Context, task StepTask) (Result, error) {
		if task.Step.ID == "b" {
			return Result{}, errors.New("host: the step result could not be saved")
		}
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
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "fp", Step: 1}) }, time.Second)
	env.RegisterDelayedCallback(func() {
		var interrupted State
		if value, err := env.QueryWorkflow("state"); err != nil || value.Get(&interrupted) != nil ||
			interrupted.Status != "interrupted" || !strings.Contains(interrupted.Reason, "could not be saved") {
			t.Errorf("the run is interrupted with the error: %+v %v", interrupted, err)
		}
		env.SignalWorkflow("control", "stop")
	}, 3*time.Second)
	env.ExecuteWorkflow(Execute, groupPlan("fp", false))
	state := finish(t, env)
	if state.Status != "stopped" || cancelled.Load() != 1 {
		t.Fatalf("the other member is cancelled: %+v, cancellations %d", state, cancelled.Load())
	}
}

func TestKeptMembersOfTheStartingGroupDoNotRunAgain(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	seen := newCalls()
	env.RegisterActivityWithOptions(func(_ context.Context, task StepTask) (Result, error) {
		seen.note(task)
		return Result{Passed: true}, nil
	}, activity.RegisterOptions{Name: "cockpit.run-step"})
	plan := groupPlan("fp", false)
	plan.InitialResults = []Entry{{StepID: "first", PlanFingerprint: "fp", Result: Result{Passed: true}}, {StepID: "a", PlanFingerprint: "fp", Result: Result{Passed: true}}}
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "fp", Step: 1, Kept: []string{"a", "last"}}) }, time.Second)
	env.ExecuteWorkflow(Execute, plan)
	state := finish(t, env)
	if state.Status != "finished" || !reflect.DeepEqual(seen.order, []string{"b", "last"}) {
		t.Fatalf("only the member that did not pass runs again, and a kept id outside the group is ignored: %+v", seen.order)
	}
}

func TestRevisionDuringAGroupWaitsForTheGroupsEnd(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	seen := newCalls()
	gate := make(chan struct{})
	env.RegisterActivityWithOptions(func(_ context.Context, task StepTask) (Result, error) {
		seen.note(task)
		if task.Step.Group != "" && task.PlanFingerprint == "fp" {
			<-gate
		}
		return Result{Passed: true}, nil
	}, activity.RegisterOptions{Name: "cockpit.run-step"})
	revised := groupPlan("fp-2", false)
	revised.Steps[3].Assignment = "Verify again"
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "fp", Step: 1}) }, time.Second)
	env.RegisterDelayedCallback(func() {
		env.SignalWorkflow("replan", Revision{ExpectedFingerprint: "fp", Plan: revised, Step: 3})
	}, 2*time.Second)
	env.RegisterDelayedCallback(func() {
		var running State
		if value, err := env.QueryWorkflow("state"); err != nil || value.Get(&running) != nil || running.PendingFingerprint != "fp-2" || running.Fingerprint != "fp" {
			t.Errorf("the revision waits while the group runs: %+v %v", running, err)
		}
		close(gate)
	}, 3*time.Second)
	env.ExecuteWorkflow(Execute, groupPlan("fp", false))
	state := finish(t, env)
	if state.Status != "finished" || state.Fingerprint != "fp-2" || !reflect.DeepEqual(resultIDs(state), []string{"a", "b", "last"}) ||
		state.Results[2].PlanFingerprint != "fp-2" {
		t.Fatalf("the revision applies after the group: %+v", state)
	}
}

func TestAGroupThePlanDoesNotAllowRunsStepByStep(t *testing.T) {
	cases := map[string]func(*Plan){
		"the last step": func(plan *Plan) { plan.Steps[3].Group = "reviews" },
		"a QA scenario": func(plan *Plan) { plan.Steps[2].QAScenarioID = "login" },
		"a recovery": func(plan *Plan) {
			plan.Steps[1].Prerequisite = true
			plan.Steps[1].Recovery = &StepRecovery{Assignment: "Fix", MaxAttempts: 1}
		},
		"a single member": func(plan *Plan) { plan.Steps[2].Group = "other" },
		"too many members": func(plan *Plan) {
			plan.Steps = append(plan.Steps[:3], plan.Steps[1], plan.Steps[2], plan.Steps[3])
			plan.Steps[3].ID = "c"
			plan.Steps[4].ID = "d"
		},
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			var suite testsuite.WorkflowTestSuite
			env := suite.NewTestWorkflowEnvironment()
			seen := newCalls()
			env.RegisterActivityWithOptions(func(_ context.Context, task StepTask) (Result, error) {
				seen.note(task)
				return Result{Passed: true}, nil
			}, activity.RegisterOptions{Name: "cockpit.run-step"})
			plan := groupPlan("fp", false)
			change(&plan)
			env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "fp", Step: 0}) }, time.Second)
			env.ExecuteWorkflow(Execute, plan)
			state := finish(t, env)
			for id, members := range seen.members {
				if members != nil {
					t.Fatalf("%s ran as a group member: %+v", id, members)
				}
			}
			if state.Status != "finished" || len(state.Results) != len(plan.Steps) {
				t.Fatalf("every step runs on its own: %+v", state)
			}
		})
	}
}

func TestRunStartedBeforeGroupsRunsItsMembersOneAtATime(t *testing.T) {
	var suite testsuite.WorkflowTestSuite
	env := suite.NewTestWorkflowEnvironment()
	env.OnGetVersion(parallelStepGroups, workflow.DefaultVersion, 1).Return(workflow.DefaultVersion)
	seen := newCalls()
	var running, most atomic.Int32
	env.RegisterActivityWithOptions(func(_ context.Context, task StepTask) (Result, error) {
		seen.note(task)
		now := running.Add(1)
		if now > most.Load() {
			most.Store(now)
		}
		time.Sleep(20 * time.Millisecond)
		running.Add(-1)
		return Result{Passed: true}, nil
	}, activity.RegisterOptions{Name: "cockpit.run-step"})
	env.RegisterDelayedCallback(func() { env.SignalWorkflow("approve", Start{Fingerprint: "fp", Step: 0}) }, time.Second)
	env.ExecuteWorkflow(Execute, groupPlan("fp", false))
	state := finish(t, env)
	if state.Status != "finished" || most.Load() != 1 || !reflect.DeepEqual(seen.order, []string{"first", "a", "b", "last"}) || seen.members["a"] != nil {
		t.Fatalf("an earlier run's steps run one at a time: %+v, at most %d at once", seen.order, most.Load())
	}
}
