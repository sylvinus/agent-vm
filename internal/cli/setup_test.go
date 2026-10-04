package cli

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	agentvm "github.com/sylvinus/agent-vm"
	"github.com/sylvinus/agent-vm/internal/host"
	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vm/vmtest"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

// setupRun runs setup against a fake, with the host's prerequisites taken
// as met, and returns what the guest was given to run.
func setupRun(t *testing.T, args ...string) (*testEnv, int, []string) {
	t.Helper()
	te := newTestEnv(t, vmtest.New())
	host.CPUs = func() int { return 64 }
	host.MemGiB = func() int { return 256 }
	var stdin []string
	te.fake.ShellFunc = func(name string, o vm.ShellOpts) int {
		b, _ := io.ReadAll(o.Stdin)
		stdin = append(stdin, string(b))
		return 0
	}
	code := te.setupBase(append([]string{"setup"}, args...))
	return te, code, stdin
}

// setupBase is setup without the host's prerequisites, which a test host
// may lack.
func (te *testEnv) setupBase(args []string) int {
	te.stdout.Reset()
	te.stderr.Reset()
	te.fake.Calls = nil
	saved := skipPrereqs
	skipPrereqs = true
	defer func() { skipPrereqs = saved }()
	return te.main(context.Background(), args)
}

func exportsOf(t *testing.T, stdin []string) map[string]string {
	t.Helper()
	if len(stdin) == 0 || !strings.HasSuffix(stdin[0], agentvm.SetupScript) {
		t.Fatalf("the setup script was not run: %q", stdin)
	}
	m := map[string]string{}
	for _, l := range strings.Split(strings.TrimSuffix(stdin[0], agentvm.SetupScript), "\n") {
		if k, v, ok := strings.Cut(strings.TrimPrefix(l, "export AGENT_VM_INSTALL_"), "="); ok {
			m[k] = v
		}
	}
	return m
}

func on(m map[string]string) string {
	var out []string
	for _, n := range software {
		if m[strings.ToUpper(strings.ReplaceAll(n, "-", "_"))] == "1" {
			out = append(out, n)
		}
	}
	return strings.Join(out, ",")
}

func TestSetupPreinstall(t *testing.T) {
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"--preinstall=default"}, "python,node,docker,chromium,gh,claude,opencode,codex,vibe,mcp-chrome"},
		{[]string{"--preinstall", "--disk", "20"}, "python,node,docker,chromium,gh,claude,opencode,codex,vibe,mcp-chrome"},
		{[]string{"--preinstall=none"}, ""},
		{[]string{"--preinstall=all"}, strings.Join(software, ",")},
		{[]string{"--preinstall=python, docker,claude"}, "python,docker,claude"},
		{[]string{"--preinstall=code-vibe"}, "code-server,code-vibe"},
		// Codex needs npm: node goes in, and it is said.
		{[]string{"--preinstall=codex"}, "node,codex"},
	} {
		te, code, stdin := setupRun(t, c.args...)
		if code != 0 {
			t.Fatalf("%q: %d %s", c.args, code, te.out())
		}
		if got := on(exportsOf(t, stdin)); got != c.want {
			t.Errorf("%q: %s, want %s", c.args, got, c.want)
		}
		if c.want == "node,codex" && !strings.Contains(te.out(), "Enabling Node.js because Codex CLI requires npm.") {
			t.Errorf("node not said: %s", te.out())
		}
	}
	te, code, _ := setupRun(t, "--preinstall=Claude")
	if code != 1 || !strings.Contains(te.out(), "Unknown preinstall name: Claude (names are lowercase)") {
		t.Errorf("unknown name: %s", te.out())
	}
	te, code, _ = setupRun(t, "--reset")
	if code != 1 || !strings.Contains(te.out(), "Unknown option: --reset") {
		t.Errorf("--reset: %s", te.out())
	}
	for _, args := range [][]string{{"--rm"}, {"--scratch"}, {"--ssh-port=2222"}, {"--disk", "10G"}, {"--disk"}, {"--unsafe-writable-git"}, {"--unsafe-disable-security-prompts"}} {
		if te, code, _ = setupRun(t, args...); code != 1 || te.fake.CallLog() != "" {
			t.Errorf("%q: %d %s", args, code, te.out())
		}
	}
	te, code, _ = setupRun(t, "--help")
	if code != 0 || te.stdout.String() != setupHelp {
		t.Error("--help")
	}
}

// wizardRun is setupRun on a terminal, answering the wizard.
func wizardRun(t *testing.T, answers ...string) (*testEnv, []string) {
	t.Helper()
	te := newTestEnv(t, vmtest.New(), answers...)
	host.CPUs = func() int { return 64 }
	host.MemGiB = func() int { return 256 }
	var stdin []string
	te.fake.ShellFunc = func(name string, o vm.ShellOpts) int {
		b, _ := io.ReadAll(o.Stdin)
		stdin = append(stdin, string(b))
		return 0
	}
	if code := te.setupBase([]string{"setup"}); code != 0 {
		t.Fatalf("%d %s", code, te.out())
	}
	return te, stdin
}

func TestSetupWizard(t *testing.T) {
	// Enter everywhere: the default set and resources.
	te, stdin := wizardRun(t)
	if got := on(exportsOf(t, stdin)); got != strings.Join(defaultSoftware, ",") {
		t.Errorf("default: %s", got)
	}
	if b := te.fake.VMs[vmname.Template]; b.CPUs != 1 || b.Memory != 3<<30 || b.Disk != 10<<30 {
		t.Errorf("default resources: %+v", b)
	}
	if !strings.Contains(te.out(), "  Resources: CPUs: 1, Memory: 3 GiB, Disk: 10 GiB\n") {
		t.Errorf("resources not shown: %s", te.out())
	}

	// Each component: Claude and Codex as extensions only, whose Chrome
	// DevTools MCP needs Node.js; code-server makes the default memory 4.
	te, stdin = wizardRun(t,
		"n",                   // the default set
		"", "n", "y", "n", "", // Claude, OpenCode, Codex, Vibe, Pi
		"y", "2", // code-server, extension only
		"n", "y", "n", "y", "", // Docker, Chromium, gh, Chrome MCP, Playwright MCP
		"n", "y", "", "", // Python, Ruby, Rust, Go
		"n", "15", "", "3") // resources
	if got := on(exportsOf(t, stdin)); got != "node,ruby,chromium,code-server,code-claude,code-codex,mcp-chrome" {
		t.Errorf("picked: %s", got)
	}
	if b := te.fake.VMs[vmname.Template]; b.CPUs != 3 || b.Memory != 4<<30 || b.Disk != 15<<30 {
		t.Errorf("resources: %+v", b)
	}
	if !strings.Contains(te.out(), "Node.js 24: yes (Chrome DevTools MCP uses npx)") || !strings.Contains(te.out(), "  agent-vm code\n") ||
		strings.Contains(te.out(), "  agent-vm claude\n") {
		t.Errorf("output: %s", te.out())
	}
}

// code-server makes the default memory 4, but --memory wins. No terminal:
// no wizard, the default set.
func TestSetupWizardMemory(t *testing.T) {
	te := newTestEnv(t, vmtest.New(), "n", "", "", "", "", "", "y")
	host.CPUs = func() int { return 64 }
	host.MemGiB = func() int { return 256 }
	if te.setupBase([]string{"setup", "--memory", "2"}) != 0 {
		t.Fatal(te.out())
	}
	if b := te.fake.VMs[vmname.Template]; b.Memory != 2<<30 || !strings.Contains(te.out(), "code-server (VS Code") {
		t.Errorf("--memory with code-server: %+v %s", b, te.out())
	}

	te, code, stdin := setupRun(t)
	if code != 0 || strings.Contains(te.out(), "setup wizard") || on(exportsOf(t, stdin)) != strings.Join(defaultSoftware, ",") {
		t.Errorf("no terminal: %d %s", code, te.out())
	}
}

func TestSetupFailures(t *testing.T) {
	for _, c := range []struct{ op, want string }{
		{"create", "Error: Failed to create base VM. Full log: "},
		{"start", "Error: Failed to start base VM. Full log: "},
		{"shell", "Error: Setup script failed. Full log: "},
	} {
		te := newTestEnv(t, vmtest.New())
		te.fake.FailOn = map[string]error{c.op: errors.New("boom")}
		if te.setupBase([]string{"setup", "--preinstall=none"}) != 1 || !strings.Contains(te.out(), c.want+te.state.Path("setup.log")) {
			t.Errorf("%s: %s", c.op, te.out())
		}
		if log, _ := os.ReadFile(te.state.Path("setup.log")); !strings.Contains(string(log), "boom") {
			t.Errorf("%s: log %q", c.op, log)
		}
		if _, err := os.Stat(te.state.Path(state.BaseVersion)); err == nil {
			t.Errorf("%s: ready marker", c.op)
		}
	}
	// A base that does not stop is not marked ready: Lima clones only a
	// stopped one.
	te := newTestEnv(t, vmtest.New())
	te.fake.Sticky[vmname.Template] = true
	if te.setupBase([]string{"setup", "--preinstall=none"}) != 1 || !strings.Contains(te.out(), "the base VM is set up but did not stop") {
		t.Errorf("running base: %s", te.out())
	}
	if _, err := os.Stat(te.state.Path(state.BaseVersion)); err == nil {
		t.Error("a running base was marked ready")
	}
}

// Said only to someone with VMs cloned from the previous base.
func TestSetupExistingNote(t *testing.T) {
	const note = "Existing VMs were not updated"
	te, _, _ := setupRun(t, "--preinstall=none")
	if strings.Contains(te.out(), note) {
		t.Errorf("no VM, but: %s", te.out())
	}
	te.fake.VMs["proj-deadbeef"] = &vm.Instance{Name: "proj-deadbeef", Status: vm.Stopped}
	if te.setupBase([]string{"setup", "--preinstall=none"}) != 0 || !strings.Contains(te.out(), note) {
		t.Errorf("with a VM: %s", te.out())
	}
}

func TestSetupBase(t *testing.T) {
	te, code, stdin := setupRun(t, "--preinstall=none", "--disk", "12", "--memory=5", "--cpus", "2")
	if code != 0 {
		t.Fatalf("%d %s", code, te.out())
	}
	base := te.fake.VMs[vmname.Template]
	if base == nil || base.Status != vm.Stopped || base.CPUs != 2 || base.Memory != 5<<30 || base.Disk != 12<<30 || len(base.Mounts) != 0 {
		t.Fatalf("base: %+v", base)
	}
	if !strings.HasPrefix(te.fake.CallLog(), "delete base\ncreate base template:debian-13\nstart base\nshell base bash -l\nstop base") {
		t.Errorf("calls:\n%s", te.fake.CallLog())
	}
	if len(stdin) != 1 {
		t.Errorf("guest stdin: %q", stdin)
	}
	if te.state.Read(te.state.Path(state.BaseBuiltBy)) == "" || te.state.Read(te.state.Path(state.BaseVersion)) == "" {
		t.Error("markers not written")
	}
	if !strings.Contains(te.out(), "Base VM ready.") || strings.Contains(te.out(), "agent-vm claude") {
		t.Errorf("output: %s", te.out())
	}
	// The user's setup.sh, CRs dropped, under zsh; a failure fails setup and
	// leaves no marker.
	os.WriteFile(te.state.Path("setup.sh"), []byte("echo x\r\n"), 0o644)
	var got []string
	te.fake.ShellFunc = func(name string, o vm.ShellOpts) int {
		b, _ := io.ReadAll(o.Stdin)
		got = append(got, strings.Join(o.Args, " ")+": "+string(b))
		if o.Args[0] == "zsh" {
			return 1
		}
		return 0
	}
	if te.setupBase([]string{"setup", "--preinstall=none"}) != 1 || !strings.Contains(te.out(), "Custom setup script failed") {
		t.Errorf("failing setup.sh: %s", te.out())
	}
	if len(got) != 2 || got[1] != "zsh -l: echo x\n" {
		t.Errorf("setup.sh: %q", got)
	}
	if _, err := os.Stat(te.state.Path(state.BaseVersion)); err == nil {
		t.Error("a failed setup left the ready marker")
	}
	// Lima's override.yaml: nothing made.
	cfg := filepath.Join(LimaHome(te.state), "_config")
	os.MkdirAll(cfg, 0o755)
	os.WriteFile(filepath.Join(cfg, "override.yaml"), []byte("mounts: []\n"), 0o644)
	te.fake.Calls = nil
	if te.setupBase([]string{"setup", "--preinstall=none"}) != 1 || !strings.Contains(te.out(), "override.yaml adds to every VM's config") || te.fake.CallLog() != "" {
		t.Errorf("override.yaml: %s\n%s", te.out(), te.fake.CallLog())
	}
}
