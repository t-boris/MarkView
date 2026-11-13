//go:build integration

package localserver

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	cockpit "github.com/t-boris/MarkView/cockpit-temporal"
	"github.com/t-boris/MarkView/cockpit-temporal/localtls"
	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/worker"
)

// The packaged helper holds stdin open while the app is alive; EOF must stop the service.
func launchPackaged(ctx context.Context, binary string, opts Options) (Endpoint, func() error, error) {
	cmd := exec.CommandContext(ctx, binary, "--runtime", opts.Runtime, "--state", opts.State, "--postgres", opts.PostgresBinaries, "--supervisor", opts.PostgresSupervisor)
	input, err := cmd.StdinPipe()
	if err != nil {
		return Endpoint{}, nil, err
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		return Endpoint{}, nil, err
	}
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		return Endpoint{}, nil, err
	}
	var endpoint Endpoint
	if err := json.NewDecoder(output).Decode(&endpoint); err != nil {
		_ = input.Close()
		_ = cmd.Wait()
		return Endpoint{}, nil, err
	}
	return endpoint, func() error { _ = input.Close(); return cmd.Wait() }, nil
}

func TestLocalTemporalStartsAndRestarts(t *testing.T) {
	binaries, supervisor := os.Getenv("MARKVIEW_TEST_POSTGRES"), os.Getenv("MARKVIEW_TEST_SUPERVISOR")
	if binaries == "" || supervisor == "" {
		t.Skip("packaged PostgreSQL paths not supplied")
	}
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	stateDir := filepath.Join(root, "state")
	for n := 0; n < 2; n++ {
		func() {
			runtime := filepath.Join(root, "runtime-"+string(rune('a'+n)))
			ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
			defer cancel()
			options := Options{Runtime: runtime, State: stateDir, PostgresBinaries: binaries, PostgresSupervisor: supervisor}
			var endpoint Endpoint
			var closeServer func() error
			if binary := os.Getenv("MARKVIEW_TEST_SERVER"); binary != "" {
				var err error
				endpoint, closeServer, err = launchPackaged(ctx, binary, options)
				if err != nil {
					t.Fatal(err)
				}
			} else {
				server, err := Start(ctx, options)
				if err != nil {
					t.Fatal(err)
				}
				endpoint, closeServer = server.Endpoint, server.Close
			}
			defer func() {
				if closeServer != nil {
					_ = closeServer()
				}
			}()
			tlsConfig, err := localtls.Client(endpoint.TLS)
			if err != nil {
				t.Fatal(err)
			}
			connection, err := client.DialContext(ctx, client.Options{HostPort: endpoint.Address, ConnectionOptions: client.ConnectionOptions{TLS: tlsConfig}})
			if err != nil {
				t.Fatal(err)
			}
			defer connection.Close()
			w := worker.New(connection, "integration", worker.Options{})
			w.RegisterWorkflow(cockpit.Execute)
			if err := w.Start(); err != nil {
				t.Fatal(err)
			}
			defer w.Stop()
			if n == 0 {
				_, err = connection.ExecuteWorkflow(ctx, client.StartWorkflowOptions{ID: "persistent-run", TaskQueue: "integration"}, cockpit.Execute,
					cockpit.Plan{Fingerprint: "reviewed", Steps: []cockpit.Step{{ID: "one", Agent: "Codex", Assignment: "Work"}}})
				if err != nil {
					t.Fatal(err)
				}
			}
			var state cockpit.State
			for tries := 0; tries < 30; tries++ {
				query, queryErr := connection.QueryWorkflow(ctx, "persistent-run", "", "state")
				if queryErr == nil {
					queryErr = query.Get(&state)
				}
				if queryErr == nil {
					break
				}
				if tries == 29 {
					t.Fatal(fmt.Errorf("query persisted workflow: %w", queryErr))
				}
				time.Sleep(time.Second)
			}
			if state.Status != "awaiting-approval" {
				t.Fatalf("unexpected persisted state: %+v", state)
			}
			w.Stop()
			connection.Close()
			if err := closeServer(); err != nil {
				t.Fatal(err)
			}
			closeServer = nil
		}()
	}
}
