//go:build unix

package vm

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func device(p string) (uint64, bool) {
	var st syscall.Stat_t
	if err := syscall.Stat(p, &st); err != nil {
		return 0, false
	}
	return uint64(st.Dev), true
}

// To another file system: copied, then removed (rename cannot).
func TestMoveOldAcrossFS(t *testing.T) {
	ctx := context.Background()
	l := newTestLima(t)
	old := os.Getenv("LIMA_HOME")
	from, _ := device(old)
	other := ""
	for _, d := range []string{"/dev/shm", os.Getenv("AGENT_VM_TEST_OTHER_FS")} {
		if dev, ok := device(d); d != "" && ok && dev != from {
			other = d
			break
		}
	}
	if other == "" {
		t.Skip("no other file system: set AGENT_VM_TEST_OTHER_FS")
	}
	none := []Mount{}
	if err := l.Create(ctx, "agent-vm-p-12345678", "template:debian-13", Settings{CPUs: 1, Mounts: &none}, io.Discard); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(old, "agent-vm-p-12345678")
	os.WriteFile(filepath.Join(dir, "x.tmp"), []byte("x"), 0o644)
	os.Symlink("lima.yaml", filepath.Join(dir, "link"))
	tmp, err := os.MkdirTemp(other, "avm")
	if err != nil {
		t.Skip(err)
	}
	t.Cleanup(func() { os.RemoveAll(tmp) })
	now := filepath.Join(tmp, "lima")
	if err := MoveOld(ctx, old, now, "agent-vm-p-12345678", "p-12345678"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Error("left in the old home")
	}
	moved := filepath.Join(now, "p-12345678")
	if _, err := os.Stat(filepath.Join(moved, "x.tmp")); err == nil {
		t.Error("x.tmp was moved")
	}
	if l, err := os.Readlink(filepath.Join(moved, "link")); err != nil || l != "lima.yaml" {
		t.Errorf("link: %q %v", l, err)
	}
	l2, err := NewLima(now, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if inst, err := l2.Get(ctx, "p-12345678"); err != nil || inst.CPUs != 1 || inst.Status != Stopped {
		t.Fatalf("in the new home: %+v %v", inst, err)
	}
}
