package cli

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vm/vmtest"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

func infoMap(t *testing.T, te *testEnv, args ...string) map[string]string {
	t.Helper()
	if code := te.run(append([]string{"info"}, args...)...); code != 0 {
		t.Fatalf("info: %d %s", code, te.out())
	}
	m := map[string]string{}
	for _, l := range strings.Split(strings.TrimSuffix(te.stdout.String(), "\n"), "\n") {
		k, v, ok := strings.Cut(l, "=")
		if !ok {
			t.Fatalf("not key=value: %q", l)
		}
		m[k] = v
	}
	return m
}

func TestInfo(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	os.Unsetenv("GIT_CONFIG_GLOBAL")
	os.Unsetenv("XDG_CONFIG_HOME")
	os.WriteFile(filepath.Join(home, ".gitconfig"), []byte("[safe]\n\tbareRepository = explicit\n"), 0o644)
	proj := filepath.Join(home, "proj")
	os.MkdirAll(proj, 0o755)
	t.Chdir(proj)
	t.Setenv("PWD", proj)
	name := vmname.Name(proj)
	t.Setenv("AGENT_VM_UNSAFE_WRITABLE_GIT", "")

	te := newTestEnv(t, vmtest.New())
	m := infoMap(t, te)
	for k, want := range map[string]string{
		"template": "base", "dir": proj, "vm_name": name, "project_env": proj + "/.agent-vm.env",
		"base_exists": "0", "vm_exists": "0", "vm_running": "0", "vm_stale": "unknown", "ssh_host": "lima-" + name,
		"ssh_config": "unknown", "git_protected": "1", "security_questions": "none", "state_dir": string(te.state),
	} {
		if m[k] != want {
			t.Errorf("no VM: %s=%q, want %q", k, m[k], want)
		}
	}

	// The base, usable once its marker is there; the VM running, from an
	// older base.
	te.fake.VMs[vmname.Template] = &vm.Instance{Name: vmname.Template, Status: vm.Stopped}
	te.fake.VMs[name] = &vm.Instance{Name: name, Status: vm.Running, SSHConfig: "/x/ssh.config"}
	if infoMap(t, te)["base_exists"] != "0" {
		t.Error("a base without its marker counted")
	}
	os.WriteFile(te.state.Path(state.BaseVersion), []byte("2\n"), 0o644)
	os.WriteFile(te.state.Marker(state.VersionOf, name), []byte("1\n"), 0o644)
	m = infoMap(t, te)
	if m["base_exists"] != "1" || m["vm_exists"] != "1" || m["vm_running"] != "1" || m["vm_stale"] != "1" || m["ssh_config"] != "/x/ssh.config" {
		t.Errorf("with VMs: %v", m)
	}
	os.WriteFile(te.state.Marker(state.VersionOf, name), []byte("2\n"), 0o644)
	if infoMap(t, te)["vm_stale"] != "0" {
		t.Error("an up to date VM said stale")
	}

	// What a start would ask.
	exec.Command("git", "-C", proj, "init", "-q").Run()
	exec.Command("git", "-C", proj, "config", "core.hooksPath", ".").Run()
	exec.Command("git", "-C", proj, "config", "core.fsmonitor", "./mon.sh").Run()
	os.WriteFile(filepath.Join(home, ".gitconfig"), nil, 0o644)
	if q := infoMap(t, te)["security_questions"]; q != "hooks,git-config,bare-repo" {
		t.Errorf("questions: %q", q)
	}
	t.Setenv("AGENT_VM_UNSAFE_WRITABLE_GIT", "1")
	if m := infoMap(t, te); m["git_protected"] != "0" || m["security_questions"] != "bare-repo" {
		t.Errorf("opted out: %v", m)
	}

	// A backend that cannot be asked: unknown, never a confident 0.
	te.fake.Err = errors.New("broken")
	m = infoMap(t, te)
	if m["base_exists"] != "unknown" || m["vm_exists"] != "unknown" || m["vm_running"] != "unknown" {
		t.Errorf("failing backend: %v", m)
	}
	if te.run("info", "/no/such/dir") != 1 || !strings.Contains(te.out(), "no such directory") {
		t.Errorf("missing dir: %s", te.out())
	}
}
