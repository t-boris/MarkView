package localserver

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPersistentPrivatePassword(t *testing.T) {
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	a, err := Password(dir)
	if err != nil {
		t.Fatal(err)
	}
	b, err := Password(dir)
	if err != nil || a != b {
		t.Fatalf("password changed: %v", err)
	}
	path := filepath.Join(dir, "database-secret")
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := Password(dir); err == nil {
		t.Fatal("public password accepted")
	}
}

func TestRejectsPublicOrRelativeDirectory(t *testing.T) {
	if PrivateDir("relative") == nil {
		t.Fatal("relative directory accepted")
	}
	dir := t.TempDir()
	if err := os.Chmod(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if PrivateDir(dir) == nil {
		t.Fatal("public directory accepted")
	}
}
