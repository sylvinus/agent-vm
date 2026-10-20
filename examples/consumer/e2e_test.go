//go:build e2e

package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A real VM: go test -tags e2e. Downloads Debian's image, boots it (slow
// without hardware acceleration), installs git and curl in the base, then
// runs a command in a project's VM, shares the folder and nothing else, and
// removes the VM.
func TestSandbox(t *testing.T) {
	// A home of its own, where git is set as agent-vm asks: it would stop to
	// ask, on a program that asks nothing.
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	os.Unsetenv("GIT_CONFIG_GLOBAL")
	os.Unsetenv("XDG_CONFIG_HOME")
	os.WriteFile(filepath.Join(home, ".gitconfig"), []byte("[safe]\n\tbareRepository = explicit\n"), 0o644)
	t.Setenv("SANDBOX_STATE_DIR", t.TempDir())
	proj := t.TempDir()
	t.Chdir(proj)
	t.Setenv("PWD", proj)

	var stdout, stderr bytes.Buffer
	if code := run([]string{"setup"}, strings.NewReader(""), &stdout, &stderr); code != 0 {
		t.Fatalf("setup: %d\n%s", code, stderr.String())
	}
	stdout.Reset()
	stderr.Reset()

	os.WriteFile("from-host", []byte("host\n"), 0o644)
	script := `git --version >/dev/null && cat from-host && echo vm > from-vm`
	if code := run([]string{"run", "sh", "-c", script}, strings.NewReader(""), &stdout, &stderr); code != 0 || stdout.String() != "host\n" {
		t.Fatalf("run: %d %q\n%s", code, stdout.String(), stderr.String())
	}
	// The folder is shared both ways.
	if b, _ := os.ReadFile("from-vm"); string(b) != "vm\n" {
		t.Errorf("from-vm on the host: %q", b)
	}
	if code := run([]string{"rm"}, strings.NewReader(""), &stdout, &stderr); code != 0 {
		t.Errorf("rm: %d\n%s", code, stderr.String())
	}
}
