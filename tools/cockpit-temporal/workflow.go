package cockpit

import (
	"fmt"
	"time"

	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/workflow"
)

// Plan is the already reviewed process. The fingerprint ties a start signal to the reviewed plan.
type Plan struct {
	Fingerprint     string
	Goal            string
	Controls        string
	SuccessCriteria []string
	Steps           []Step
}
type Step struct {
	ID           string
	Agent        string
	Assignment   string
	Prerequisite bool
}
type Start struct {
	Fingerprint string
	Step        int
}
type Result struct {
	Passed bool
	Detail string
	Build  string
}
type Entry struct {
	StepID string
	Result Result
}
type StepTask struct {
	Step            Step
	PlanFingerprint string
	Goal            string
	Controls        string
	SuccessCriteria []string
	PriorResults    []Entry
}
type State struct {
	Status  string
	Current int
	Reason  string
	Results []Entry
}

// Execute coordinates separate host activities in order. Activities are never retried by Temporal:
// a lost worker may have made changes, and an automatic replay could repeat them.
func Execute(ctx workflow.Context, plan Plan) (State, error) {
	state := State{Status: "awaiting-approval", Current: -1}
	if plan.Fingerprint == "" || len(plan.Steps) == 0 {
		return state, fmt.Errorf("invalid plan")
	}
	seen := make(map[string]bool)
	for _, step := range plan.Steps {
		if step.ID == "" || step.Agent == "" || step.Assignment == "" || seen[step.ID] {
			return state, fmt.Errorf("invalid step")
		}
		seen[step.ID] = true
	}
	if err := workflow.SetQueryHandler(ctx, "state", func() (State, error) { return state, nil }); err != nil {
		return state, err
	}
	starts := workflow.GetSignalChannel(ctx, "approve")
	controls := workflow.GetSignalChannel(ctx, "control")
	for state.Status == "awaiting-approval" {
		selector := workflow.NewSelector(ctx)
		selector.AddReceive(starts, func(channel workflow.ReceiveChannel, _ bool) {
			var start Start
			channel.Receive(ctx, &start)
			if start.Fingerprint == plan.Fingerprint && start.Step >= 0 && start.Step < len(plan.Steps) {
				state.Current = start.Step
				state.Status = "running"
			}
		})
		selector.AddReceive(controls, func(channel workflow.ReceiveChannel, _ bool) {
			var command string
			channel.Receive(ctx, &command)
			if command == "stop" {
				state.Status = "stopped"
			}
		})
		selector.Select(ctx)
	}
	if state.Status == "stopped" {
		return state, nil
	}
	ctx = workflow.WithActivityOptions(ctx, workflow.ActivityOptions{
		StartToCloseTimeout: 30 * 24 * time.Hour,
		HeartbeatTimeout:    30 * time.Second,
		RetryPolicy:         &temporal.RetryPolicy{MaximumAttempts: 1},
	})
	for state.Current < len(plan.Steps) {
		// Commands are applied only at a step boundary.
		var command string
		for controls.ReceiveAsync(&command) {
			if command == "stop" {
				state.Status = "stopped"
				return state, nil
			}
			if command == "pause" {
				state.Status = "paused"
				state.Reason = "Paused by user"
			}
		}
		for state.Status == "paused" {
			controls.Receive(ctx, &command)
			if command == "stop" {
				state.Status = "stopped"
				return state, nil
			}
			if command == "resume" {
				state.Status = "running"
				state.Reason = ""
			}
		}
		step := plan.Steps[state.Current]
		var result Result
		err := workflow.ExecuteActivity(ctx, "cockpit.run-step", StepTask{Step: step, PlanFingerprint: plan.Fingerprint, Goal: plan.Goal, Controls: plan.Controls, SuccessCriteria: plan.SuccessCriteria, PriorResults: append([]Entry(nil), state.Results...)}).Get(ctx, &result)
		if err != nil {
			// The activity may have changed the world before failing. Never repeat it here.
			state.Status = "interrupted"
			state.Reason = err.Error()
			for {
				controls.Receive(ctx, &command)
				if command == "stop" {
					state.Status = "stopped"
					return state, nil
				}
			}
		}
		state.Results = append(state.Results, Entry{StepID: step.ID, Result: result})
		if !result.Passed {
			state.Status = "paused"
			state.Reason = result.Detail
			for {
				controls.Receive(ctx, &command)
				if command == "stop" {
					state.Status = "stopped"
					return state, nil
				}
				if command == "retry" && step.Prerequisite {
					state.Status = "running"
					state.Reason = ""
					break
				}
			}
			continue
		}
		state.Current++
	}
	state.Status = "finished"
	state.Current = -1
	return state, nil
}
