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

const testToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// socket listens on a private host.sock and, like the app, leaves the token in host.token next to it.
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
	if err := os.WriteFile(filepath.Join(dir, "host.token"), []byte(testToken), 0600); err != nil {
		t.Fatal(err)
	}
	return path, listener
}

func TestHostReceivesTaskAndReturnsResult(t *testing.T) {
	path, listener := socket(t)
	seen := make(chan hostRequest, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var request hostRequest
		if json.NewDecoder(conn).Decode(&request) != nil {
			return
		}
		seen <- request
		_ = json.NewEncoder(conn).Encode(hostReply{Result: Result{Passed: true, Build: "b1"}})
	}()
	task := StepTask{Step: Step{ID: "one", Agent: "Codex", Assignment: "inspect"}, Controls: "no deployment"}
	result, err := (HostActivity{Socket: path}).send(context.Background(), task)
	if err != nil || !result.Passed || result.Build != "b1" {
		t.Fatalf("result %+v: %v", result, err)
	}
	if got := <-seen; got.Step.ID != "one" || got.Controls != task.Controls || got.Token != testToken {
		t.Fatalf("wrong request: %+v", got)
	}
}

// What the app reads is one JSON object: the task's fields and the token side by side.
func TestHostRequestCarriesTokenBesideTheTask(t *testing.T) {
	body, err := json.Marshal(hostRequest{StepTask: StepTask{Step: Step{ID: "one"}, Goal: "g"}, Token: "t"})
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(body, &fields); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"step", "goal", "controls", "token"} {
		if _, ok := fields[name]; !ok {
			t.Fatalf("request has no %q field: %s", name, body)
		}
	}
}

func TestHostNeverConnectsWithoutAPrivateToken(t *testing.T) {
	for name, damage := range map[string]func(dir string) error{
		"missing":        func(dir string) error { return os.Remove(filepath.Join(dir, "host.token")) },
		"group readable": func(dir string) error { return os.Chmod(filepath.Join(dir, "host.token"), 0640) },
		"world readable": func(dir string) error { return os.Chmod(filepath.Join(dir, "host.token"), 0644) },
		"empty":          func(dir string) error { return os.WriteFile(filepath.Join(dir, "host.token"), []byte(" \n"), 0600) },
		"symbolic link": func(dir string) error {
			real := filepath.Join(dir, "real.token")
			if err := os.Rename(filepath.Join(dir, "host.token"), real); err != nil {
				return err
			}
			return os.Symlink(real, filepath.Join(dir, "host.token"))
		},
		"directory": func(dir string) error {
			if err := os.Remove(filepath.Join(dir, "host.token")); err != nil {
				return err
			}
			return os.Mkdir(filepath.Join(dir, "host.token"), 0700)
		},
	} {
		t.Run(name, func(t *testing.T) {
			path, listener := socket(t)
			connected := make(chan struct{}, 1)
			go func() {
				if conn, err := listener.Accept(); err == nil {
					connected <- struct{}{}
					conn.Close()
				}
			}()
			if err := damage(filepath.Dir(path)); err != nil {
				t.Fatal(err)
			}
			if _, err := (HostActivity{Socket: path}).send(context.Background(), StepTask{}); err == nil {
				t.Fatal("task sent without a private token")
			}
			select {
			case <-connected:
				t.Fatal("worker connected to the host socket without a private token")
			case <-time.After(100 * time.Millisecond):
			}
		})
	}
}

func TestHostTokenFollowsTheSocketNameConvention(t *testing.T) {
	dir := t.TempDir()
	for socket, file := range map[string]string{"host.sock": "host.token", "other": "other.token"} {
		if err := os.WriteFile(filepath.Join(dir, file), []byte(" tok-"+file+"\n"), 0600); err != nil {
			t.Fatal(err)
		}
		got, err := hostToken(filepath.Join(dir, socket))
		if err != nil || got != "tok-"+file {
			t.Fatalf("%s: token %q: %v", socket, got, err)
		}
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
