//go:build e2e

package cli

import (
	"bytes"
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lima-vm/lima/v2/pkg/instance"
)

// agent-vm as a user runs it, on real VMs: setup, then a command in a
// project, its .git read-only. go test -tags e2e -run TestE2E ./internal/cli/
// Slow without hardware acceleration: AGENT_VM_E2E_TIMEOUT (default 60m)
// for each boot, and go test's -timeout.
func TestE2E(t *testing.T) {
	timeout := 60 * time.Minute
	if v := os.Getenv("AGENT_VM_E2E_TIMEOUT"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			t.Fatal(err)
		}
		timeout = d
	}
	ctx := instance.WithWatchHostAgentTimeout(context.Background(), timeout)
	// Short: Lima's sockets live under it, at most 104 or 108 characters.
	// AGENT_VM_E2E_DIR: where, when /tmp cannot hold the VMs' disks.
	parent := os.Getenv("AGENT_VM_E2E_DIR")
	if parent == "" {
		parent = "/tmp"
	}
	home, err := os.MkdirTemp(parent, "avm")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(home) })
	t.Setenv("HOME", home)
	t.Setenv("AGENT_VM_STATE_DIR", filepath.Join(home, ".agent-vm"))
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	os.Unsetenv("GIT_CONFIG_GLOBAL")
	os.Unsetenv("XDG_CONFIG_HOME")
	os.WriteFile(filepath.Join(home, ".gitconfig"), []byte("[safe]\n\tbareRepository = explicit\n"), 0o644)
	skipPrereqs = true // for hosts without KVM: QEMU emulates

	run := func(dir string, args ...string) (int, string) {
		t.Helper()
		t.Chdir(dir)
		t.Setenv("PWD", dir)
		var out bytes.Buffer
		w := io.MultiWriter(&out, os.Stderr)
		e, err := newApp(IO{Stdin: strings.NewReader(""), Stdout: w, Stderr: w})
		if err != nil {
			t.Fatal(err)
		}
		return e.main(ctx, args), out.String()
	}

	start := time.Now()
	if code, out := run(home, "setup", "--preinstall=none"); code != 0 {
		t.Fatalf("setup: %d\n%s", code, out)
	}
	t.Logf("setup in %v", time.Since(start).Round(time.Second))
	t.Cleanup(func() { run(home, "destroy-all") })

	proj := filepath.Join(home, "proj")
	os.MkdirAll(proj, 0o755)
	if err := exec.Command("git", "-C", proj, "init", "-q").Run(); err != nil {
		t.Fatal(err)
	}
	cfg, _ := os.ReadFile(filepath.Join(proj, ".git", "config"))
	os.WriteFile(filepath.Join(home, ".agent-vm", "env"), []byte("SECRET='s3'\n"), 0o600)
	code, out := run(proj, "run", "sh", "-c",
		`echo hi > from-vm && printf 'a\n' >> from-vm && echo "secret=$SECRET" && (echo x >> .git/config && echo WROTE-GIT || echo REFUSED-GIT)`)
	if code != 0 {
		t.Fatalf("run: %d\n%s", code, out)
	}
	if !strings.Contains(out, "secret=s3") {
		t.Errorf("the env did not reach the command:\n%s", out)
	}
	if !strings.Contains(out, "REFUSED-GIT") {
		t.Errorf(".git was writable:\n%s", out)
	}
	if b, _ := os.ReadFile(filepath.Join(proj, ".git", "config")); !bytes.Equal(b, cfg) {
		t.Errorf(".git/config changed: %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(proj, "from-vm")); string(b) != "hi\na\n" {
		t.Errorf("on the host: %q", b)
	}
	if code, out := run(proj, "info"); code != 0 || !strings.Contains(out, "vm_running=1") || !strings.Contains(out, "git_protected=1") {
		t.Errorf("info: %s", out)
	}
	// sshfs's cache off: a change on the host shows at once.
	os.WriteFile(filepath.Join(proj, "f"), []byte("v1\n"), 0o644)
	if code, out := run(proj, "run", "cat", "f"); code != 0 || !strings.Contains(out, "v1") {
		t.Errorf("first read: %d %s", code, out)
	}
	os.WriteFile(filepath.Join(proj, "f"), []byte("v2, longer\n"), 0o644)
	if code, out := run(proj, "run", "cat", "f"); code != 0 || !strings.Contains(out, "v2, longer") {
		t.Errorf("read after a change on the host: %d %s", code, out)
	}
	// A share lost in the VM: found by the probe, and mounted again.
	if code, out := run(proj, "run", "sh", "-c", `cd / && sudo umount -l "$1"`, "sh", proj); code != 0 {
		t.Fatalf("umount: %d %s", code, out)
	}
	code, out = run(proj, "run", "cat", "f")
	if code != 0 || !strings.Contains(out, "the project share is not mounted") || !strings.Contains(out, "v2, longer") {
		t.Errorf("lost share: %d %s", code, out)
	}
	if code, out := run(proj, "stop"); code != 0 || !strings.Contains(out, "VM stopped.") {
		t.Errorf("stop: %s", out)
	}
}
