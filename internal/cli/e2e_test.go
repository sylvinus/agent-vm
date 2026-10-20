//go:build e2e

package cli

import (
	"bytes"
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/sylvinus/agent-vm/third_party/lima/pkg/instance"

	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vmname"
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
	// The run that started the VM is over and its context cancelled: the VM
	// runs on (Lima once killed its hostagent then).
	time.Sleep(2 * time.Second)
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
	// A named VM that shares nothing: the folder's path is made in it, empty,
	// and it is the VM's own, kept.
	code, out = run(proj, "--name", "sandbox", "--no-shares", "run", "sh", "-c", `pwd; test ! -e from-vm && echo EMPTY`)
	if code != 0 || !strings.Contains(out, proj+"\n") || !strings.Contains(out, "EMPTY") {
		t.Errorf("named VM, no shares: %d\n%s", code, out)
	}
	if code, out := run(proj, "stop", "sandbox"); code != 0 {
		t.Errorf("stop sandbox: %d\n%s", code, out)
	}
	// The hostagent killed under the VM: with QEMU, the VM runs on, cut off.
	// The next run stops it and starts it again; so does stop. With vz, the
	// VM goes with the hostagent.
	st := state.Dir(filepath.Join(home, ".agent-vm"))
	b, err := vm.NewLima(LimaHome(st), st.VMs(), string(st))
	if err != nil {
		t.Fatal(err)
	}
	name := vmname.Name(proj)
	orphan := func() (driver int) {
		t.Helper()
		inst, err := b.Get(ctx, name)
		if err != nil || inst.Status != vm.Running {
			t.Fatalf("before the kill: %+v %v", inst, err)
		}
		pid := func(f string) int {
			b, _ := os.ReadFile(filepath.Join(inst.Dir, f))
			n, _ := strconv.Atoi(strings.TrimSpace(string(b)))
			return n
		}
		driver = pid(inst.VMType + ".pid")
		if err := syscall.Kill(pid("ha.pid"), syscall.SIGKILL); err != nil {
			t.Fatal(err)
		}
		// Broken without more until the hostagent is reaped.
		for range 100 {
			if inst, err = b.Get(ctx, name); err == nil && (inst.Orphaned || inst.Status == vm.Stopped) {
				break
			}
			time.Sleep(100 * time.Millisecond)
		}
		if !inst.Orphaned {
			t.Logf("not orphaned by the kill: %s", inst.Status)
			return 0
		}
		return driver
	}
	orphaned := orphan() != 0
	if code, out := run(proj, "run", "true"); code != 0 || orphaned != strings.Contains(out, "left running without Lima's host agent") {
		t.Errorf("run on an orphaned VM: %d %s", code, out)
	}
	driver := orphan()
	if code, out := run(proj, "stop"); code != 0 || !strings.Contains(out, "VM stopped.") {
		t.Errorf("stop: %s", out)
	}
	// Killed, then reaped by init.
	for i := 0; driver != 0 && syscall.Kill(driver, 0) == nil; i++ {
		if i == 50 {
			t.Errorf("the orphaned driver %d still runs", driver)
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
}
