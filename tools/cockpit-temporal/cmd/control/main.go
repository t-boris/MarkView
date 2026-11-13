package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"time"

	cockpit "github.com/t-boris/MarkView/cockpit-temporal"
	"github.com/t-boris/MarkView/cockpit-temporal/localtls"
	"go.temporal.io/sdk/client"
)

type request struct {
	Address    string         `json:"address"`
	Queue      string         `json:"queue"`
	WorkflowID string         `json:"workflowID"`
	Action     string         `json:"action"`
	Plan       cockpit.Plan   `json:"plan"`
	Approval   cockpit.Start  `json:"approval"`
	Command    string         `json:"command"`
	TLS        localtls.Files `json:"tls"`
}

func validate(req request) error {
	host, _, err := net.SplitHostPort(req.Address)
	if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		return errors.New("a loopback Temporal address is required")
	}
	if req.WorkflowID == "" || len(req.WorkflowID) > 200 {
		return errors.New("a valid workflow ID is required")
	}
	switch req.Action {
	case "start":
		if req.Queue == "" || req.Plan.Fingerprint == "" {
			return errors.New("a queue and plan are required")
		}
	case "approve":
		if req.Approval.Fingerprint == "" || req.Approval.Step < 0 {
			return errors.New("an approval is required")
		}
	case "control":
		if req.Command != "pause" && req.Command != "resume" && req.Command != "retry" && req.Command != "stop" {
			return errors.New("unknown control")
		}
	case "state":
	default:
		return errors.New("unknown action")
	}
	return nil
}

func run(req request) (any, error) {
	if err := validate(req); err != nil {
		return nil, err
	}
	tlsConfig, err := localtls.Client(req.TLS)
	if err != nil {
		return nil, errors.New("local Temporal credentials unavailable")
	}
	c, err := client.Dial(client.Options{HostPort: req.Address, ConnectionOptions: client.ConnectionOptions{TLS: tlsConfig}})
	if err != nil {
		return nil, err
	}
	defer c.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	switch req.Action {
	case "start":
		execution, err := c.ExecuteWorkflow(ctx, client.StartWorkflowOptions{ID: req.WorkflowID, TaskQueue: req.Queue}, cockpit.Execute, req.Plan)
		if err != nil {
			return nil, err
		}
		return map[string]string{"workflowID": execution.GetID(), "runID": execution.GetRunID()}, nil
	case "approve":
		return nil, c.SignalWorkflow(ctx, req.WorkflowID, "", "approve", req.Approval)
	case "control":
		return nil, c.SignalWorkflow(ctx, req.WorkflowID, "", "control", req.Command)
	case "state":
		value, err := c.QueryWorkflow(ctx, req.WorkflowID, "", "state")
		if err != nil {
			return nil, err
		}
		var state cockpit.State
		if err := value.Get(&state); err != nil {
			return nil, err
		}
		return state, nil
	}
	return nil, errors.New("unknown action")
}

func main() {
	var req request
	if err := json.NewDecoder(io.LimitReader(os.Stdin, 1<<20)).Decode(&req); err != nil {
		fmt.Fprintln(os.Stderr, "invalid request")
		os.Exit(2)
	}
	value, err := run(req)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := json.NewEncoder(os.Stdout).Encode(value); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
