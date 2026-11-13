package cockpit

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func socket(t *testing.T) (string, net.Listener) {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "mv-cockpit-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	path := filepath.Join(dir, "host.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	return path, listener
}

func TestHostReceivesTaskAndReturnsResult(t *testing.T) {
	path, listener := socket(t)
	seen := make(chan StepTask, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var task StepTask
		if json.NewDecoder(conn).Decode(&task) != nil {
			return
		}
		seen <- task
		_ = json.NewEncoder(conn).Encode(hostReply{Result: Result{Passed: true, Build: "b1"}})
	}()
	task := StepTask{Step: Step{ID: "one", Agent: "Codex", Assignment: "inspect"}, Controls: "no deployment"}
	result, err := (HostActivity{Socket: path}).send(context.Background(), task)
	if err != nil || !result.Passed || result.Build != "b1" {
		t.Fatalf("result %+v: %v", result, err)
	}
	if got := <-seen; got.Step.ID != "one" || got.Controls != task.Controls {
		t.Fatalf("wrong task: %+v", got)
	}
}

func TestHostRejectsPublicSocketAndCancelsWait(t *testing.T) {
	path, listener := socket(t)
	if err := os.Chmod(path, 0666); err != nil {
		t.Fatal(err)
	}
	if _, err := (HostActivity{Socket: path}).send(context.Background(), StepTask{}); err == nil {
		t.Fatal("public socket accepted")
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	go func() {
		conn, err := listener.Accept()
		if err == nil {
			defer conn.Close()
			_, _ = conn.Read(make([]byte, 4096))
			time.Sleep(time.Second)
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := (HostActivity{Socket: path}).send(ctx, StepTask{}); err == nil {
		t.Fatal("cancelled wait succeeded")
	}
}
