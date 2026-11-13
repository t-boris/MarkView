//go:build integration

package localserver

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	cockpit "github.com/t-boris/MarkView/cockpit-temporal"
	"github.com/t-boris/MarkView/cockpit-temporal/localtls"
	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/worker"
	"go.temporal.io/server/common/log"
)

func TestLocalTemporalStartsAndRestarts(t *testing.T) {
	binaries, supervisor := os.Getenv("MARKVIEW_TEST_POSTGRES"), os.Getenv("MARKVIEW_TEST_SUPERVISOR")
	if binaries == "" || supervisor == "" {
		t.Skip("packaged PostgreSQL paths not supplied")
	}
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(root, "state")
	for n := 0; n < 2; n++ {
		runtime := filepath.Join(root, "runtime-"+string(rune('a'+n)))
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		server, err := Start(ctx, Options{Runtime: runtime, State: state, PostgresBinaries: binaries, PostgresSupervisor: supervisor, Logger: log.NewCLILogger()})
		if err != nil {
			cancel()
			t.Fatal(err)
		}
		tlsConfig, err := localtls.Client(server.Endpoint.TLS)
		if err != nil {
			t.Fatal(err)
		}
		connection, err := client.DialContext(ctx, client.Options{HostPort: server.Endpoint.Address, ConnectionOptions: client.ConnectionOptions{TLS: tlsConfig}})
		if err != nil {
			t.Fatal(err)
		}
		w := worker.New(connection, "integration", worker.Options{})
		w.RegisterWorkflow(cockpit.Execute)
		if err := w.Start(); err != nil {
			t.Fatal(err)
		}
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
		if err := server.Close(); err != nil {
			t.Fatal(err)
		}
		cancel()
	}
}
