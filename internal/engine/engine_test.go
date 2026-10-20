package engine

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/sylvinus/agent-vm/internal/host"
	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/policy"
	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vm/vmtest"
	"github.com/sylvinus/agent-vm/provision"
)

// testAsker answers from a script and records the questions.
type testAsker struct {
	can     bool
	answers []bool
	asked   []Question
}

func (a *testAsker) CanAsk() bool { return a.can }

func (a *testAsker) Ask(_ context.Context, q Question) bool {
	a.asked = append(a.asked, q)
	if len(a.answers) == 0 {
		return q.Default
	}
	ans := a.answers[0]
	a.answers = a.answers[1:]
	return ans
}

type testEngine struct {
	*Engine
	fake   *vmtest.Fake
	asker  *testAsker
	mu     sync.Mutex
	events []Event
	proj   string
}

func (te *testEngine) text() string {
	te.mu.Lock()
	defer te.mu.Unlock()
	var b strings.Builder
	for _, ev := range te.events {
		b.WriteString(ev.Text + "\n")
	}
	return b.String()
}

// newTest is an engine over a fake backend, in a state folder and with a
// project folder of its own, home and git config out of the way.
func newTest(t *testing.T, mod func(*Options)) *testEngine {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	home, _ := filepath.EvalSymlinks(t.TempDir())
	home = paths.Host(home)
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	os.Unsetenv("GIT_CONFIG_GLOBAL")
	os.Unsetenv("XDG_CONFIG_HOME")
	t.Setenv("APPDATA", "")
	t.Setenv("LOCALAPPDATA", "")
	os.WriteFile(filepath.Join(home, ".gitconfig"), []byte("[safe]\n\tbareRepository = explicit\n"), 0o644)
	proj := filepath.Join(home, "proj")
	os.MkdirAll(proj, 0o755)
	t.Chdir(proj)
	t.Setenv("PWD", proj)

	cpus, mem := host.CPUs, host.MemGiB
	t.Cleanup(func() { host.CPUs, host.MemGiB = cpus, mem })
	host.CPUs = func() int { return 64 }
	host.MemGiB = func() int { return 256 }
	te := &testEngine{fake: vmtest.New(), asker: &testAsker{}, proj: proj}
	// The guest answers the probe as a VM with its shares would.
	te.fake.ShellFunc = func(name string, o vm.ShellOpts) int {
		if len(o.Args) > 2 && o.Args[0] == "sh" && o.Args[2] == ProbeScript {
			io.Copy(io.Discard, o.Stdin)
			io.WriteString(o.Stdout, "env-ok\n")
			if o.Args[7] != "" {
				io.WriteString(o.Stdout, "share-ok\n")
			}
			if v := te.fake.VMs[name]; v == nil || len(v.Mounts) > 0 && !v.Mounts[0].Writable {
				return 1
			}
		}
		return 0
	}
	opts := Options{
		StateDir: filepath.Join(home, ".mytool"),
		AppName:  "mytool",
		Asker:    te.asker,
		Backend:  te.fake,
		OnEvent: func(ev Event) {
			te.mu.Lock()
			te.events = append(te.events, ev)
			te.mu.Unlock()
		},
	}
	if mod != nil {
		mod(&opts)
	}
	e, err := Open(opts)
	if err != nil {
		t.Fatal(err)
	}
	te.Engine = e
	return te
}

// ready makes the base template exist and be ready.
func (te *testEngine) ready(template string) {
	te.fake.VMs[template] = &vm.Instance{Name: template, Status: vm.Stopped, CPUs: 1, Memory: 3 << 30, Disk: 10 << 30}
	te.state.UpdateMeta(template, func(m *state.Metadata) {
		m.Base = &state.Base{Name: template, Built: 1759000000, BuiltBy: "0.4.0"}
	})
}

func TestOpenOptions(t *testing.T) {
	if _, err := Open(Options{}); err == nil || !strings.Contains(err.Error(), "StateDir") {
		t.Errorf("no state dir: %v", err)
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	e, err := Open(Options{StateDir: "~/.mytool", Backend: vmtest.New()})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(e.State()), paths.Host(filepath.Join(home, ".mytool")); got != want {
		t.Errorf("state %q, want %q", got, want)
	}
	if e.AppName() != "agent-vm" || e.LimaHome() != e.State().LimaHome() {
		t.Errorf("defaults: %q %q", e.AppName(), e.LimaHome())
	}
}

// The first start of a project: the base is cloned, its shares set, policies
// written for the host agent, and the program told what happens.
func TestEnsureNewVM(t *testing.T) {
	te := newTest(t, nil)
	te.ready("base")
	v, err := te.ProjectVM("")
	if err != nil {
		t.Fatal(err)
	}
	if err := v.Ensure(context.Background(), Spec{}); err != nil {
		t.Fatalf("%v\n%s", err, te.text())
	}
	if !v.Created() {
		t.Error("not created")
	}
	got := te.fake.VMs[v.Name]
	if got == nil || got.Status != vm.Running || got.MountType != vm.ReverseSSHFS || len(got.Mounts) != 1 || !got.Mounts[0].Writable {
		t.Fatalf("VM: %+v", got)
	}
	if !strings.HasPrefix(te.fake.CallLog(), "clone base "+v.Name+"\nedit "+v.Name+"\nedit "+v.Name+"\nstart "+v.Name) {
		t.Errorf("calls:\n%s", te.fake.CallLog())
	}
	for _, want := range []string{"Creating VM '" + v.Name + "'...", "Starting VM '" + v.Name + "'..."} {
		if !strings.Contains(te.text(), want) {
			t.Errorf("no %q in:\n%s", want, te.text())
		}
	}
	pf, err := policy.Read(te.state.Policy(v.Name))
	if err != nil || pf.App != "mytool" || pf.Network == nil {
		t.Errorf("policy: %+v %v", pf, err)
	}
	if b := te.state.Known(v.Name).Base; b == nil || b.Built != 1759000000 {
		t.Errorf("base recorded: %+v", b)
	}
	// Again: nothing to change.
	te.fake.Calls = nil
	if err := v.Ensure(context.Background(), Spec{}); err != nil {
		t.Fatal(err)
	}
	if log := te.fake.CallLog(); strings.Contains(log, "edit") || strings.Contains(log, "start") {
		t.Errorf("second Ensure changed the VM:\n%s", log)
	}
}

// What a start stops on is an error that errors.Is matches, told as an
// event first, naming the program as the engine was opened.
func TestEnsureErrors(t *testing.T) {
	te := newTest(t, nil)
	v, _ := te.ProjectVM("")
	err := v.Ensure(context.Background(), Spec{})
	if !errors.Is(err, ErrBaseMissing) || !strings.Contains(te.text(), "Run 'mytool setup' first.") || strings.Contains(te.text(), "agent-vm") {
		t.Errorf("no base: %v\n%s", err, te.text())
	}
	te.fake.VMs["base"] = &vm.Instance{Name: "base", Status: vm.Stopped}
	if err := v.Ensure(context.Background(), Spec{}); !errors.Is(err, ErrBaseIncomplete) {
		t.Errorf("base without its record: %v", err)
	}
	te.ready("base")

	// A project the VM must not get.
	home, _ := os.UserHomeDir()
	t.Chdir(home)
	t.Setenv("PWD", home)
	hv, _ := te.ProjectVM("")
	err = hv.Ensure(context.Background(), Spec{})
	var refused *RefusedError
	if !errors.Is(err, ErrRefused) || !errors.As(err, &refused) || refused.Dir != paths.Host(home) {
		t.Errorf("home: %v", err)
	}

	// An unreadable policy stops the start before Lima does.
	te2 := newTest(t, func(o *Options) {
		o.Policy = func() (*policy.File, error) { return nil, errors.New("network, line 2: nope") }
	})
	te2.ready("base")
	v2, _ := te2.ProjectVM("")
	if err := v2.Ensure(context.Background(), Spec{}); err == nil || !strings.Contains(te2.text(), "network, line 2: nope") || strings.Contains(te2.fake.CallLog(), "start ") {
		t.Errorf("bad policy: %v\n%s\n%s", err, te2.text(), te2.fake.CallLog())
	}
}

// Questions go to the Asker; without one, or one that cannot ask, the answer
// is no.
func TestAskerAndNoAsker(t *testing.T) {
	te := newTest(t, nil)
	te.ready("base")
	v, _ := te.ProjectVM("")
	ctx := context.Background()
	if err := v.Ensure(ctx, Spec{}); err != nil {
		t.Fatal(err)
	}
	// Running, and a resource change asked: a restart is put to the Asker.
	te.fake.VMs[v.Name].Status = vm.Running
	te.asker.can = true
	te.asker.answers = []bool{false}
	if err := v.Ensure(ctx, Spec{CPUs: 2}); err != nil {
		t.Fatalf("%v\n%s", err, te.text())
	}
	if len(te.asker.asked) != 1 || te.asker.asked[0].Kind != QRestart || te.asker.asked[0].VM != v.Name || !strings.Contains(te.text(), "Not applied: the VM keeps its current settings.") {
		t.Errorf("asked %+v\n%s", te.asker.asked, te.text())
	}
	// No Asker: the same, without a question.
	te2 := newTest(t, func(o *Options) { o.Asker = nil })
	te2.ready("base")
	v2, _ := te2.ProjectVM("")
	if err := v2.Ensure(ctx, Spec{}); err != nil {
		t.Fatal(err)
	}
	te2.fake.VMs[v2.Name].Status = vm.Running
	if err := v2.Ensure(ctx, Spec{CPUs: 2}); err != nil || !strings.Contains(te2.text(), "Not applied") {
		t.Errorf("no asker: %v\n%s", err, te2.text())
	}
	// --readonly asked of a running VM that is writable: refused, not silent.
	te2.fake.VMs[v2.Name].Status = vm.Running
	if err := v2.Ensure(ctx, Spec{ReadOnly: true}); !errors.Is(err, ErrNotApplied) {
		t.Errorf("readonly on a running VM, no asker: %v", err)
	}
}

// The unsafe flags: what turns the security questions off is told.
func TestUnsafeNoPrompts(t *testing.T) {
	te := newTest(t, nil)
	te.ready("base")
	// A hooks folder that cannot be protected is a question; with the prompts
	// off, it is answered yes and said.
	exec.Command("git", "-C", te.proj, "init", "-q").Run()
	exec.Command("git", "-C", te.proj, "config", "core.hooksPath", ".").Run()
	v, _ := te.ProjectVM("")
	if err := v.Ensure(context.Background(), Spec{}); !errors.Is(err, ErrAborted) {
		t.Fatalf("without an asker: %v\n%s", err, te.text())
	}
	if len(te.asker.asked) != 0 {
		t.Errorf("asked although it cannot: %+v", te.asker.asked)
	}
	if err := v.Ensure(context.Background(), Spec{UnsafeNoPrompts: "--the-flag"}); err != nil {
		t.Fatalf("%v\n%s", err, te.text())
	}
	if !strings.Contains(te.text(), "Continuing: --the-flag.") {
		t.Errorf("not said:\n%s", te.text())
	}
}

// Exec runs through a login zsh, naming the program in what it says.
func TestExec(t *testing.T) {
	te := newTest(t, nil)
	te.ready("base")
	v, _ := te.ProjectVM("")
	te.fake.VMs[v.Name] = &vm.Instance{Name: v.Name, Status: vm.Running}
	var got vm.ShellOpts
	te.fake.ShellFunc = func(_ string, o vm.ShellOpts) int { got = o; return 7 }
	code, err := v.Exec(context.Background(), Exec{Args: []string{"mytool-agent", "--x"}, TTY: true})
	if err != nil || code != 7 {
		t.Fatalf("%d %v", code, err)
	}
	if got.Workdir != paths.Guest(v.Dir) || !got.Interactive || len(got.Args) < 6 || got.Args[0] != "zsh" || got.Args[len(got.Args)-2] != "mytool-agent" ||
		!strings.Contains(got.Args[3], "mytool: $1 is not installed in this VM.") {
		t.Errorf("shell opts: %+v", got)
	}
	code, err = v.Shell(context.Background(), Exec{Args: []string{"zsh", "-l"}})
	if err != nil || code != 7 || strings.Join(got.Args, " ") != "zsh -l" {
		t.Errorf("shell: %d %v %q", code, err, got.Args)
	}
}

// Setup builds the template under another name, then swaps it in.
func TestSetup(t *testing.T) {
	te := newTest(t, nil)
	var scripts []string
	te.fake.ShellFunc = func(name string, o vm.ShellOpts) int {
		b, _ := io.ReadAll(o.Stdin)
		scripts = append(scripts, name+": "+strings.Join(o.Args, " ")+": "+string(b))
		if _, err := policy.Read(te.state.Policy(name)); err != nil {
			t.Errorf("the build boots without a policy: %v", err)
		}
		return 0
	}
	tmpl := provision.Template{
		Name: "base-mytool", MemoryGiB: 2, DiskGiB: 8,
		Scripts: []provision.Script{
			{Name: "install", Message: "Installing...", Shell: []string{"bash", "-l"}, Content: "echo hi\n", Env: []string{"A=1", "B=it's"}},
			{Name: "more", Content: "echo more\n"},
		},
		Env: []string{"T=t"},
	}
	var steps []string
	out := stepFunc(func(name string, fn func(o, e io.Writer) error) error {
		steps = append(steps, name)
		return fn(io.Discard, io.Discard)
	})
	if err := te.Setup(context.Background(), tmpl, out); err != nil {
		t.Fatalf("%v\n%s", err, te.text())
	}
	if strings.Join(steps, ",") != "create,start,script:install,script:more" {
		t.Errorf("steps %v", steps)
	}
	want := []string{
		"base-mytool-building: bash -l: export T=t\nexport A=1\nexport B='it'\\''s'\necho hi\n",
		"base-mytool-building: bash -l: export T=t\necho more\n",
	}
	if len(scripts) != 2 || scripts[0] != want[0] || scripts[1] != want[1] {
		t.Errorf("scripts %q", scripts)
	}
	if !strings.HasPrefix(te.fake.CallLog(), "delete base-mytool-building\ncreate base-mytool-building template:debian-13\nstart base-mytool-building\nshell") ||
		!strings.Contains(te.fake.CallLog(), "stop base-mytool-building\ndelete base-mytool\nclone base-mytool-building base-mytool\ndelete base-mytool-building") {
		t.Errorf("calls:\n%s", te.fake.CallLog())
	}
	if te.fake.VMs["base-mytool"] == nil || te.fake.VMs["base-mytool"].Memory != 2<<30 || !te.state.BaseReady("base-mytool") {
		t.Errorf("template: %+v", te.fake.VMs["base-mytool"])
	}
	// A VM is cloned from the template it names.
	v, _ := te.ProjectVM("")
	if err := v.Ensure(context.Background(), Spec{Base: "base-mytool"}); err != nil {
		t.Fatalf("%v\n%s", err, te.text())
	}
	if !strings.Contains(te.fake.CallLog(), "clone base-mytool "+v.Name) {
		t.Errorf("cloned from another:\n%s", te.fake.CallLog())
	}

	// A script that fails stops the build and leaves the template.
	te.fake.ShellFunc = func(string, vm.ShellOpts) int { return 3 }
	err := te.Setup(context.Background(), tmpl, out)
	var se *SetupError
	if !errors.As(err, &se) || se.Step != "script" || se.Script != "install" || se.Told {
		t.Errorf("failing script: %v", err)
	}
	if !te.state.BaseReady("base-mytool") || te.fake.VMs["base-mytool"] == nil {
		t.Error("a failed build took the template")
	}
}

type stepFunc func(name string, fn func(stdout, stderr io.Writer) error) error

func (f stepFunc) Step(name string, fn func(stdout, stderr io.Writer) error) error {
	return f(name, fn)
}

// A scratch VM has a name of its own and a record of its run; one whose run
// is gone is found.
func TestScratch(t *testing.T) {
	te := newTest(t, nil)
	te.ready("base")
	v, err := te.NewScratchVM("")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(v.Name, "-scratch-") || te.state.Known(v.Name).ScratchPID != os.Getpid() {
		t.Errorf("scratch VM %q %+v", v.Name, te.state.Known(v.Name))
	}
	if err := v.Ensure(context.Background(), Spec{}); err != nil {
		t.Fatalf("%v\n%s", err, te.text())
	}
	if got := te.fake.VMs[v.Name]; got == nil || len(got.Mounts) != 0 {
		t.Errorf("a scratch VM shares nothing: %+v", got)
	}
	dead, unknown := te.ScratchLeftovers()
	if len(dead) != 0 || len(unknown) != 0 {
		t.Errorf("this run's VM is a leftover: %v %v", dead, unknown)
	}
	te.state.UpdateMeta(v.Name, func(m *state.Metadata) { m.ScratchPID = 999999999 })
	if dead, _ = te.ScratchLeftovers(); len(dead) != 1 || dead[0] != v.Name {
		t.Errorf("dead run: %v", dead)
	}
	if !v.Remove(context.Background()) || te.fake.VMs[v.Name] != nil {
		t.Error("not removed")
	}
	if _, err := os.Stat(te.state.VM(v.Name)); !os.IsNotExist(err) {
		t.Error("its folder is left")
	}
}

// The resources asked against the VM's: in bytes, the disk one way (it
// only grows), a VM that cannot be read counts as a change.
func TestResourcesDiffer(t *testing.T) {
	inst := &vm.Instance{CPUs: 2, Memory: 4 << 30, Disk: 20 << 30}
	for _, c := range []struct {
		o    Spec
		want bool
	}{
		{Spec{}, false},
		{Spec{CPUs: 2, MemoryGiB: 4, DiskGiB: 20}, false},
		{Spec{CPUs: 3}, true},
		{Spec{MemoryGiB: 5}, true},
		{Spec{DiskGiB: 10}, false},
		{Spec{DiskGiB: 30}, true},
	} {
		s := &session{spec: c.o}
		if got := s.resourcesDiffer(inst); got != c.want {
			t.Errorf("%+v: %v", c.o, got)
		}
	}
	if !(&session{spec: Spec{CPUs: 2}}).resourcesDiffer(nil) {
		t.Error("an unknown VM is no change")
	}
	// Half a GiB more than asked: a change.
	if !(&session{spec: Spec{MemoryGiB: 4}}).resourcesDiffer(&vm.Instance{Memory: 4<<30 + 1<<29}) {
		t.Error("compared in whole GiB")
	}
}

// beforeBoot holds every check that applies: --readonly with .git
// protected refuses a protected share left writable.
func TestBeforeBootAll(t *testing.T) {
	te := newTest(t, nil)
	name := "p-12345678"
	off := false
	te.fake.VMs[name] = &vm.Instance{Name: name, Status: vm.Stopped, MountType: vm.ReverseSSHFS, Mounts: []vm.Mount{{
		Location: te.proj, Writable: true, SSHFS: &vm.SSHFS{SFTPDriver: "builtin", Cache: &off, ReadonlyNames: []string{".git", ".hg"}}}}}
	s := &session{Engine: te.Engine, ctx: context.Background(), name: name, spec: Spec{ReadOnly: true}, protect: true, names: []string{".git", ".hg"}}
	if err := s.beforeBoot(); err == nil || !strings.Contains(te.text(), "a writable share of "+te.proj) {
		t.Errorf("--readonly, protected, writable: %v\n%s", err, te.text())
	}
	s.spec.ReadOnly = false
	if err := s.beforeBoot(); err != nil {
		t.Errorf("writable asked: %v\n%s", err, te.text())
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
		{inst(rs, vm.Mount{Location: "/p", Writable: true, SSHFS: b(".git", ".hg", ".sl", ".jj")}), nil, "", "a writable share of /p"},
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

func TestEventWriter(t *testing.T) {
	te := newTest(t, nil)
	w := te.writer(Warning, "x")
	io.WriteString(w, "one\ntw")
	io.WriteString(w, "o\n\nthree\n")
	if got := te.text(); got != "one\ntwo\n\nthree\n" {
		t.Errorf("events %q", got)
	}
	for _, ev := range te.events {
		if ev.Level != Warning || ev.VM != "x" {
			t.Errorf("event %+v", ev)
		}
	}
}
