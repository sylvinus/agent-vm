package cli

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/vm"
)

// localGuest runs what the VM would, on this machine: the project is at its
// own path, as the share puts it, and the guest has its own home.
func localGuest(t *testing.T, se *startEnv) (home string, ran *[][]string) {
	t.Helper()
	for _, sh := range []string{"sh", "zsh", "awk"} {
		if _, err := exec.LookPath(sh); err != nil {
			t.Skip("no " + sh)
		}
	}
	home = t.TempDir()
	var calls [][]string
	se.fake.ShellFunc = func(name string, o vm.ShellOpts) int {
		calls = append(calls, append([]string{o.Workdir}, o.Args...))
		cmd := exec.Command(o.Args[0], o.Args[1:]...)
		cmd.Dir = o.Workdir
		if cmd.Dir == "" {
			cmd.Dir = home
		}
		cmd.Env = []string{"HOME=" + home, "PATH=" + os.Getenv("PATH"), "ZDOTDIR=" + home}
		cmd.Stdin, cmd.Stdout, cmd.Stderr = o.Stdin, o.Stdout, o.Stderr
		err := cmd.Run()
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return ee.ExitCode()
		}
		if err != nil {
			t.Fatal(err)
		}
		return 0
	}
	return home, &calls
}

// The probe, run as the VM runs it: the env pushed private, the project's
// own after the shared one, CRs dropped; nothing left in the project.
func TestGuestProbe(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	home, _ := localGuest(t, se)
	os.WriteFile(se.state.Path("env"), []byte("TOKEN='x'\n"), 0o600)
	os.WriteFile(filepath.Join(se.proj, ".agent-vm.env"), []byte("P=1\r\n"), 0o600)
	if code := se.run("run", "true"); code != 0 {
		t.Fatalf("run: %d %s", code, se.out())
	}
	fi, err := os.Stat(filepath.Join(home, ".agent-vm.env"))
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("guest env: %v %v", fi, err)
	}
	if b, _ := os.ReadFile(filepath.Join(home, ".agent-vm.env")); string(b) != "TOKEN='x'\nP=1\n" {
		t.Errorf("guest env: %q", b)
	}
	ents, _ := os.ReadDir(se.proj)
	for _, e := range ents {
		if strings.Contains(e.Name(), "probe") {
			t.Errorf("left in the project: %s", e.Name())
		}
	}
	// Removed on the host: emptied in the guest.
	os.Remove(se.state.Path("env"))
	os.Remove(filepath.Join(se.proj, ".agent-vm.env"))
	se.run("run", "true")
	if b, err := os.ReadFile(filepath.Join(home, ".agent-vm.env")); err != nil || len(b) != 0 {
		t.Errorf("guest env after removal: %q %v", b, err)
	}
}

// ~/.agent-vm/runtime.sh: piped whole into the VM, CRs dropped, under the
// shell its shebang names.
func TestGuestUserRuntime(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	localGuest(t, se)
	os.WriteFile(se.state.Path("runtime.sh"), []byte("#!/bin/bash -e\r\necho \"bash=${BASH_VERSION:+yes}\"\r\n"), 0o644)
	if code := se.run("run", "true"); code != 0 || !strings.Contains(se.out(), "Running user runtime setup...") || !strings.Contains(se.out(), "bash=yes\n") {
		t.Errorf("runtime.sh: %d %q", code, se.out())
	}
}

// `run`'s wrapper: a missing command is 127 and said so, a file without +x
// is env's 126, an assignment goes to the command.
func TestGuestRun(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	localGuest(t, se)
	if code := se.run("run", "no-such-command-x"); code != 127 || !strings.Contains(se.out(), "agent-vm: no-such-command-x is not installed in this VM.") {
		t.Errorf("missing: %d %s", code, se.out())
	}
	os.WriteFile(filepath.Join(se.proj, "s.sh"), []byte("#!/bin/sh\necho hi\n"), 0o644)
	if code := se.run("run", "./s.sh"); code != 126 {
		t.Errorf("no +x: %d %s", code, se.out())
	}
	if code := se.run("run", "V=x", "sh", "-c", "echo v=$V"); code != 0 || !strings.Contains(se.out(), "v=x") {
		t.Errorf("assignment: %d %s", code, se.out())
	}
}

// A project runtime script that is a link out of the project runs in the
// VM, by its path there: the host never reads it (the agent can retarget
// the link at any host file).
func TestGuestRuntimeLink(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	_, ran := localGuest(t, se)
	outside := filepath.Join(t.TempDir(), "rt.sh")
	os.WriteFile(outside, []byte("#!/bin/sh\necho from-runtime\n"), 0o644)
	os.Symlink(outside, filepath.Join(se.proj, ".agent-vm.runtime.sh"))
	if code := se.run("run", "true"); code != 0 || !strings.Contains(se.out(), "Running project runtime setup...") {
		t.Fatalf("run: %d %s", code, se.out())
	}
	inVM := false
	for _, c := range *ran {
		last := c[len(c)-1]
		if last == filepath.Join(se.proj, ".agent-vm.runtime.sh") && c[1] == "zsh" {
			inVM = true
		}
		if strings.Contains(strings.Join(c, " "), " -s") && strings.HasPrefix(c[len(c)-1], "exec ") {
			t.Errorf("piped from the host: %q", c)
		}
	}
	if !inVM || !strings.Contains(se.out(), "from-runtime") {
		t.Errorf("not run in the VM by its path: %q\n%s", *ran, se.out())
	}
}
