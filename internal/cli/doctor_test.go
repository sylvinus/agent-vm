package cli

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

func TestDoctor(t *testing.T) {
	se := newStartEnv(t)
	if code := se.run("doctor"); code != 1 || !strings.Contains(se.stdout.String(), "  FAIL  no base template yet") ||
		!strings.Contains(se.stdout.String(), "  ok    safe.bareRepository = explicit") || !strings.HasSuffix(se.stdout.String(), "warning(s).\n") {
		t.Errorf("no base:\n%s", se.out())
	}
	if se.run("doctor", "x") != 2 || !strings.Contains(se.out(), "Usage: agent-vm doctor") {
		t.Errorf("an argument: %s", se.out())
	}

	se.base()
	exec.Command("git", "-C", se.proj, "init", "-q").Run()
	exec.Command("git", "-C", se.proj, "config", "core.hooksPath", ".husky/_").Run()
	se.run("run", "true")
	out := func() string { se.run("doctor"); return se.stdout.String() }
	o := out()
	for _, want := range []string{
		"  ok    base is ready, built ",
		"  ok    " + vmname.Name(se.proj) + " exists",
		"  ok    running; the project share is enforced on the host (--readonly works)",
		"  ok    its shares keep every .git read-only",
		"  ok    git runs hooks from .husky/_ (core.hooksPath): every '.husky' in the project is read-only for the VM",
		"  ok    every .git is read-only for the VMs (sshfs.readonlyNames)",
		"1 running, ",
		" warning(s).\n",
	} {
		if !strings.Contains(o, want) {
			t.Errorf("missing %q in:\n%s", want, o)
		}
	}
	// The VM's shares without a name the project needs now.
	v := se.fake.VMs[vmname.Name(se.proj)]
	v.Mounts[0].SSHFS.ReadonlyNames = []string{".git", ".hg"}
	o = out()
	if !strings.Contains(o, "  warn  its shares keep .git read-only, but not all of .git, .hg, .husky") ||
		!strings.Contains(o, "  warn  git runs hooks from .husky/_ (core.hooksPath), which the VM can still write") {
		t.Errorf("older names:\n%s", o)
	}
	// An env others can read; a leftover scratch VM; a config risk.
	os.WriteFile(se.state.Path("env"), []byte("A=1\nB=2\nA=3\n"), 0o644)
	os.Chmod(se.state.Path("env"), 0o644)
	os.WriteFile(se.state.Marker(state.ScratchOf, "x-scratch-0000aaaa"), []byte("999999999\n"), 0o644)
	exec.Command("git", "-C", se.proj, "config", "core.fsmonitor", "./mon.sh").Run()
	o = out()
	// Permission bits mean little on Windows (see doctor.go): only the
	// count is said there.
	envReadable, envPrivate := "  warn  env is readable by other users on this machine (mode 644)", "  ok    env: 2 key(s), private to you (mode 600)"
	if runtime.GOOS == "windows" {
		envReadable, envPrivate = "  -     env: 2 key(s)", "  -     env: 2 key(s)"
	}
	for _, want := range []string{
		envReadable,
		"  warn  scratch VM x-scratch-0000aaaa was left by a run that did not finish",
		"        core.fsmonitor = ./mon.sh",
	} {
		if !strings.Contains(o, want) {
			t.Errorf("missing %q in:\n%s", want, o)
		}
	}
	os.Chmod(se.state.Path("env"), 0o600)
	if o = out(); !strings.Contains(o, envPrivate) {
		t.Errorf("env:\n%s", o)
	}
	// A mount type the host does not enforce; doctor changes nothing.
	v.MountType = "9p"
	se.fake.Calls = nil
	if o = out(); !strings.Contains(o, "  warn  running with a share the host does not confine: ") || !strings.Contains(o, `the mount type is "9p"`) {
		t.Errorf("9p:\n%s", o)
	}
	if strings.Contains(se.fake.CallLog(), "edit") || strings.Contains(se.fake.CallLog(), "start") || strings.Contains(se.fake.CallLog(), "stop") {
		t.Errorf("doctor changed the VM:\n%s", se.fake.CallLog())
	}
	// Lima's overrides, and a config Lima refuses. Host-spelled: doctor
	// spells its folders so.
	cfg := paths.Host(filepath.Join(LimaHome(se.state), "_config"))
	os.MkdirAll(cfg, 0o755)
	os.WriteFile(cfg+"/override.yaml", []byte("mounts: []\n"), 0o644)
	v.ConfigErr = errors.New("field `mounts[1].sshfs.sftpDriver` must be `builtin`")
	o = out()
	for _, want := range []string{
		"  FAIL  " + cfg + "/override.yaml adds to every VM's config",
		"  FAIL  Lima cannot read the config of " + vmname.Name(se.proj),
		"        field `mounts[1].sshfs.sftpDriver` must be `builtin`",
	} {
		if !strings.Contains(o, want) {
			t.Errorf("missing %q in:\n%s", want, o)
		}
	}
	v.ConfigErr = nil
	os.Remove(cfg + "/override.yaml")
	se.fake.Err = errors.New("broken")
	if o = out(); !strings.Contains(o, "  warn  could not query Lima") {
		t.Errorf("broken backend:\n%s", o)
	}
}
