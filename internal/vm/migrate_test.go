package vm

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMoveOld(t *testing.T) {
	ctx := context.Background()
	l := newTestLima(t)
	old := os.Getenv("LIMA_HOME")
	off := false
	proj := t.TempDir()
	mounts := []Mount{{Location: proj, MountPoint: proj, Writable: true, SSHFS: &SSHFS{SFTPDriver: "builtin", Cache: &off, ReadonlyNames: []string{".git", ".hg"}}}}
	rev := ReverseSSHFS
	if err := l.Create(ctx, "agent-vm-p-12345678", "template:debian-13", Settings{CPUs: 1, Mounts: &mounts, MountType: &rev}, io.Discard); err != nil {
		t.Fatal(err)
	}
	none := []Mount{}
	if err := l.Create(ctx, "other", "template:debian-13", Settings{CPUs: 1, Mounts: &none}, io.Discard); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(old, "agent-vm-p-12345678")
	for _, f := range []string{"ha.sock", "stale.pid", "x.tmp", "protected", "vz-identifier"} {
		os.WriteFile(filepath.Join(dir, f), []byte("x"), 0o644)
	}
	// A hostagent's pid that is not running: not running.
	found, err := FindOld(old, "agent-vm-")
	if err != nil || len(found) != 1 || found[0].Name != "agent-vm-p-12345678" || found[0].Running {
		t.Fatalf("FindOld: %+v %v", found, err)
	}

	now := filepath.Join(t.TempDir(), "lima")
	if err := MoveOld(ctx, old, now, "agent-vm-p-12345678", "p-12345678"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Error("left in the old home")
	}
	moved := filepath.Join(now, "p-12345678")
	for _, f := range []string{"ha.sock", "stale.pid", "x.tmp", "protected"} {
		if _, err := os.Stat(filepath.Join(moved, f)); err == nil {
			t.Errorf("%s was moved", f)
		}
	}
	if b, err := os.ReadFile(filepath.Join(moved, "vz-identifier")); err != nil || len(b) != 0 {
		t.Errorf("vz-identifier: %q %v", b, err)
	}
	if _, err := os.Stat(filepath.Join(old, "other")); err != nil {
		t.Error("a VM that is not agent-vm's was touched")
	}

	l2, err := NewLima(now, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	inst, err := l2.Get(ctx, "p-12345678")
	if err != nil || inst.Name != "p-12345678" || inst.MountType != ReverseSSHFS || len(inst.Mounts) != 1 || inst.Mounts[0].Location != proj || inst.Status != Stopped {
		t.Fatalf("in the new home: %+v %v", inst, err)
	}

	// Too long for the sockets at the new place: refused, nothing moved.
	long := filepath.Join(t.TempDir(), strings.Repeat("d", 90))
	if err := MoveOld(ctx, now, long, "p-12345678", "p-12345678"); err == nil || !strings.Contains(err.Error(), "too long") {
		t.Errorf("long path: %v", err)
	}
	if _, err := os.Stat(moved); err != nil {
		t.Error("moved although refused")
	}
}
