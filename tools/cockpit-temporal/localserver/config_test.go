package localserver

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/t-boris/MarkView/cockpit-temporal/localtls"
)

func TestPrivateConfigurationUsesDistinctPorts(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	cert, err := localtls.Generate(dir)
	if err != nil {
		t.Fatal(err)
	}
	ports, err := PickPorts()
	if err != nil {
		t.Fatal(err)
	}
	seen := map[int]bool{}
	for _, p := range []int{ports.Frontend, ports.FrontendMember, ports.FrontendHTTP, ports.History, ports.HistoryMember, ports.Matching, ports.MatchingMember, ports.Worker, ports.WorkerMember} {
		if p == 0 || p > 32767 || seen[p] {
			t.Fatalf("invalid port: %d", p)
		}
		seen[p] = true
	}
	_, err = MakeConfig(dir, "127.0.0.1:5555", "user", "secret", cert, ports)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "server-config.yaml")); !os.IsNotExist(err) {
		t.Fatal("transient server configuration remained on disk")
	}
}
