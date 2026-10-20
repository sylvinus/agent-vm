package state

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// legacyVM makes 0.3.0's VM name: lima/<name>/lima.yaml and a marker per fact.
func legacyVM(t *testing.T, d Dir, name string, markers map[string]string) {
	t.Helper()
	dir := filepath.Join(d.LimaHome(), name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, "lima.yaml"), []byte("cpus: 2\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "diffdisk"), []byte("disk of "+name), 0o644)
	for kind, content := range markers {
		if err := d.Write(kind+name, []byte(content)); err != nil {
			t.Fatal(err)
		}
	}
}

func TestMigrateLayout(t *testing.T) {
	d := Dir(t.TempDir())
	legacyVM(t, d, "base", nil)
	d.Write(legacyBaseVersion, []byte("1760000000\n"))
	d.Write(legacyBaseBuiltBy, []byte("0.3.0\n"))
	legacyVM(t, d, "proj-1234abcd", map[string]string{
		legacyVersionOf: "1750000000\n", legacyBuiltByOf: "0.2.1\n", legacyTermOf: "xterm-ghostty\n",
		legacyFileMountsOf: "/h/f|/s/file-mounts/proj-1234abcd/0/f|/tmp/.agent-vm-file-mounts/0/f|/h/f\n",
		legacyPolicyOf:     "abc\n", legacyMountsOf: "x\n", legacyCacheOf: "y\n",
	})
	// 0.1.0's VM, migrated in place by 0.2: no built-by, but sshfs.
	legacyVM(t, d, "old-0000aaaa", map[string]string{legacySSHFSOf: "1\n", legacyVersionOf: "1740000000\n"})
	// A run that did not finish, and one with no pid.
	legacyVM(t, d, "x-scratch-0000aaaa", map[string]string{legacyScratchOf: "4242\n"})
	legacyVM(t, d, "y-scratch-0000bbbb", map[string]string{legacyScratchOf: "?\n"})
	// Markers of no VM, and staged files of VMs there are, and are not.
	d.Write(legacyTermOf+"gone", []byte("t\n"))
	d.Write(legacyVersionOf+"gone", []byte("1\n"))
	os.MkdirAll(d.Path("file-mounts/proj-1234abcd/0"), 0o755)
	os.WriteFile(d.Path("file-mounts/proj-1234abcd/0/f"), []byte("staged"), 0o644)
	os.MkdirAll(d.Path("file-mounts/gone/0"), 0o755)
	// What is not agent-vm's stays.
	os.MkdirAll(filepath.Join(d.LimaHome(), "_config"), 0o755)
	d.Write(".agent-vm-lima-migrated", []byte("x\n"))
	d.Write("env", []byte("A=1\n"))
	if !d.PendingLayout(d.LimaHome()) {
		t.Fatal("nothing pending")
	}

	var log bytes.Buffer
	if err := d.MigrateLayout(LayoutOps{Home: d.LimaHome(), Template: "base", Log: &log}); err != nil {
		t.Fatalf("%v\n%s", err, log.String())
	}
	if d.PendingLayout(d.LimaHome()) {
		ents, _ := os.ReadDir(string(d))
		t.Errorf("pending after: %v", ents)
	}

	if b, _ := os.ReadFile(filepath.Join(d.Lima("proj-1234abcd"), "diffdisk")); string(b) != "disk of proj-1234abcd" {
		t.Errorf("disk: %q", b)
	}
	if _, err := os.Stat(filepath.Join(d.LimaHome(), "proj-1234abcd")); err == nil {
		t.Error("left in lima/")
	}
	if _, err := os.Stat(filepath.Join(d.LimaHome(), "_config")); err != nil {
		t.Error("Lima's own config moved")
	}

	m := d.Known("proj-1234abcd")
	if m.Schema != 1 || m.Base == nil || *m.Base != (Base{Name: "base", Built: 1750000000, BuiltBy: "0.2.1"}) || m.Term != "xterm-ghostty" ||
		len(m.FileMounts) != 1 || !strings.HasPrefix(m.FileMounts[0], "/h/f|") {
		t.Errorf("project VM: %+v", m)
	}
	if b := d.Known("base").Base; b == nil || *b != (Base{Name: "base", Built: 1760000000, BuiltBy: "0.3.0"}) || !d.BaseReady("base") {
		t.Errorf("base: %+v", b)
	}
	if b := d.Known("old-0000aaaa").Base; b == nil || b.BuiltBy != "0.1.0" || b.Built != 1740000000 {
		t.Errorf("0.1.0 VM: %+v", b)
	}
	if d.Known("x-scratch-0000aaaa").ScratchPID != 4242 || d.Known("y-scratch-0000bbbb").ScratchPID != -1 {
		t.Error("scratch records")
	}
	if b, _ := os.ReadFile(filepath.Join(d.FileMounts("proj-1234abcd"), "0", "f")); string(b) != "staged" {
		t.Errorf("staged files: %q", b)
	}

	// Gone: the markers, the staged files of no VM, the old file-mounts.
	ents, _ := os.ReadDir(string(d))
	var left []string
	for _, e := range ents {
		left = append(left, e.Name())
	}
	if got := strings.Join(left, " "); got != ".agent-vm-lima-migrated env lima vms" {
		t.Errorf("state folder: %s", got)
	}
	if _, err := os.Stat(d.VM("gone")); err == nil {
		t.Error("a folder for a VM that is not there")
	}

	// Done once: a second run changes nothing.
	log.Reset()
	if err := d.MigrateLayout(LayoutOps{Home: d.LimaHome(), Template: "base", Log: &log}); err != nil || log.Len() != 0 {
		t.Errorf("second run: %v %q", err, log.String())
	}
}

// A running VM cannot move: it waits, with its markers, unless it can be
// stopped.
func TestMigrateLayoutRunning(t *testing.T) {
	d := Dir(t.TempDir())
	legacyVM(t, d, "up-1234abcd", map[string]string{legacyBuiltByOf: "0.3.0\n", legacyVersionOf: "5\n"})
	legacyVM(t, d, "down-1234abcd", map[string]string{legacyBuiltByOf: "0.3.0\n", legacyVersionOf: "5\n"})
	running := func(n string) bool { return n == "up-1234abcd" }
	var log bytes.Buffer

	// No one to ask.
	if err := d.MigrateLayout(LayoutOps{Home: d.LimaHome(), Template: "base", Running: running, Log: &log}); err != nil {
		t.Fatal(err)
	}
	if !d.HasLima("down-1234abcd") || d.HasLima("up-1234abcd") || !strings.Contains(log.String(), "up-1234abcd is running") {
		t.Errorf("not asked: %q", log.String())
	}
	if _, err := os.Stat(d.Path(legacyBuiltByOf + "up-1234abcd")); err != nil {
		t.Error("the markers of the VM left behind went")
	}
	if !d.PendingLayout(d.LimaHome()) {
		t.Error("nothing pending, a VM is left")
	}

	// Asked, and no.
	if err := d.MigrateLayout(LayoutOps{Home: d.LimaHome(), Template: "base", Running: running, Ask: func([]string) bool { return false }}); err != nil || d.HasLima("up-1234abcd") {
		t.Errorf("declined: %v", err)
	}

	// Asked, yes, but it does not stop.
	log.Reset()
	boom := errors.New("boom")
	err := d.MigrateLayout(LayoutOps{Home: d.LimaHome(), Template: "base", Running: running, Ask: func([]string) bool { return true }, Stop: func(string) error { return boom }, Log: &log})
	if err != nil || d.HasLima("up-1234abcd") || !strings.Contains(log.String(), "boom") {
		t.Errorf("not stopped: %v %q", err, log.String())
	}

	// Asked, yes, stopped.
	var stopped []string
	err = d.MigrateLayout(LayoutOps{Home: d.LimaHome(), Template: "base", Running: running, Ask: func(r []string) bool { return len(r) == 1 },
		Stop: func(n string) error { stopped = append(stopped, n); return nil }})
	if err != nil || !d.HasLima("up-1234abcd") || strings.Join(stopped, ",") != "up-1234abcd" {
		t.Errorf("stopped: %v %v", err, stopped)
	}
	if d.Known("up-1234abcd").Base == nil || d.PendingLayout(d.LimaHome()) {
		t.Error("metadata of the moved VM, or still pending")
	}
}

// Interrupted after the rename: the markers are still there, the VM is
// moved, and the next run finishes.
func TestMigrateLayoutResumes(t *testing.T) {
	d := Dir(t.TempDir())
	legacyVM(t, d, "p-1234abcd", map[string]string{legacyBuiltByOf: "0.3.0\n", legacyVersionOf: "7\n"})
	if err := os.MkdirAll(d.VM("p-1234abcd"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(filepath.Join(d.LimaHome(), "p-1234abcd"), d.Lima("p-1234abcd")); err != nil {
		t.Fatal(err)
	}
	if !d.PendingLayout(d.LimaHome()) {
		t.Fatal("markers not pending")
	}
	if err := d.MigrateLayout(LayoutOps{Home: d.LimaHome(), Template: "base"}); err != nil {
		t.Fatal(err)
	}
	if b := d.Known("p-1234abcd").Base; b == nil || b.Built != 7 || d.PendingLayout(d.LimaHome()) {
		t.Errorf("resumed: %+v", b)
	}
}

// A VM in both places is not touched.
func TestMigrateLayoutConflict(t *testing.T) {
	d := Dir(t.TempDir())
	legacyVM(t, d, "p-1234abcd", map[string]string{legacyVersionOf: "7\n"})
	os.MkdirAll(d.Lima("p-1234abcd"), 0o755)
	os.WriteFile(filepath.Join(d.Lima("p-1234abcd"), "lima.yaml"), []byte("new"), 0o644)
	var log bytes.Buffer
	err := d.MigrateLayout(LayoutOps{Home: d.LimaHome(), Template: "base", Log: &log})
	if err == nil || !strings.Contains(err.Error(), "p-1234abcd") || !strings.Contains(log.String(), "exists already") {
		t.Errorf("%v %q", err, log.String())
	}
	if b, _ := os.ReadFile(filepath.Join(d.Lima("p-1234abcd"), "lima.yaml")); string(b) != "new" {
		t.Error("the VM there was overwritten")
	}
	if !d.HasLima("p-1234abcd") {
		t.Error("lost")
	}
	if _, err := os.Stat(filepath.Join(d.LimaHome(), "p-1234abcd", "lima.yaml")); err != nil {
		t.Error("the old one went")
	}
}

// 0.2's migration names markers as 0.3.0 did; they follow the VM before
// this one runs.
func TestLegacyRename(t *testing.T) {
	d := Dir(t.TempDir())
	for _, kind := range legacyKinds {
		d.Write(kind+"agent-vm-a", []byte("1\n"))
	}
	os.MkdirAll(d.Path("file-mounts/agent-vm-a"), 0o755)
	if err := d.LegacyRename("agent-vm-a", "a"); err != nil {
		t.Fatal(err)
	}
	for _, kind := range legacyKinds {
		if d.Read(kind+"a") != "1" || d.Read(kind+"agent-vm-a") != "" {
			t.Errorf("%s did not follow", kind)
		}
	}
	if _, err := os.Stat(d.Path("file-mounts/a")); err != nil {
		t.Error("staged files did not follow")
	}
}

// sshfs-cache-x is the cache record of x, unless a VM is named cache-x.
func TestLegacyMarkerAmbiguity(t *testing.T) {
	d := Dir(t.TempDir())
	d.Write(legacyCacheOf+"x", []byte("1\n"))
	got := d.legacyMarkers("base", func(string) bool { return false })
	if got["x"][legacyCacheOf] == "" {
		t.Errorf("no VM named cache-x: %v", got)
	}
	got = d.legacyMarkers("base", func(n string) bool { return n == "cache-x" })
	if got["cache-x"][legacySSHFSOf] == "" || got["x"] != nil {
		t.Errorf("a VM named cache-x: %v", got)
	}
}
