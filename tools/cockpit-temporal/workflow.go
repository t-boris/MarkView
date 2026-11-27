package cockpit

import (
	"fmt"
	"strings"
	"time"

	"go.temporal.io/sdk/temporal"
	"go.temporal.io/sdk/workflow"
)

const maxStepRecoveryAttempts = 3

// nonPrerequisiteFailureContinues is the change id of the rule that only a failed prerequisite pauses the run.
const nonPrerequisiteFailureContinues = "non-prerequisite-failure-continues"

// StepRecovery describes a bounded recovery attempt authorized by the approved plan when a prerequisite fails.
type StepRecovery struct {
	Assignment  string `json:"assignment"`
	MaxAttempts int    `json:"maxAttempts"`
}

// Plan is the already reviewed process. The fingerprint ties a start signal to the reviewed plan.
type Plan struct {
	Fingerprint     string   `json:"fingerprint"`
	Goal            string   `json:"goal"`
	Controls        string   `json:"controls"`
	SuccessCriteria []string `json:"successCriteria"`
	Steps           []Step   `json:"steps"`
	InitialResults  []Entry  `json:"initialResults,omitempty"`
}
type Step struct {
	ID                  string        `json:"id"`
	Title               string        `json:"title"`
	Agent               string        `json:"agent"`
	Assignment          string        `json:"assignment"`
	CompletionCondition string        `json:"completionCondition"`
	Prerequisite        bool          `json:"prerequisite"`
	QAScenarioID        string        `json:"qaScenarioID,omitempty"`
	Recovery            *StepRecovery `json:"recovery,omitempty"`
}
type Start struct {
	Fingerprint string `json:"fingerprint"`
	Step        int    `json:"step"`
}
type Revision struct {
	ExpectedFingerprint string `json:"expectedFingerprint"`
	Plan                Plan   `json:"plan"`
	Step                int    `json:"step"`
}
type Result struct {
	Passed          bool      `json:"passed"`
	Detail          string    `json:"detail"`
	Build           string    `json:"build"`
	ScenarioID      string    `json:"scenarioID,omitempty"`
	QARunID         string    `json:"qaRunID,omitempty"`
	Progress        *Progress `json:"progress,omitempty"`
	Interrupted     bool      `json:"interrupted,omitempty"`
	NeededInput     string    `json:"neededInput,omitempty"`
	RecoveryAttempt int       `json:"recoveryAttempt,omitempty"`
	// ContinuedAfterFailure marks a failed step after which the run went on to the next step (a step that is not a prerequisite).
	ContinuedAfterFailure bool `json:"continuedAfterFailure,omitempty"`
}
type Progress struct {
	PassNumber       int               `json:"passNumber"`
	Activity         string            `json:"activity"`
	ScenarioCoverage []string          `json:"scenarioCoverage"`
	Bugs             []string          `json:"bugs"`
	Fixes            []string          `json:"fixes"`
	LatestChange     string            `json:"latestChange"`
	Blockers         []string          `json:"blockers"`
	BuildLogPath     *string           `json:"buildLogPath,omitempty"`
	CriteriaResults  []CriterionResult `json:"criteriaResults,omitempty"`
}
type CriterionResult struct {
	Criterion string `json:"criterion"`
	Met       bool   `json:"met"`
	Evidence  string `json:"evidence"`
}
type Entry struct {
	StepID          string `json:"stepID"`
	PlanFingerprint string `json:"planFingerprint"`
	Result          Result `json:"result"`
}
type StepTask struct {
	Step            Step     `json:"step"`
	PlanFingerprint string   `json:"planFingerprint"`
	Goal            string   `json:"goal"`
	Controls        string   `json:"controls"`
	SuccessCriteria []string `json:"successCriteria"`
	PriorResults    []Entry  `json:"priorResults"`
	IsFinalStep     bool     `json:"isFinalStep"`
	RecoveryAttempt int      `json:"recoveryAttempt,omitempty"`
	// ContinuesAfterFailure tells the host, before the step runs, that the run goes on if this step fails, so the run record
	// follows the workflow's decision instead of making its own.
	ContinuesAfterFailure bool `json:"continuesAfterFailure,omitempty"`
}
type State struct {
	Status             string  `json:"status"`
	Current            int     `json:"current"`
	Reason             string  `json:"reason"`
	NeededInput        string  `json:"neededInput,omitempty"`
	RecoveryAttempts   int     `json:"recoveryAttempts,omitempty"`
	Fingerprint        string  `json:"fingerprint"`
	PendingFingerprint string  `json:"pendingFingerprint"`
	Results            []Entry `json:"results"`
}

func validatePlan(plan Plan) error {
	if plan.Fingerprint == "" || len(plan.Steps) == 0 {
		return fmt.Errorf("invalid plan")
	}
	seen := make(map[string]bool)
	for _, step := range plan.Steps {
		if step.ID == "" || step.Title == "" || step.Agent == "" || step.Assignment == "" || step.CompletionCondition == "" || seen[step.ID] {
			return fmt.Errorf("invalid step")
		}
		if step.Recovery != nil {
			if !step.Prerequisite || strings.TrimSpace(step.Recovery.Assignment) == "" || step.Recovery.MaxAttempts < 1 || step.Recovery.MaxAttempts > maxStepRecoveryAttempts {
				return fmt.Errorf("invalid step recovery")
			}
		}
		seen[step.ID] = true
	}
	return nil
}

func hasPassedPrerequisite(results []Entry, stepID string) bool {
	for _, entry := range results {
		if entry.StepID == stepID && entry.Result.Passed && entry.Result.RecoveryAttempt == 0 {
			return true
		}
	}
	return false
}

// revisionBypassesPrerequisite reports whether starting a revision at revision.Step would skip an
// unpassed prerequisite step in the revised plan while the run is paused on a failed prerequisite.
func revisionBypassesPrerequisite(revision Revision, results []Entry) bool {
	for i := 0; i < revision.Step && i < len(revision.Plan.Steps); i++ {
		if revision.Plan.Steps[i].Prerequisite && !hasPassedPrerequisite(results, revision.Plan.Steps[i].ID) {
			return true
		}
	}
	return false
}

// Execute coordinates separate host activities in order. Activities are never retried by Temporal:
// a lost worker may have made changes, and an automatic replay could repeat them.
func Execute(ctx workflow.Context, plan Plan) (State, error) {
	state := State{Status: "awaiting-approval", Current: -1, Fingerprint: plan.Fingerprint, Results: append([]Entry{}, plan.InitialResults...)}
	if err := validatePlan(plan); err != nil {
		return state, err
	}
	if err := workflow.SetQueryHandler(ctx, "state", func() (State, error) { return state, nil }); err != nil {
		return state, err
	}
	// A failed step that is not a prerequisite is recorded and the run goes on (BUG-130). A run started before this change keeps
	// pausing on every failed step, so that its history replays as it was written.
	failureGatesOnlyPrerequisites := workflow.GetVersion(ctx, nonPrerequisiteFailureContinues, workflow.DefaultVersion, 1) == 1
	starts := workflow.GetSignalChannel(ctx, "approve")
	controls := workflow.GetSignalChannel(ctx, "control")
	revisions := workflow.GetSignalChannel(ctx, "replan")
	var pending *Revision
	failedPrerequisite := false
	recoveryAttempts := 0
	acceptRevision := func(revision Revision) {
		if revision.ExpectedFingerprint != plan.Fingerprint || revision.Plan.Fingerprint == plan.Fingerprint || validatePlan(revision.Plan) != nil || revision.Step < 0 || revision.Step >= len(revision.Plan.Steps) {
			return
		}
		if failedPrerequisite && revisionBypassesPrerequisite(revision, state.Results) {
			return
		}
		pending = &revision
		state.PendingFingerprint = revision.Plan.Fingerprint
	}
	applyRevision := func() {
		plan = pending.Plan
		state.Current = pending.Step
		state.Fingerprint = plan.Fingerprint
		state.PendingFingerprint = ""
		state.Status = "running"
		state.Reason = ""
		state.NeededInput = ""
		state.RecoveryAttempts = 0
		failedPrerequisite = false
		recoveryAttempts = 0
		pending = nil
	}
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
		WaitForCancellation: true,
		RetryPolicy:         &temporal.RetryPolicy{MaximumAttempts: 1},
	})
	runActivity := func(task StepTask) (Result, error, string) {
		var result Result
		activityCtx, cancelActivity := workflow.WithCancel(ctx)
		defer cancelActivity()
		future := workflow.ExecuteActivity(activityCtx, "cockpit.run-step", task)
		var err error
		completed := false
		interruption := ""
		var command string
		for !completed {
			selector := workflow.NewSelector(ctx)
			selector.AddFuture(future, func(f workflow.Future) { err = f.Get(ctx, &result); completed = true })
			selector.AddReceive(controls, func(channel workflow.ReceiveChannel, _ bool) {
				channel.Receive(ctx, &command)
				if command == "stop" || (command == "pause" && interruption == "") {
					interruption = command
					cancelActivity()
				}
			})
			selector.AddReceive(revisions, func(channel workflow.ReceiveChannel, _ bool) {
				var revision Revision
				channel.Receive(ctx, &revision)
				acceptRevision(revision)
			})
			selector.Select(ctx)
		}
		return result, err, interruption
	}
	waitStoppedAfterInterruption := func(reason string) (State, error) {
		state.Status = "interrupted"
		state.Reason = reason
		var command string
		for {
			controls.Receive(ctx, &command)
			if command == "stop" {
				state.Status = "stopped"
				return state, nil
			}
		}
	}
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
			if pending != nil {
				applyRevision()
				break
			}
			selector := workflow.NewSelector(ctx)
			selector.AddReceive(controls, func(channel workflow.ReceiveChannel, _ bool) {
				channel.Receive(ctx, &command)
				if command == "stop" {
					state.Status = "stopped"
				}
				if command == "resume" {
					state.Status = "running"
					state.Reason = ""
				}
			})
			selector.AddReceive(revisions, func(channel workflow.ReceiveChannel, _ bool) {
				var revision Revision
				channel.Receive(ctx, &revision)
				acceptRevision(revision)
			})
			selector.Select(ctx)
		}
		if state.Status == "stopped" {
			return state, nil
		}
		step := plan.Steps[state.Current]
		continuesAfterFailure := failureGatesOnlyPrerequisites && !step.Prerequisite
		result, err, interruption := runActivity(StepTask{
			Step:                  step,
			PlanFingerprint:       plan.Fingerprint,
			Goal:                  plan.Goal,
			Controls:              plan.Controls,
			SuccessCriteria:       plan.SuccessCriteria,
			PriorResults:          append([]Entry{}, state.Results...),
			IsFinalStep:           state.Current == len(plan.Steps)-1,
			ContinuesAfterFailure: continuesAfterFailure,
		})
		if interruption == "stop" {
			state.Status = "stopped"
			return state, nil
		}
		if interruption == "pause" {
			return waitStoppedAfterInterruption("The agent was interrupted; detached background processes may still be running.")
		}
		if err != nil {
			// The activity may have changed the world before failing. Never repeat it here.
			return waitStoppedAfterInterruption(err.Error())
		}
		// The workflow decides, never the host's answer: only a step that is not a prerequisite lets the run go on after failing.
		result.ContinuedAfterFailure = !result.Passed && continuesAfterFailure
		state.Results = append(state.Results, Entry{StepID: step.ID, PlanFingerprint: plan.Fingerprint, Result: result})
		var revision Revision
		for revisions.ReceiveAsync(&revision) {
			acceptRevision(revision)
		}
		if !result.Passed && !result.ContinuedAfterFailure {
			pauseReason := result.Detail
			pauseNeeded := strings.TrimSpace(result.NeededInput)
			if step.Prerequisite && step.Recovery != nil && strings.TrimSpace(step.Recovery.Assignment) != "" && recoveryAttempts < step.Recovery.MaxAttempts && pending == nil {
				recoveryAttempts++
				state.RecoveryAttempts = recoveryAttempts
				recStep := step
				recStep.Title = fmt.Sprintf("Recover prerequisite: %s (attempt %d/%d)", step.Title, recoveryAttempts, step.Recovery.MaxAttempts)
				recStep.Assignment = step.Recovery.Assignment
				recStep.CompletionCondition = fmt.Sprintf("Blocker resolved so prerequisite %q can be re-checked.", step.Title)
				recStep.QAScenarioID = ""
				recResult, recErr, recInterruption := runActivity(StepTask{
					Step:            recStep,
					PlanFingerprint: plan.Fingerprint,
					Goal:            plan.Goal,
					Controls:        plan.Controls,
					SuccessCriteria: plan.SuccessCriteria,
					PriorResults:    append([]Entry{}, state.Results...),
					IsFinalStep:     false,
					RecoveryAttempt: recoveryAttempts,
				})
				if recInterruption == "stop" {
					state.Status = "stopped"
					return state, nil
				}
				if recInterruption == "pause" {
					return waitStoppedAfterInterruption("The agent was interrupted; detached background processes may still be running.")
				}
				if recErr != nil {
					return waitStoppedAfterInterruption(recErr.Error())
				}
				recResult.RecoveryAttempt = recoveryAttempts
				state.Results = append(state.Results, Entry{StepID: step.ID, PlanFingerprint: plan.Fingerprint, Result: recResult})
				for revisions.ReceiveAsync(&revision) {
					acceptRevision(revision)
				}
				if recResult.Passed {
					if pending != nil {
						if revisionBypassesPrerequisite(*pending, state.Results) {
							pending = nil
							state.PendingFingerprint = ""
						} else {
							applyRevision()
						}
					}
					continue
				}
				if strings.TrimSpace(recResult.Detail) != "" {
					pauseReason = recResult.Detail
				}
				if strings.TrimSpace(recResult.NeededInput) != "" {
					pauseNeeded = strings.TrimSpace(recResult.NeededInput)
				}
			}
			failedPrerequisite = step.Prerequisite
			if pending != nil && failedPrerequisite && revisionBypassesPrerequisite(*pending, state.Results) {
				pending = nil
				state.PendingFingerprint = ""
			}
			state.Status = "paused"
			state.Reason = pauseReason
			state.NeededInput = pauseNeeded
			for state.Status == "paused" {
				if pending != nil {
					applyRevision()
					break
				}
				selector := workflow.NewSelector(ctx)
				selector.AddReceive(controls, func(channel workflow.ReceiveChannel, _ bool) {
					channel.Receive(ctx, &command)
					if command == "stop" {
						state.Status = "stopped"
					}
					if command == "retry" {
						state.Status = "running"
						state.Reason = ""
						state.NeededInput = ""
						state.RecoveryAttempts = 0
						failedPrerequisite = false
						recoveryAttempts = 0
					}
				})
				selector.AddReceive(revisions, func(channel workflow.ReceiveChannel, _ bool) {
					var revision Revision
					channel.Receive(ctx, &revision)
					acceptRevision(revision)
				})
				selector.Select(ctx)
			}
			if state.Status == "stopped" {
				return state, nil
			}
			continue
		}
		failedPrerequisite = false
		recoveryAttempts = 0
		state.RecoveryAttempts = 0
		state.NeededInput = ""
		if pending != nil {
			applyRevision()
			continue
		}
		state.Current++
	}
	state.Status = "finished"
	state.Current = -1
	return state, nil
}
