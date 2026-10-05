package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vm/vmtest"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

// guest answers like a VM: the probe by its shares (lost when the test says
// so), the rest by running nothing.
type guest struct {
	fake     *vmtest.Fake
	lost     bool
	payloads []string
	ran      [][]string
}

func (g *guest) shell(name string, o vm.ShellOpts) int {
	if len(o.Args) > 2 && o.Args[0] == "sh" && o.Args[2] == probeScript {
		b, _ := io.ReadAll(o.Stdin)
		g.payloads = append(g.payloads, string(b))
		fmt.Fprintln(o.Stdout, "env-ok")
		if o.Args[6] != "" && !g.lost {
			fmt.Fprintln(o.Stdout, "share-ok")
		}
		v := g.fake.VMs[name]
		if g.lost || v == nil || len(v.Mounts) == 0 && !strings.Contains(name, "scratch") || len(v.Mounts) > 0 && !v.Mounts[0].Writable {
			return 1
		}
		return 0
	}
	g.ran = append(g.ran, append([]string{o.Workdir}, o.Args...))
	return 0
}

type startEnv struct {
	*testEnv
	g          *guest
	home, proj string
}

func newStartEnv(t *testing.T, answers ...string) *startEnv {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	home, _ := filepath.EvalSymlinks(t.TempDir())
	// Host-spelled, as AbsDir spells the callers' folders: mixed
	// separators never compare on Windows.
	home = paths.Host(home)
	t.Setenv("HOME", home)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	os.Unsetenv("GIT_CONFIG_GLOBAL")
	os.Unsetenv("XDG_CONFIG_HOME")
	t.Setenv("AGENT_VM_UNSAFE_WRITABLE_GIT", "")
	t.Setenv("AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS", "")
	t.Setenv("AGENT_VM_SSHFS_CACHE", "")
	t.Setenv("TERM", "")
	os.WriteFile(filepath.Join(home, ".gitconfig"), []byte("[safe]\n\tbareRepository = explicit\n"), 0o644)
	proj := home + "/proj"
	os.MkdirAll(proj, 0o755)
	t.Chdir(proj)
	t.Setenv("PWD", proj)
	fake := vmtest.New()
	g := &guest{fake: fake}
	fake.ShellFunc = g.shell
	te := newTestEnv(t, fake, answers...)
	te.state = state.Dir(home + "/.agent-vm")
	os.MkdirAll(string(te.state), 0o755)
	return &startEnv{testEnv: te, g: g, home: home, proj: proj}
}

func (se *startEnv) base() {
	se.fake.VMs[vmname.Template] = &vm.Instance{Name: vmname.Template, Status: vm.Stopped, CPUs: 1, Memory: 3 << 30, Disk: 10 << 30}
	os.WriteFile(se.state.Path(state.BaseVersion), []byte("1759000000\n"), 0o644)
	os.WriteFile(se.state.Path(state.BaseBuiltBy), []byte("0.3.0\n"), 0o644)
}

func TestStartNoBase(t *testing.T) {
	se := newStartEnv(t)
	if se.run("run", "true") != 1 || !strings.Contains(se.out(), "Error: Base VM not found. Run 'agent-vm setup' first.") {
		t.Errorf("no base: %s", se.out())
	}
	se.fake.VMs[vmname.Template] = &vm.Instance{Name: vmname.Template, Status: vm.Stopped}
	if se.run("run", "true") != 1 || !strings.Contains(se.out(), "Base VM setup did not complete") {
		t.Errorf("base without its marker: %s", se.out())
	}
}

func TestStartNewVM(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	os.WriteFile(se.state.Path("env"), []byte("TOKEN='x'\r\n"), 0o600)
	name := vmname.Name(se.proj)
	if code := se.run("run", "echo", "hi"); code != 0 {
		t.Fatalf("run: %d %s", code, se.out())
	}
	if !strings.HasPrefix(se.fake.CallLog(), "clone base "+name+"\nedit "+name+"\nedit "+name+"\nstart "+name) {
		t.Errorf("calls:\n%s", se.fake.CallLog())
	}
	v := se.fake.VMs[name]
	if v.Status != vm.Running || v.MountType != vm.ReverseSSHFS || len(v.Mounts) != 1 || !v.Mounts[0].Writable ||
		v.Mounts[0].SSHFS == nil || strings.Join(v.Mounts[0].SSHFS.ReadonlyNames, ",") != ".git,.hg" || v.Mounts[0].SSHFS.Cache == nil || *v.Mounts[0].SSHFS.Cache {
		t.Errorf("VM: %+v %+v", v, v.Mounts)
	}
	if len(se.g.payloads) != 1 || se.g.payloads[0] != "TOKEN='x'\n" {
		t.Errorf("payload: %q", se.g.payloads)
	}
	last := se.g.ran[len(se.g.ran)-1]
	if last[0] != paths.Guest(se.proj) || last[1] != "zsh" || last[len(last)-2] != "echo" || last[len(last)-1] != "hi" {
		t.Errorf("command: %q", last)
	}
	for _, m := range []string{state.VersionOf, state.BuiltByOf} {
		if _, err := os.Stat(se.state.Marker(m, name)); err != nil {
			t.Errorf("marker %s not recorded", m)
		}
	}
	// Again: nothing to change, nothing restarted.
	se.run("run", "true")
	if strings.Contains(se.fake.CallLog(), "edit") || strings.Contains(se.fake.CallLog(), "start") || strings.Contains(se.fake.CallLog(), "stop") {
		t.Errorf("second run changed the VM:\n%s", se.fake.CallLog())
	}
	// --rm: deleted after.
	if se.run("--rm", "run", "true") != 0 || se.fake.VMs[name] != nil || !strings.Contains(se.out(), "VM destroyed.") {
		t.Errorf("--rm: %s", se.out())
	}
}

// The resources asked against the VM's: in bytes, the disk one way (it
// only grows), a VM that cannot be read counts as a change.
func TestResourcesDiffer(t *testing.T) {
	inst := &vm.Instance{CPUs: 2, Memory: 4 << 30, Disk: 20 << 30}
	for _, c := range []struct {
		o    VMOpts
		want bool
	}{
		{VMOpts{}, false},
		{VMOpts{CPUs: 2, Memory: 4, Disk: 20}, false},
		{VMOpts{CPUs: 3}, true},
		{VMOpts{Memory: 5}, true},
		{VMOpts{Disk: 10}, false},
		{VMOpts{Disk: 30}, true},
	} {
		s := &start{opts: c.o}
		if got := s.resourcesDiffer(inst); got != c.want {
			t.Errorf("%+v: %v", c.o, got)
		}
	}
	if !(&start{opts: VMOpts{CPUs: 2}}).resourcesDiffer(nil) {
		t.Error("an unknown VM is no change")
	}
	// Half a GiB more than asked: a change.
	if !(&start{opts: VMOpts{Memory: 4}}).resourcesDiffer(&vm.Instance{Memory: 4<<30 + 1<<29}) {
		t.Error("compared in whole GiB")
	}
}

// A folder left without lima.yaml by an interrupted creation is cleaned up.
func TestStartPartialVM(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	d := filepath.Join(LimaHome(se.state), vmname.Name(se.proj))
	os.MkdirAll(d, 0o755)
	os.WriteFile(filepath.Join(d, "basedisk"), nil, 0o644)
	if se.run("run", "true") != 0 || !strings.Contains(se.out(), "Detected partial VM state at "+d) {
		t.Errorf("partial: %s", se.out())
	}
	if _, err := os.Stat(filepath.Join(d, "basedisk")); err == nil {
		t.Error("left")
	}
}

// --ssh-port: set before the first start, not set again when unchanged, 0
// back to Lima's choice; a port another VM has is refused.
func TestStartSSHPort(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	name := vmname.Name(se.proj)
	se.fake.VMs["other-00000000"] = &vm.Instance{Name: "other-00000000", Status: vm.Stopped, SSHPortConfig: 2222}
	if se.run("--ssh-port", "2222", "run", "true") != 1 || !strings.Contains(se.out(), "SSH port 2222 is already set for VM 'other-00000000'") || se.fake.CallLog() != "" {
		t.Errorf("taken: %s\n%s", se.out(), se.fake.CallLog())
	}
	if se.run("--ssh-port", "2223", "run", "true") != 0 || se.fake.VMs[name].SSHPortConfig != 2223 ||
		strings.Index(se.fake.CallLog(), "start ") < strings.LastIndex(se.fake.CallLog(), "edit ") {
		t.Errorf("new VM: %s\n%s", se.out(), se.fake.CallLog())
	}
	se.fake.VMs[name].Status = vm.Stopped
	if se.run("--ssh-port", "2223", "run", "true") != 0 || strings.Contains(se.fake.CallLog(), "edit") {
		t.Errorf("unchanged: %s\n%s", se.out(), se.fake.CallLog())
	}
	se.fake.VMs[name].Status = vm.Stopped
	if se.run("--ssh-port", "0", "run", "true") != 0 || se.fake.VMs[name].SSHPortConfig != 0 {
		t.Errorf("0: %s\n%s", se.out(), se.fake.CallLog())
	}
}

// A new VM that cannot be configured is deleted, never started, nothing
// recorded; --reset that cannot delete changes nothing.
func TestStartFailures(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	name := vmname.Name(se.proj)
	for _, op := range []string{"clone", "edit"} {
		se.fake.FailOn = map[string]error{op: errors.New("no")}
		if se.run("run", "true") != 1 || strings.Contains(se.fake.CallLog(), "start") || se.fake.VMs[name] != nil {
			t.Errorf("%s fails: %s\n%s", op, se.out(), se.fake.CallLog())
		}
		if _, err := os.Stat(se.state.Marker(state.VersionOf, name)); err == nil {
			t.Errorf("%s fails: recorded", op)
		}
	}
	se.fake.FailOn = nil
	if se.run("run", "true") != 0 {
		t.Fatalf("run: %s", se.out())
	}
	se.fake.FailOn = map[string]error{"delete": errors.New("no")}
	se.fake.Sticky[name] = true
	if se.run("--reset", "run", "true") != 1 || strings.Contains(se.fake.CallLog(), "clone") {
		t.Errorf("--reset, delete fails: %s\n%s", se.out(), se.fake.CallLog())
	}
	se.fake.FailOn, se.fake.Sticky = nil, map[string]bool{}
	if se.run("--reset", "run", "true") != 0 || !strings.Contains(se.out(), "Resetting VM") || !strings.Contains(se.fake.CallLog(), "delete "+name+"\nclone ") {
		t.Errorf("--reset: %s\n%s", se.out(), se.fake.CallLog())
	}
}

// A VM from a 0.1.0 base (no record of what built it): told how to replace
// it, not started; --reset does.
func TestStartFrom01(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	name := vmname.Name(se.proj)
	se.fake.VMs[name] = &vm.Instance{Name: name, Status: vm.Stopped}
	if se.run("run", "true") != 1 || !strings.Contains(se.out(), "comes from a base built by agent-vm 0.1.0") || se.fake.CallLog() != "" {
		t.Errorf("0.1.0: %s\n%s", se.out(), se.fake.CallLog())
	}
	if se.run("--reset", "run", "true") != 0 {
		t.Errorf("--reset: %s", se.out())
	}
}

func TestStartRefusesHome(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	// Go reads the home from USERPROFILE on Windows, not HOME.
	t.Setenv("USERPROFILE", se.home)
	t.Chdir(se.home)
	t.Setenv("PWD", se.home)
	if se.run("shell") != 1 || !strings.Contains(se.out(), "refusing to share "+se.home+" with a VM: it is, or contains, your home directory") {
		t.Errorf("home: %s", se.out())
	}
	if strings.Contains(se.fake.CallLog(), "clone") {
		t.Error("cloned anyway")
	}
	// The user's own Lima home: its _config/user key logs into their VMs.
	key := filepath.Join(se.home, ".lima", "_config")
	os.MkdirAll(key, 0o755)
	t.Chdir(key)
	t.Setenv("PWD", key)
	if se.run("shell") != 1 || !strings.Contains(se.out(), "is inside Lima's state") {
		t.Errorf("~/.lima: %s", se.out())
	}
}

func TestStartReadonly(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	if se.run("--readonly", "run", "true") != 0 || !strings.Contains(se.out(), "Read-only: the project and every other share (enforced on the host).") {
		t.Fatalf("--readonly: %s", se.out())
	}
	name := vmname.Name(se.proj)
	if v := se.fake.VMs[name]; v.Mounts[0].Writable {
		t.Error("writable under --readonly")
	}
	// An rw volume too: read-only, said so. Host-spelled: entries spell
	// their sources so.
	vol := paths.Host(filepath.Join(t.TempDir(), "vol"))
	os.MkdirAll(vol, 0o755)
	os.WriteFile(se.state.Path("volumes"), []byte(vol+":/mnt/vol:rw\n"), 0o644)
	se.fake.VMs[name].Status = vm.Stopped
	if se.run("--readonly", "run", "true") != 0 || !strings.Contains(se.out(), "Note: --readonly: '"+vol+"' (rw in ~/.agent-vm/volumes) is mounted read-only too.") {
		t.Fatalf("--readonly with an rw volume: %s", se.out())
	}
	for _, m := range se.fake.VMs[name].Mounts {
		if m.Writable {
			t.Errorf("writable under --readonly: %+v", m)
		}
	}
	os.Remove(se.state.Path("volumes"))
	se.fake.VMs[name].Status = vm.Stopped
	se.run("--readonly", "run", "true")
	// Back to writable: the running read-only VM is asked before a restart;
	// no terminal, refused.
	if se.run("run", "true") != 1 || !strings.Contains(se.out(), "not restarted") {
		t.Errorf("writable again, no terminal: %s", se.out())
	}
	se2 := &startEnv{testEnv: newTestEnv(t, se.fake, "y\n"), g: se.g, home: se.home, proj: se.proj}
	se2.state = se.state
	if se2.run("run", "true") != 0 || !se.fake.VMs[name].Mounts[0].Writable {
		t.Errorf("writable again, yes: %s\n%s", se2.out(), se.fake.CallLog())
	}
}

// beforeBoot holds every check that applies: --readonly with .git
// protected refuses a protected share left writable.
func TestBeforeBootAll(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	if se.run("run", "true") != 0 {
		t.Fatal(se.out())
	}
	name := vmname.Name(se.proj)
	se.fake.VMs[name].Status = vm.Stopped
	s := &start{app: se.app, ctx: context.Background(), name: name, opts: VMOpts{ReadOnly: true}, protect: true, names: []string{".git", ".hg"}}
	if s.beforeBoot() == nil || !strings.Contains(se.stderr.String(), "a writable share of "+se.proj) {
		t.Errorf("--readonly, protected, writable: %s", se.out())
	}
	s.opts.ReadOnly = false
	if s.beforeBoot() != nil {
		t.Errorf("writable asked: %s", se.out())
	}
}

// The verdicts on a VM's shares: confined first, then the names or the
// read-only mode.
func TestShareVerdicts(t *testing.T) {
	b := func(names ...string) *vm.SSHFS { return &vm.SSHFS{SFTPDriver: "builtin", ReadonlyNames: names} }
	inst := func(mt string, ms ...vm.Mount) *vm.Instance { return &vm.Instance{MountType: mt, Mounts: ms} }
	rs := vm.ReverseSSHFS
	for _, c := range []struct {
		inst          *vm.Instance
		names         []string
		unprot, notRO string
	}{
		{inst(rs, vm.Mount{Location: "/p", SSHFS: b(".git", ".hg")}), []string{".git"}, "", ""},
		{inst(rs, vm.Mount{Location: "/p", SSHFS: b(".git", ".hg", "tools")}), []string{".git", ".hg"}, "", ""},
		{inst(rs, vm.Mount{Location: "/p", SSHFS: b(".git")}), []string{".git", "tools"}, "lacks the read-only names", ""},
		{inst(rs, vm.Mount{Location: "/p", SSHFS: b()}), nil, "lacks the read-only names", ""},
		{inst(rs, vm.Mount{Location: "/p", Writable: true, SSHFS: b(".git", ".hg")}), nil, "", "a writable share of /p"},
		{inst(rs, vm.Mount{Location: "/p", SSHFS: b("tools")}), nil, "lacks the read-only names", ""},
		{inst(rs, vm.Mount{Location: "/p", SSHFS: &vm.SSHFS{ReadonlyNames: []string{".git"}}}), nil, "not served by the builtin SFTP server", "not served by the builtin SFTP server"},
		{inst("9p", vm.Mount{Location: "/p", SSHFS: b(".git")}), nil, "the mount type", "the mount type"},
	} {
		if got := unprotected(c.inst, c.names); c.unprot == "" && got != "" || !strings.Contains(got, c.unprot) {
			t.Errorf("unprotected %+v %v: %q", c.inst.Mounts, c.names, got)
		}
		if got := notReadOnly(c.inst); c.notRO == "" && got != "" || !strings.Contains(got, c.notRO) {
			t.Errorf("notReadOnly %+v: %q", c.inst.Mounts, got)
		}
	}
}

// Lima's own config: its override files refuse everything; a VM config it
// cannot read is said, nothing touched.
func TestStartLimaConfig(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	name := vmname.Name(se.proj)
	if se.run("run", "true") != 0 {
		t.Fatalf("first run: %s", se.out())
	}
	cfg := paths.Host(filepath.Join(se.home, ".agent-vm", "lima", "_config"))
	os.MkdirAll(cfg, 0o755)
	os.WriteFile(cfg+"/default.yaml", []byte("cpus: 8\n"), 0o644)
	se.fake.Calls = nil
	if se.run("run", "true") != 1 || !strings.Contains(se.out(), cfg+"/default.yaml adds to every VM's config") || se.fake.CallLog() != "" {
		t.Errorf("default.yaml: %s\n%s", se.out(), se.fake.CallLog())
	}
	os.Remove(cfg + "/default.yaml")
	se.fake.VMs[name].Status, se.fake.VMs[name].ConfigErr = vm.Broken, errors.New("field `mounts[1].sshfs.sftpDriver` must be `builtin`")
	if se.run("run", "true") != 1 || !strings.Contains(se.out(), "Lima cannot read the config of VM '"+name+"':\n  field `mounts[1]") {
		t.Errorf("unreadable: %s", se.out())
	}
	if strings.Contains(se.fake.CallLog(), "start") || strings.Contains(se.fake.CallLog(), "edit") {
		t.Errorf("touched:\n%s", se.fake.CallLog())
	}
}

// More of the hooks and config questions at start.
func TestStartHooksCases(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	name := vmname.Name(se.proj)
	git := func(args ...string) { exec.Command("git", append([]string{"-C", se.proj}, args...)...).Run() }
	git("init", "-q")
	names := func() string { return strings.Join(se.fake.VMs[name].Mounts[0].SSHFS.ReadonlyNames, ",") }

	// A plain name, no terminal: protected (yes by default), started.
	git("config", "core.hooksPath", "tools/hooks")
	if se.run("run", "true") != 0 || names() != ".git,.hg,tools" {
		t.Errorf("plain name, no terminal: %s", se.out())
	}
	// A name the shares cannot carry: aborted without a terminal, nothing
	// touched; running, only warned.
	git("config", "core.hooksPath", `a"b/x`)
	se.fake.VMs[name].Status = vm.Stopped
	if se.run("run", "true") != 1 || !strings.Contains(se.out(), "Aborted.") || se.fake.CallLog() != "" {
		t.Errorf("bad name: %s\n%s", se.out(), se.fake.CallLog())
	}
	se.fake.VMs[name].Status = vm.Running
	if se.run("run", "true") != 0 || !strings.Contains(se.out(), "Warning: git's core.hooksPath is") || strings.Contains(se.fake.CallLog(), "stop") {
		t.Errorf("bad name, running: %s\n%s", se.out(), se.fake.CallLog())
	}
	// --readonly: nothing asked, the hooks names still given.
	git("config", "core.hooksPath", "tools/hooks")
	git("config", "core.fsmonitor", "./mon.sh")
	se.fake.VMs[name].Status = vm.Stopped
	if se.run("--readonly", "run", "true") != 0 || strings.Contains(se.out(), "Warning: git on this machine uses these") || names() != ".git,.hg,tools" {
		t.Errorf("--readonly: %s %s", se.out(), names())
	}
	// A config risk alone: aborted without a terminal, nothing touched.
	git("config", "--unset", "core.hooksPath")
	se.fake.VMs[name].Status = vm.Stopped
	if se.run("run", "true") != 1 || !strings.Contains(se.out(), "core.fsmonitor = ./mon.sh") || se.fake.CallLog() != "" {
		t.Errorf("config risk: %s\n%s", se.out(), se.fake.CallLog())
	}
	git("config", "--unset", "core.fsmonitor")
	// sshfs's cache: on with AGENT_VM_SSHFS_CACHE=1, off again without; a
	// running VM differing only by it is left alone.
	cache := func() bool { c := se.fake.VMs[name].Mounts[0].SSHFS.Cache; return c == nil || *c }
	t.Setenv("AGENT_VM_SSHFS_CACHE", "1")
	se.fake.VMs[name].Status = vm.Stopped
	if se.run("run", "true") != 0 || !cache() {
		t.Errorf("cache on: %s", se.out())
	}
	t.Setenv("AGENT_VM_SSHFS_CACHE", "")
	if se.run("run", "true") != 0 || strings.Contains(se.fake.CallLog(), "stop") || strings.Contains(se.out(), "Warning") {
		t.Errorf("running, cache differs: %s\n%s", se.out(), se.fake.CallLog())
	}
	se.fake.VMs[name].Status = vm.Stopped
	if se.run("run", "true") != 0 || cache() {
		t.Errorf("cache off: %s", se.out())
	}
}

// Hooks in a writable volume inside the project: no name covers them, so a
// risk to accept, not a name.
func TestStartHooksInVolume(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	exec.Command("git", "-C", se.proj, "init", "-q").Run()
	exec.Command("git", "-C", se.proj, "config", "core.hooksPath", ".husky/_").Run()
	os.MkdirAll(filepath.Join(se.proj, ".husky", "_"), 0o755)
	os.WriteFile(se.state.Path("volumes"), []byte(filepath.Join(se.proj, ".husky")+":/mnt/husky:rw\n"), 0o644)
	if se.run("run", "true") != 1 || !strings.Contains(se.out(), "core.hooksPath is '.husky/_', which the VM can write, and no read-only name covers it") ||
		!strings.Contains(se.out(), "Aborted.") {
		t.Errorf("hooks in a volume: %s", se.out())
	}
}

func TestStartHooksQuestions(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	exec.Command("git", "-C", se.proj, "init", "-q").Run()
	exec.Command("git", "-C", se.proj, "config", "core.hooksPath", ".").Run()
	if se.run("run", "true") != 1 || !strings.Contains(se.out(), "core.hooksPath is the project directory itself") || !strings.Contains(se.out(), "Aborted.") {
		t.Errorf("hooks '.': %s", se.out())
	}
	if se.fake.CallLog() != "" {
		t.Errorf("touched before the abort: %s", se.fake.CallLog())
	}
	if se.run("--unsafe-disable-security-prompts", "run", "true") != 0 || !strings.Contains(se.out(), "Continuing: --unsafe-disable-security-prompts.") {
		t.Errorf("prompts off: %s", se.out())
	}
	// A plain name, asked; a yes protects it.
	exec.Command("git", "-C", se.proj, "config", "core.hooksPath", "tools/hooks").Run()
	se.fake.VMs[vmname.Name(se.proj)].Status = vm.Stopped
	se3 := &startEnv{testEnv: newTestEnv(t, se.fake, "y\n"), g: se.g, home: se.home, proj: se.proj}
	se3.state = se.state
	if se3.run("run", "true") != 0 || strings.Join(se.fake.VMs[vmname.Name(se.proj)].Mounts[0].SSHFS.ReadonlyNames, ",") != ".git,.hg,tools" {
		t.Errorf("tools: %s %+v", se3.out(), se.fake.VMs[vmname.Name(se.proj)].Mounts)
	}
	if !strings.Contains(se3.out(), "Making .git, .hg, tools read-only for VM") || !strings.Contains(se3.out(), "every 'tools' in the project is read-only") {
		t.Errorf("not said: %s", se3.out())
	}
	// Declined: what is under tools is a risk again, said with the hooks.
	exec.Command("git", "-C", se.proj, "config", "core.fsmonitor", "tools/fsmon.sh").Run()
	se.fake.VMs[vmname.Name(se.proj)].Status = vm.Stopped
	se4 := &startEnv{testEnv: newTestEnv(t, se.fake, "n\n", "y\n", "n\n"), g: se.g, home: se.home, proj: se.proj}
	se4.state = se.state
	if se4.run("run", "true") != 1 || !strings.Contains(se4.out(), "'tools' stays writable") || !strings.Contains(se4.out(), "core.fsmonitor = tools/fsmon.sh") {
		t.Errorf("declined: %s", se4.out())
	}
}

func TestStartBareRepo(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	os.WriteFile(filepath.Join(se.home, ".gitconfig"), nil, 0o644)
	if se.run("run", "true") != 1 || !strings.Contains(se.out(), "Git: repositories not named .git") || !strings.Contains(se.out(), "Aborted. Run the command above") {
		t.Errorf("bare repo, no terminal: %s", se.out())
	}
	se2 := &startEnv{testEnv: newTestEnv(t, se.fake, "y\n"), g: se.g, home: se.home, proj: se.proj}
	se2.state = se.state
	if se2.run("run", "true") != 0 || !strings.Contains(se2.out(), "now ignores repositories not named .git") {
		t.Errorf("bare repo, yes: %s", se2.out())
	}
	if b, _ := os.ReadFile(filepath.Join(se.home, ".gitconfig")); !strings.Contains(string(b), "bareRepository = explicit") {
		t.Errorf("global config: %q", b)
	}
	name := vmname.Name(se.proj)
	unset := func() {
		os.WriteFile(filepath.Join(se.home, ".gitconfig"), nil, 0o644)
		se.fake.VMs[name].Status = vm.Stopped
	}
	asked := func(answers ...string) *startEnv {
		s := &startEnv{testEnv: newTestEnv(t, se.fake, answers...), g: se.g, home: se.home, proj: se.proj}
		s.state = se.state
		return s
	}
	// No, then no: aborted, nothing set.
	unset()
	if s := asked("n\n", "n\n"); s.run("run", "true") != 1 || !strings.Contains(s.out(), "Warning: not set.") || !strings.Contains(s.out(), "Aborted. Run the command above") {
		t.Errorf("no, no: %s", s.out())
	}
	// No, then go on anyway.
	if s := asked("n\n", "y\n"); s.run("run", "true") != 0 || !strings.Contains(s.out(), "Warning: not set.") {
		t.Errorf("no, yes: %s", s.out())
	}
	if b, _ := os.ReadFile(filepath.Join(se.home, ".gitconfig")); len(b) != 0 {
		t.Errorf("set although declined: %q", b)
	}
	// Questions off: nothing set, said so.
	unset()
	if se.run("--unsafe-disable-security-prompts", "run", "true") != 0 || !strings.Contains(se.out(), "Continuing") {
		t.Errorf("prompts off: %s", se.out())
	}
	if b, _ := os.ReadFile(filepath.Join(se.home, ".gitconfig")); len(b) != 0 {
		t.Errorf("set with prompts off: %q", b)
	}
	// Running: a warning, no question.
	se.fake.VMs[name].Status = vm.Running
	if se.run("run", "true") != 0 || !strings.Contains(se.out(), "Warning: git on this machine uses repositories a VM creates") {
		t.Errorf("running: %s", se.out())
	}
	// --readonly: the VM writes nothing, nothing asked.
	unset()
	if se.run("--readonly", "run", "true") != 0 || strings.Contains(se.out(), "repositories not named .git") {
		t.Errorf("--readonly: %s", se.out())
	}
	// A yes that git cannot apply: said so, then asked to go on.
	unset()
	os.Remove(filepath.Join(se.home, ".gitconfig"))
	os.MkdirAll(filepath.Join(se.home, ".gitconfig"), 0o755)
	if s := asked("y\n", "n\n"); s.run("run", "true") != 1 || !strings.Contains(s.out(), "Warning: the setting did not take.") {
		t.Errorf("did not take: %s", s.out())
	}
}

func TestStartRepairsLostShare(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	se.run("run", "true")
	se.g.lost = true
	code := se.run("run", "true")
	if code != 1 || !strings.Contains(se.out(), "the project share is not mounted") || !strings.Contains(se.out(), "did not mount") {
		t.Errorf("lost, stays lost: %d %s", code, se.out())
	}
	if !strings.Contains(se.fake.CallLog(), "stop "+vmname.Name(se.proj)) {
		t.Errorf("not restarted: %s", se.fake.CallLog())
	}
}

func TestStartOlderNames(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	se.run("run", "true")
	exec.Command("git", "-C", se.proj, "init", "-q").Run()
	exec.Command("git", "-C", se.proj, "config", "core.hooksPath", ".husky/_").Run()
	// Running, no terminal: a risk to accept, refused by default.
	if se.run("run", "true") != 1 || !strings.Contains(se.out(), "runs with an older list of read-only names (it needs .git, .hg, .husky)") {
		t.Errorf("older names: %s", se.out())
	}
	se2 := &startEnv{testEnv: newTestEnv(t, se.fake, "y\n"), g: se.g, home: se.home, proj: se.proj}
	se2.state = se.state
	if se2.run("run", "true") != 0 || strings.Join(se.fake.VMs[vmname.Name(se.proj)].Mounts[0].SSHFS.ReadonlyNames, ",") != ".git,.hg,.husky" {
		t.Errorf("restarted: %s %s", se2.out(), se.fake.CallLog())
	}
}

// A VM whose shares leave .git writable: protected before it boots when
// stopped; when running, a restart offered (stop, edit, start, in that
// order), refused without a terminal.
func TestStartGitStale(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	name := vmname.Name(se.proj)
	se.run("run", "true")
	unprotect := func() {
		for i := range se.fake.VMs[name].Mounts {
			se.fake.VMs[name].Mounts[i].SSHFS.ReadonlyNames = nil
		}
	}
	unprotect()
	if se.run("run", "true") != 1 || !strings.Contains(se.out(), "is running with .git writable") || !strings.Contains(se.out(), "Aborted. 'agent-vm stop'") ||
		strings.Contains(se.fake.CallLog(), "stop") {
		t.Errorf("running, no terminal: %s\n%s", se.out(), se.fake.CallLog())
	}
	if se.run("--unsafe-disable-security-prompts", "run", "true") != 0 || !strings.Contains(se.out(), "Continuing") || strings.Contains(se.fake.CallLog(), "stop") {
		t.Errorf("running, prompts off: %s\n%s", se.out(), se.fake.CallLog())
	}
	se2 := &startEnv{testEnv: newTestEnv(t, se.fake, "y\n"), g: se.g, home: se.home, proj: se.proj}
	se2.state = se.state
	if se2.run("run", "true") != 0 || !strings.HasPrefix(se.fake.CallLog(), "stop "+name+"\nedit "+name+"\nstart "+name) {
		t.Errorf("running, restarted: %s\n%s", se2.out(), se.fake.CallLog())
	}
	// Stopped: protected before its one start.
	unprotect()
	se.fake.VMs[name].Status = vm.Stopped
	if se.run("run", "true") != 0 || !strings.Contains(se.out(), "Making every .git read-only for VM") ||
		!strings.HasPrefix(se.fake.CallLog(), "edit "+name+"\nstart "+name) || strings.Count(se.fake.CallLog(), "start ") != 1 {
		t.Errorf("stopped: %s\n%s", se.out(), se.fake.CallLog())
	}
}

// Left writable on purpose: a warning on every start, the shares still the
// confined server's, without the names. Only "1" counts.
func TestStartWritableGit(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	name := vmname.Name(se.proj)
	se.run("run", "true")
	// Running and protected: kept so until it stops.
	if se.run("--unsafe-writable-git", "run", "true") != 0 || !strings.Contains(se.out(), "WARNING: --unsafe-writable-git") ||
		!strings.Contains(se.out(), "keeps .git read-only until it stops") || strings.Contains(se.fake.CallLog(), "stop") {
		t.Errorf("running: %s\n%s", se.out(), se.fake.CallLog())
	}
	se.fake.VMs[name].Status = vm.Stopped
	t.Setenv("AGENT_VM_UNSAFE_WRITABLE_GIT", "1")
	if se.run("run", "true") != 0 || !strings.Contains(se.out(), "WARNING: AGENT_VM_UNSAFE_WRITABLE_GIT=1") || !strings.Contains(se.out(), "Making .git writable for VM") {
		t.Errorf("stopped: %s", se.out())
	}
	m := se.fake.VMs[name].Mounts[0]
	if se.fake.VMs[name].MountType != vm.ReverseSSHFS || m.SSHFS == nil || m.SSHFS.SFTPDriver != "builtin" || len(m.SSHFS.ReadonlyNames) != 0 {
		t.Errorf("shares: %+v %+v", se.fake.VMs[name], m.SSHFS)
	}
	// Anything but 1: protected again (stopped, so no question).
	t.Setenv("AGENT_VM_UNSAFE_WRITABLE_GIT", "yes")
	se.fake.VMs[name].Status = vm.Stopped
	if se.run("run", "true") != 0 || strings.Contains(se.out(), "WARNING") || len(se.fake.VMs[name].Mounts[0].SSHFS.ReadonlyNames) == 0 {
		t.Errorf("yes: %s", se.out())
	}
	t.Setenv("AGENT_VM_UNSAFE_WRITABLE_GIT", "")
	// The prompts switch, likewise: "yes" still asks (no terminal: no).
	exec.Command("git", "-C", se.proj, "init", "-q").Run()
	exec.Command("git", "-C", se.proj, "config", "core.hooksPath", ".").Run()
	se.fake.VMs[name].Status = vm.Stopped
	t.Setenv("AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS", "yes")
	if se.run("run", "true") != 1 || !strings.Contains(se.out(), "Aborted.") {
		t.Errorf("prompts yes: %s", se.out())
	}
	t.Setenv("AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS", "1")
	if se.run("run", "true") != 0 {
		t.Errorf("prompts 1: %s", se.out())
	}
}

// --readonly on a stopped writable VM: its shares read-only before its one
// start; back to writable the same way, said so.
func TestStartReadonlyStopped(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	name := vmname.Name(se.proj)
	se.run("run", "true")
	se.fake.VMs[name].Status = vm.Stopped
	if se.run("--readonly", "run", "true") != 0 || !strings.HasPrefix(se.fake.CallLog(), "edit "+name+"\nstart "+name) ||
		strings.Count(se.fake.CallLog(), "start ") != 1 || strings.Contains(se.fake.CallLog(), "stop") || !strings.Contains(se.out(), "Making every share of VM") {
		t.Errorf("--readonly: %s\n%s", se.out(), se.fake.CallLog())
	}
	se.fake.VMs[name].Status = vm.Stopped
	if se.run("run", "true") != 0 || !strings.HasPrefix(se.fake.CallLog(), "edit "+name+"\nstart "+name) ||
		!strings.Contains(se.out(), "was left read-only by --readonly; making it writable again") || !se.fake.VMs[name].Mounts[0].Writable {
		t.Errorf("writable again: %s\n%s", se.out(), se.fake.CallLog())
	}
}

func TestStartScratch(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	os.WriteFile(filepath.Join(se.proj, ".agent-vm.env"), []byte("P=1\n"), 0o600)
	os.WriteFile(se.state.Path("env"), []byte("S=1\n"), 0o600)
	if code := se.run("--scratch", "run", "true"); code != 0 {
		t.Fatalf("scratch: %d %s", code, se.out())
	}
	for name := range se.fake.VMs {
		if name != vmname.Template {
			t.Errorf("left: %s", name)
		}
	}
	if !strings.Contains(se.fake.CallLog(), "-scratch-") || !strings.Contains(se.out(), "Deleting scratch VM") {
		t.Errorf("scratch: %s\n%s", se.out(), se.fake.CallLog())
	}
	if len(se.g.payloads) != 1 || se.g.payloads[0] != "S=1\n" {
		t.Errorf("only the shared env goes in: %q", se.g.payloads)
	}
	if se.run("--scratch", "--readonly", "run", "true") != 1 || !strings.Contains(se.out(), "--reset and --readonly do not go with it") {
		t.Errorf("scratch readonly: %s", se.out())
	}
	// A leftover of a run that is gone is deleted; one in use is not.
	gone := "proj-scratch-0000aaaa"
	used := "proj-scratch-0000bbbb"
	for _, n := range []string{gone, used} {
		se.fake.VMs[n] = &vm.Instance{Name: n, Status: vm.Running}
	}
	os.WriteFile(se.state.Marker(state.ScratchOf, gone), []byte("999999999\n"), 0o644)
	os.WriteFile(se.state.Marker(state.ScratchOf, used), []byte(fmt.Sprintln(os.Getpid())), 0o644)
	se.run("--scratch", "run", "true")
	if se.fake.VMs[gone] != nil || se.fake.VMs[used] == nil {
		t.Errorf("leftovers: %s", se.out())
	}
}

// On a terminal: a no opens a shell in the VM, then asks again.
func TestStartScratchAsk(t *testing.T) {
	se := newStartEnv(t, "n", "y")
	se.base()
	if code := se.run("--scratch", "run", "true"); code != 0 {
		t.Fatalf("scratch: %d %s", code, se.out())
	}
	log := se.fake.CallLog()
	// The scratch VM's own name, which socket room may cut short: read
	// it, rather than the folder's.
	name := ""
	if i := strings.Index(se.out(), "Deleting scratch VM '"); i >= 0 {
		rest := se.out()[i+len("Deleting scratch VM '"):]
		if j := strings.IndexByte(rest, '\''); j >= 0 {
			name = rest[:j]
		}
	}
	shell, del := strings.LastIndex(log, " zsh -l\n"), strings.Index(log, "delete "+name)
	if strings.Count(se.out(), "Delete scratch VM '") != 2 || !strings.Contains(se.out(), "Type 'exit' to be asked again.") ||
		name == "" || shell < 0 || del < shell {
		t.Errorf("asked: %s\n%s", se.out(), log)
	}
	if len(se.fake.VMs) != 1 {
		t.Errorf("left: %v", se.fake.VMs)
	}
}

// A network file the hostagent would stop on stops the start here, named;
// setup too; doctor says it.
func TestStartPolicyFiles(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	os.WriteFile(se.state.Path("network"), []byte("allow 10.0.0.0/8\nallow nowhere\n"), 0o644)
	if se.run("run", "true") != 1 || !strings.Contains(se.out(), "network, line 2") || strings.Contains(se.fake.CallLog(), "start ") {
		t.Errorf("bad network file: %s\n%s", se.out(), se.fake.CallLog())
	}
	if se.setupBase([]string{"setup", "--preinstall=none"}) != 1 || !strings.Contains(se.out(), "network, line 2") || se.fake.CallLog() != "" {
		t.Errorf("setup: %s\n%s", se.out(), se.fake.CallLog())
	}
	se.run("doctor")
	if !strings.Contains(se.stdout.String(), "  FAIL  "+se.state.Path("network")+", line 2") {
		t.Errorf("doctor: %s", se.stdout.String())
	}
	os.WriteFile(se.state.Path("network"), []byte("allow localhost:11434\n"), 0o644)
	if se.run("run", "true") != 0 {
		t.Errorf("good network file: %s", se.out())
	}
	t.Setenv("AGENT_VM_UNSAFE_OPEN_NETWORK", "1")
	se.run("doctor")
	if !strings.Contains(se.stdout.String(), "  warn  network isolation off") {
		t.Errorf("doctor, open: %s", se.stdout.String())
	}
}
