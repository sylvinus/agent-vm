package state

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/paths"
)

func TestDefault(t *testing.T) {
	elsewhere := t.TempDir()
	t.Setenv("AGENT_VM_STATE_DIR", elsewhere)
	if d, err := Default(); err != nil || string(d) != paths.Host(elsewhere) {
		t.Errorf("override: %q, %v", d, err)
	}
	home := t.TempDir()
	t.Setenv("AGENT_VM_STATE_DIR", "")
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	if d, err := Default(); err != nil || string(d) != paths.Host(filepath.Join(home, ".agent-vm")) {
		t.Errorf("default: %q, %v", d, err)
	}
}

// A relative folder is made absolute where it is read: the checks that keep
// shares away from the state compare real locations.
func TestDefaultRelative(t *testing.T) {
	wd := t.TempDir()
	t.Chdir(wd)
	t.Setenv("AGENT_VM_STATE_DIR", "rel/state")
	d, err := Default()
	if err != nil || !filepath.IsAbs(string(d)) || filepath.Base(string(d)) != "state" {
		t.Fatalf("relative: %q, %v", d, err)
	}
	real, _ := filepath.EvalSymlinks(wd)
	got, _ := filepath.EvalSymlinks(filepath.Dir(filepath.Dir(string(d))))
	if got != real {
		t.Errorf("relative to %q, want %q", got, real)
	}
}

func TestReadWrite(t *testing.T) {
	d := Dir(filepath.Join(t.TempDir(), "state"))
	if d.Read("x") != "" {
		t.Error("read of nothing")
	}
	if err := d.Write("x", []byte("one\n")); err != nil {
		t.Fatal(err)
	}
	if err := d.Write("x", []byte("two\n")); err != nil {
		t.Fatal(err)
	}
	if d.Read("x") != "two" {
		t.Errorf("Read = %q", d.Read("x"))
	}
	ents, _ := os.ReadDir(string(d))
	for _, e := range ents {
		if e.Name() != "x" {
			t.Errorf("left behind: %s", e.Name())
		}
	}
	// The folder is not there and cannot be made: an error, not a silent skip.
	blocker := filepath.Join(t.TempDir(), "file")
	os.WriteFile(blocker, nil, 0o644)
	if err := Dir(filepath.Join(blocker, "sub")).Write("x", nil); err == nil {
		t.Error("written under a file")
	}
}

func TestLayout(t *testing.T) {
	d := Dir("/s")
	for got, want := range map[string]string{
		d.VMs():             "/s/vms",
		d.VM("a"):           "/s/vms/a",
		d.Lima("a"):         "/s/vms/a/lima",
		d.FileMounts("a"):   "/s/vms/a/file-mounts",
		d.Policy("a"):       "/s/vms/a/policy.json",
		d.LimaHome():        "/s/lima",
		d.Path("locks/vm1"): "/s/locks/vm1",
	} {
		if filepath.ToSlash(strings.TrimPrefix(got, filepath.VolumeName(got))) != want {
			t.Errorf("%q, want %q", got, want)
		}
	}
}

func TestMeta(t *testing.T) {
	d := Dir(t.TempDir())
	if m, err := d.Meta("a"); err != nil || m.Base != nil || m.Schema != 0 {
		t.Errorf("no file: %+v, %v", m, err)
	}
	err := d.UpdateMeta("a", func(m *Metadata) {
		m.Base = &Base{Name: "base", Built: 1760000000, BuiltBy: "0.4.0"}
		m.Term = "xterm"
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := d.UpdateMeta("a", func(m *Metadata) { m.FileMounts = []string{"x|y|z|w"} }); err != nil {
		t.Fatal(err)
	}
	m, err := d.Meta("a")
	if err != nil || m.Schema != 1 || m.Base.BuiltBy != "0.4.0" || m.Term != "xterm" || len(m.FileMounts) != 1 {
		t.Errorf("read back: %+v, %v", m, err)
	}
	if got := d.BaseLabel("a"); got != "0.4.0 2025-10-09" {
		t.Errorf("label %q", got)
	}
	// Nothing left beside it, whatever the writes.
	ents, _ := os.ReadDir(d.VM("a"))
	if len(ents) != 1 || ents[0].Name() != MetaFile {
		t.Errorf("folder: %v", ents)
	}

	// An unreadable file: nothing known, said by the error.
	os.WriteFile(filepath.Join(d.VM("a"), MetaFile), []byte("{"), 0o644)
	if m, err := d.Meta("a"); err == nil || !strings.Contains(err.Error(), MetaFile) || m.Base != nil {
		t.Errorf("corrupt: %+v, %v", m, err)
	}
	if d.Known("a").Base != nil || d.BaseLabel("a") != "0.1.0 -" || d.BaseReady("a") {
		t.Error("corrupt file known")
	}
	os.WriteFile(filepath.Join(d.VM("a"), MetaFile), []byte(`{"schema": 2}`), 0o644)
	if _, err := d.Meta("a"); err == nil || !strings.Contains(err.Error(), "newer") {
		t.Errorf("newer schema: %v", err)
	}
	// A write replaces what cannot be read.
	if err := d.UpdateMeta("a", func(m *Metadata) { m.Term = "t" }); err != nil || d.Known("a").Term != "t" {
		t.Errorf("replace: %v", err)
	}
}

func TestBaseReady(t *testing.T) {
	d := Dir(t.TempDir())
	if d.BaseReady("base") {
		t.Error("ready with nothing")
	}
	d.UpdateMeta("base", func(m *Metadata) { m.Base = &Base{Name: "base"} })
	if d.BaseReady("base") {
		t.Error("ready with no build time")
	}
	d.UpdateMeta("base", func(m *Metadata) { m.Base.Built = 5 })
	if !d.BaseReady("base") {
		t.Error("not ready")
	}
}

func TestForgetNames(t *testing.T) {
	d := Dir(t.TempDir())
	d.UpdateMeta("a", func(m *Metadata) { m.Term = "x" })
	os.MkdirAll(d.Lima("b"), 0o755)
	os.WriteFile(filepath.Join(d.Lima("b"), "lima.yaml"), nil, 0o644)
	os.WriteFile(filepath.Join(d.VMs(), "file"), nil, 0o644)
	if got := strings.Join(d.Names(), " "); got != "a b" {
		t.Errorf("names %q", got)
	}
	if d.HasLima("a") || !d.HasLima("b") {
		t.Error("HasLima")
	}
	if err := d.Forget("a"); err != nil {
		t.Fatal(err)
	}
	if err := d.Forget("a"); err != nil {
		t.Errorf("twice: %v", err)
	}
	if got := strings.Join(d.Names(), " "); got != "b" {
		t.Errorf("after forget %q", got)
	}
}
