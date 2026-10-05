package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/vm/vmtest"
)

func TestInstall(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	bin := filepath.Join(t.TempDir(), "bin")
	t.Setenv("AGENT_VM_BIN_DIR", bin)
	te := newTestEnv(t, vmtest.New())
	exe, _ := self()
	link := binLink()

	if te.run("install") != 0 || !strings.Contains(te.out(), "Linked "+link+" -> "+exe) || !strings.Contains(te.out(), "is not on your PATH") {
		t.Fatalf("install: %s", te.out())
	}
	if !strings.Contains(te.out(), "agent-vm setup     # build the base VM, once") {
		t.Errorf("next step: %s", te.out())
	}
	if t2, _ := os.Readlink(link); t2 != exe {
		t.Errorf("link: %q", t2)
	}
	if te.run("install") != 0 || !strings.Contains(te.out(), "already linked") {
		t.Errorf("again: %s", te.out())
	}
	// On Windows: the hint is PowerShell's, and PATH is compared as the
	// file system does.
	old := paths.Windows
	paths.Windows = func() bool { return true }
	if te.run("install"); !strings.Contains(te.out(), "Add it from PowerShell") || !strings.Contains(te.out(), "SetEnvironmentVariable('Path', '"+bin+";'") {
		t.Errorf("Windows hint: %s", te.out())
	}
	t.Setenv("PATH", strings.ToUpper(bin)+"/"+string(os.PathListSeparator)+os.Getenv("PATH"))
	if te.run("install"); strings.Contains(te.out(), "not on your PATH") {
		t.Errorf("on PATH, as Windows compares it: %s", te.out())
	}
	paths.Windows = old
	if te.run("install", "x") != 2 {
		t.Error("an argument")
	}
	os.WriteFile(filepath.Join(home, ".zshrc"), []byte("source ~/agent-vm/agent-vm.sh\n"), 0o644)
	if te.run("uninstall") != 0 || !strings.Contains(te.out(), "Removed "+link) || !strings.Contains(te.out(), "still sources agent-vm.sh") {
		t.Errorf("uninstall: %s", te.out())
	}
	if _, err := os.Lstat(link); err == nil {
		t.Error("not removed")
	}
	// Someone else's file: never replaced, never removed.
	os.WriteFile(link, []byte("#!/bin/sh\n"), 0o755)
	if te.run("install") != 1 || !strings.Contains(te.out(), "already exists and is not a link to") {
		t.Errorf("foreign file, install: %s", te.out())
	}
	if te.run("uninstall") != 0 || !strings.Contains(te.out(), "is not a link to this agent-vm: left alone.") {
		t.Errorf("foreign file, uninstall: %s", te.out())
	}
	if b, _ := os.ReadFile(link); string(b) != "#!/bin/sh\n" {
		t.Error("the foreign file changed")
	}
	// A dangling link of someone else's: refused, left.
	os.Remove(link)
	os.Symlink(filepath.Join(home, "gone"), link)
	if te.run("install") != 1 || !strings.Contains(te.out(), "already exists and is not a link to") {
		t.Errorf("dangling link: %s", te.out())
	}
	// 0.2's link to its agent-vm.sh: replaced.
	os.Remove(link)
	os.Symlink(filepath.Join(home, "agent-vm", "agent-vm.sh"), link)
	if te.run("install") != 0 || !strings.Contains(te.out(), "Replacing "+link) {
		t.Errorf("0.2's link: %s", te.out())
	}
	if t2, _ := os.Readlink(link); t2 != exe {
		t.Errorf("link after 0.2's: %q", t2)
	}
	// A copy an earlier install recorded, since updated: replaced, and
	// removed by uninstall.
	os.Remove(link)
	os.WriteFile(link, []byte("old agent-vm"), 0o755)
	os.MkdirAll(string(te.state), 0o755)
	os.WriteFile(te.state.Path(installedCopy), []byte(sha256Of(link)+"\n"), 0o644)
	if te.run("uninstall") != 0 || !strings.Contains(te.out(), "Removed "+link) {
		t.Errorf("recorded copy, uninstall: %s", te.out())
	}
	os.WriteFile(link, []byte("old agent-vm"), 0o755)
	if te.run("install") != 0 || !strings.Contains(te.out(), "Replacing "+link) {
		t.Errorf("recorded copy, install: %s", te.out())
	}
}
