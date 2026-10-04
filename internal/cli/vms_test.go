package cli

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/ui"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vm/vmtest"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

// testEnv runs commands against fake, with a state folder of its own and
// no terminal, unless answers are given: then one is asked each time.
type testEnv struct {
	*app
	fake           *vmtest.Fake
	stdout, stderr bytes.Buffer
}

func newTestEnv(t *testing.T, fake *vmtest.Fake, answers ...string) *testEnv {
	t.Helper()
	te := &testEnv{fake: fake}
	u := &ui.UI{Stderr: &te.stderr, OpenTTY: func() (io.ReadCloser, error) { return nil, errors.New("no tty") }}
	if answers != nil {
		u.StderrIsTerminal = true
		pop := func() string {
			a := ""
			if len(answers) > 0 {
				a, answers = answers[0], answers[1:]
			}
			return a
		}
		u.OpenTTY = func() (io.ReadCloser, error) { return &answer{pop: pop}, nil }
	}
	te.app = &app{
		io:      IO{Stdin: strings.NewReader(""), Stdout: &te.stdout, Stderr: &te.stderr},
		ui:      u,
		state:   state.Dir(t.TempDir()),
		newBack: func() (vm.Backend, error) { return fake, nil },
	}
	return te
}

// answer is a terminal that holds the next answer once read: opening it to
// see whether there is one (CanAsk) takes none.
type answer struct {
	pop func() string
	r   io.Reader
}

func (a *answer) Read(p []byte) (int, error) {
	if a.r == nil {
		a.r = strings.NewReader(a.pop())
	}
	return a.r.Read(p)
}

func (a *answer) Close() error { return nil }

func (te *testEnv) run(args ...string) int {
	te.stdout.Reset()
	te.stderr.Reset()
	te.fake.Calls = nil
	return te.main(context.Background(), args)
}

func (te *testEnv) out() string { return te.stdout.String() + te.stderr.String() }

func running(name string) *vm.Instance { return &vm.Instance{Name: name, Status: vm.Running} }

func TestStopRm(t *testing.T) {
	te := newTestEnv(t, vmtest.New(running("proj-deadbeef")))
	if te.run("stop", "proj-deadbeef") != 0 || te.fake.CallLog() != "stop proj-deadbeef" {
		t.Errorf("stop <name>: %s %s", te.fake.CallLog(), te.out())
	}
	if te.out() != "Stopping VM 'proj-deadbeef'...\nVM stopped.\n" {
		t.Errorf("stop said: %q", te.out())
	}

	// A VM that stays running is said, not reported as stopped.
	te.fake.VMs["proj-deadbeef"].Status = vm.Running
	te.fake.Sticky["proj-deadbeef"] = true
	if te.run("stop", "proj-deadbeef") != 1 || !strings.Contains(te.out(), "is still running") {
		t.Errorf("stop that did not take: %s", te.out())
	}
	// Nor a delete that did not take.
	os.WriteFile(te.state.Marker(state.VersionOf, "proj-deadbeef"), []byte("1\n"), 0o644)
	if te.run("rm", "proj-deadbeef") != 1 || !strings.Contains(te.out(), "could not delete VM 'proj-deadbeef'") ||
		strings.Contains(te.out(), "VM destroyed.") {
		t.Errorf("rm that did not take: %s", te.out())
	}
	if _, err := os.Stat(te.state.Marker(state.VersionOf, "proj-deadbeef")); err != nil {
		t.Error("a VM still there was forgotten")
	}
	te.fake.Sticky = map[string]bool{}
	if te.run("rm", "proj-deadbeef") != 0 || te.fake.CallLog() != "delete proj-deadbeef" || !strings.HasSuffix(te.out(), "VM destroyed.\n") {
		t.Errorf("rm <name>: %s %s", te.fake.CallLog(), te.out())
	}
	if _, err := os.Stat(te.state.Marker(state.VersionOf, "proj-deadbeef")); !os.IsNotExist(err) {
		t.Error("rm left the VM's markers")
	}

	// agent-vm's Lima home holds its VMs alone: any name is looked up.
	if te.run("rm", "some-other-vm") != 1 || !strings.Contains(te.out(), "no such VM: some-other-vm") || te.fake.CallLog() != "" {
		t.Errorf("rm unknown: %s %s", te.out(), te.fake.CallLog())
	}
	if te.run("stop", "does-not-exist") != 1 || !strings.Contains(te.out(), "no such VM: does-not-exist") || te.fake.CallLog() != "" {
		t.Errorf("stop unknown: %s", te.out())
	}
	if te.run("stop", "a-00000000", "b-00000000") != 1 || !strings.Contains(te.out(), "Usage: agent-vm stop [vm-name]") {
		t.Errorf("stop two: %s", te.out())
	}

	// Without a name, the current directory's VM.
	proj := t.TempDir()
	t.Chdir(proj)
	t.Setenv("PWD", proj)
	if te.run("stop") != 1 || !strings.Contains(te.out(), "No VM found for this directory.") {
		t.Errorf("stop, no VM here: %s", te.out())
	}
	te.fake.VMs[vmname.Name(proj)] = running(vmname.Name(proj))
	if te.run("stop") != 0 || te.fake.CallLog() != "stop "+vmname.Name(proj) {
		t.Errorf("stop here: %s %s", te.fake.CallLog(), te.out())
	}
}

func TestDestroyAll(t *testing.T) {
	te := newTestEnv(t, vmtest.New(running("a-00000000"), running("base")))
	if te.run("destroy-all") != 0 || !strings.HasSuffix(te.out(), "Aborted.\n") || te.fake.CallLog() != "" {
		t.Errorf("no terminal: %s %s", te.out(), te.fake.CallLog())
	}
	if !strings.Contains(te.out(), "(base is the base template: 'agent-vm setup' rebuilds it.)") {
		t.Errorf("the base is not named: %s", te.out())
	}
	te = newTestEnv(t, te.fake, "n\n")
	if te.run("destroy-all") != 0 || te.fake.CallLog() != "" {
		t.Errorf("a no: %s", te.fake.CallLog())
	}
	te = newTestEnv(t, te.fake, "y\n", "y\n")
	te.fake.Sticky["a-00000000"] = true
	if te.run("destroy-all") != 1 || !strings.Contains(te.out(), "could not delete VM 'a-00000000'") || strings.Contains(te.out(), "All VMs destroyed.") {
		t.Errorf("one stays: %s", te.out())
	}
	te.fake.Sticky = map[string]bool{}
	te.fake.VMs["base"] = running("base")
	os.MkdirAll(string(te.state), 0o755)
	for _, f := range []string{state.BaseVersion, state.BaseBuiltBy} {
		os.WriteFile(te.state.Path(f), []byte("x\n"), 0o644)
	}
	if te.run("destroy-all") != 0 || !strings.HasSuffix(te.stdout.String(), "All VMs destroyed.\n") || len(te.fake.VMs) != 0 {
		t.Errorf("a yes: %s", te.out())
	}
	for _, f := range []string{state.BaseVersion, state.BaseBuiltBy} {
		if _, err := os.Stat(te.state.Path(f)); err == nil {
			t.Errorf("%s left: the next start would take a missing base as ready", f)
		}
	}
	if te.run("destroy-all") != 0 || te.out() != "No agent-vm VMs found.\n" {
		t.Errorf("none left: %q", te.out())
	}
	te.fake.Err = errors.New("broken")
	if te.run("destroy-all") != 1 || !strings.Contains(te.out(), "could not query Lima") {
		t.Errorf("a backend that fails: %s", te.out())
	}
}

func TestList(t *testing.T) {
	proj := t.TempDir()
	t.Chdir(proj)
	t.Setenv("PWD", proj)
	here := vmname.Name(proj)
	te := newTestEnv(t, vmtest.New())
	if te.run("list") != 0 || te.out() != "  (no VMs)\n" {
		t.Errorf("no VM: %q", te.out())
	}
	te.fake.VMs[here] = &vm.Instance{Name: here, Status: vm.Running, SSHAddress: "127.0.0.1", SSHLocalPort: 60022,
		VMType: "qemu", Arch: "aarch64", CPUs: 2, Memory: 4 << 30, Disk: 10 << 30, Dir: filepath.Join(proj, "lima", here)}
	te.fake.VMs["base"] = &vm.Instance{Name: "base", Status: vm.Stopped, VMType: "qemu", Arch: "aarch64", CPUs: 1, Memory: 2 << 30, Disk: 10 << 30}
	os.WriteFile(te.state.Path(state.BaseVersion), []byte("1759000000\n"), 0o644)
	os.WriteFile(te.state.Path(state.BaseBuiltBy), []byte("0.2.1\n"), 0o644)
	os.WriteFile(te.state.Marker(state.BuiltByOf, here), []byte("0.2.0\n"), 0o644)
	if te.run("status") != 0 {
		t.Fatal(te.out())
	}
	// Rows in name order, this folder's marked, the base last and aligned.
	day := time.Unix(1759000000, 0).Format("2006-01-02")
	want := map[string]string{"  NAME ": "BASE", "  base ": "0.2.1 " + day, "> " + here + " ": "0.2.0 -"}
	lines := strings.Split(strings.TrimSuffix(te.out(), "\n"), "\n")
	col := -1
	for _, l := range lines {
		found := false
		for prefix, label := range want {
			if strings.HasPrefix(l, prefix) && strings.HasSuffix(l, "   "+label) {
				found = true
				if c := len(l) - len(label); col >= 0 && c != col {
					t.Errorf("BASE not aligned in %q", l)
				} else {
					col = c
				}
			}
		}
		if !found {
			t.Errorf("unexpected line %q", l)
		}
	}
	if len(lines) != 3 {
		t.Errorf("list:\n%s", te.out())
	}
	te.fake.Err = errors.New("broken")
	if te.run("list") != 1 || !strings.Contains(te.out(), "could not query Lima") {
		t.Errorf("failing backend: %s", te.out())
	}
}
