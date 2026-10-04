package vm

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/lima-vm/lima/v2/pkg/limatype"

	"github.com/sylvinus/agent-vm/internal/limaembed"
	"github.com/sylvinus/agent-vm/internal/paths"
)

func newTestLima(t *testing.T) *Lima {
	t.Helper()
	home := t.TempDir()
	t.Setenv("LIMA_HOME", home)
	t.Setenv("LIMA_TEMPLATES_PATH", "")
	l, err := NewLima(home, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := l.prepare(); errors.Is(err, limaembed.ErrNoAssets) {
		t.Skip("built without the guest agent: make assets")
	} else if err != nil {
		t.Fatal(err)
	}
	return l
}

// What agent-vm does to a VM without booting it: create, edit its shares,
// clone, delete.
func TestLimaLifecycle(t *testing.T) {
	ctx := context.Background()
	l := newTestLima(t)
	none := []Mount{}
	err := l.Create(ctx, "base", "template:debian-13", Settings{CPUs: 1, MemoryGiB: 2, DiskGiB: 10, Mounts: &none, NoContainerd: true}, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	base, err := l.Get(ctx, "base")
	if err != nil {
		t.Fatal(err)
	}
	if base.Status != Stopped || base.CPUs != 1 || base.Memory != 2<<30 || base.Disk != 10<<30 || len(base.Mounts) != 0 {
		t.Fatalf("created: %+v", base)
	}
	// Lima's containerd stays out: Docker brings its own when chosen.
	if y, _ := os.ReadFile(filepath.Join(os.Getenv("LIMA_HOME"), "base", "lima.yaml")); !strings.Contains(string(y), "containerd:\n  user: false\n  system: false") {
		t.Errorf("containerd in lima.yaml:\n%s", y)
	}

	if err := l.Clone(ctx, "base", "p-12345678"); err != nil {
		t.Fatal(err)
	}
	// A name whose sockets would not fit here, or longer than Lima's 76
	// characters: said so, nothing made.
	long := "agent-vm-" + strings.Repeat("x", 50) + "-12345678"
	if err := l.Clone(ctx, "base", long); !errors.Is(err, ErrNameTooLong) {
		t.Errorf("long name: %v", err)
	}
	if _, err := l.Get(ctx, long); !errors.Is(err, ErrNotFound) {
		t.Errorf("a long name was made: %v", err)
	}
	if err := l.Clone(ctx, "base", long+strings.Repeat("y", 20)); !errors.Is(err, ErrNameTooLong) {
		t.Errorf("name over 76: %v", err)
	}
	// MaxName is exactly what fits here.
	if m := MaxName(os.Getenv("LIMA_HOME")); m < 76 {
		fits := strings.Repeat("n", m-9) + "-12345678"
		if err := l.Clone(ctx, "base", fits); err != nil {
			t.Errorf("a name of MaxName (%d): %v", m, err)
		}
		l.Delete(ctx, fits)
		if err := l.Clone(ctx, "base", "n"+fits); !errors.Is(err, ErrNameTooLong) {
			t.Errorf("a name of MaxName+1: %v", err)
		}
	} else {
		t.Errorf("MaxName = %d: the test's Lima home is long, it should be less than 76", m)
	}

	proj := t.TempDir()
	off := false
	mounts := []Mount{{Location: proj, MountPoint: proj, Writable: true,
		SSHFS: &SSHFS{SFTPDriver: "builtin", Cache: &off, ReadonlyNames: []string{".git", ".hg"}}}}
	rev := ReverseSSHFS
	port := 23456
	if err := l.Edit(ctx, "p-12345678", Settings{Mounts: &mounts, MountType: &rev, SSHLocalPort: &port, CPUs: 2}); err != nil {
		t.Fatal(err)
	}
	p, err := l.Get(ctx, "p-12345678")
	if err != nil {
		t.Fatal(err)
	}
	if p.MountType != ReverseSSHFS || p.SSHLocalPort != 23456 || p.CPUs != 2 || !reflect.DeepEqual(p.Mounts, mounts) {
		t.Fatalf("edited: %+v %+v", p, p.Mounts)
	}

	// A path Lima reads as written; those it would read as another (a Go
	// template, what JSON escapes) refused, nothing written.
	amp := filepath.Join(t.TempDir(), "R&D <x>")
	os.MkdirAll(amp, 0o755)
	withAmp := []Mount{{Location: amp, MountPoint: amp, Writable: true, SSHFS: &SSHFS{SFTPDriver: "builtin", ReadonlyNames: []string{".git", "a&b"}}}}
	if err := l.Edit(ctx, "p-12345678", Settings{Mounts: &withAmp}); err != nil {
		t.Fatal(err)
	}
	if p, _ := l.Get(ctx, "p-12345678"); len(p.Mounts) != 1 || p.Mounts[0].Location != amp || p.Mounts[0].SSHFS.ReadonlyNames[1] != "a&b" {
		t.Errorf("& and <>: %+v", p.Mounts)
	}
	before0, _ := os.ReadFile(filepath.Join(p.Dir, "lima.yaml"))
	for _, name := range []string{"t{{.Home}}", "q{{.Foo}}", "bad\xffbyte", "line\u2028sep"} {
		odd := []Mount{{Location: "/tmp/" + name, MountPoint: "/tmp/x", Writable: true, SSHFS: &SSHFS{SFTPDriver: "builtin", ReadonlyNames: []string{".git"}}}}
		if err := l.Edit(ctx, "p-12345678", Settings{Mounts: &odd}); !errors.Is(err, ErrUnmountable) {
			t.Errorf("%q: %v", name, err)
		}
	}
	if after, _ := os.ReadFile(filepath.Join(p.Dir, "lima.yaml")); string(after) != string(before0) {
		t.Error("a refused share was written")
	}
	if err := l.Edit(ctx, "p-12345678", Settings{Mounts: &mounts}); err != nil {
		t.Fatal(err)
	}

	// Lima refuses a name with a slash: nothing is written.
	yaml := filepath.Join(p.Dir, "lima.yaml")
	before, _ := os.ReadFile(yaml)
	bad := []Mount{{Location: proj, Writable: true, SSHFS: &SSHFS{SFTPDriver: "builtin", ReadonlyNames: []string{"a/b"}}}}
	if err := l.Edit(ctx, "p-12345678", Settings{Mounts: &bad}); err == nil {
		t.Error("a name with a slash was accepted")
	}
	if after, _ := os.ReadFile(yaml); string(after) != string(before) {
		t.Error("a refused edit changed lima.yaml")
	}

	// Lima's override.yaml, with a share lacking the builtin SFTP server the
	// read-only names need: Lima refuses the config, and says why.
	cfg := filepath.Join(os.Getenv("LIMA_HOME"), "_config")
	os.MkdirAll(cfg, 0o755)
	os.WriteFile(filepath.Join(cfg, "override.yaml"), []byte("mounts:\n- location: "+t.TempDir()+"\n  writable: true\n"), 0o644)
	if p, err := l.Get(ctx, "p-12345678"); err != nil || p.Status != Broken || p.ConfigErr == nil || !strings.Contains(p.ConfigErr.Error(), "sftpDriver") {
		t.Errorf("get, refused: %v %+v", err, p)
	}
	// No VM made or started while it is there.
	if err := l.Create(ctx, "q-12345678", "template:debian-13", Settings{Mounts: &none}, io.Discard); !errors.Is(err, ErrLimaOverrides) {
		t.Errorf("create with an override: %v", err)
	}
	if err := l.Start(ctx, "p-12345678", io.Discard); !errors.Is(err, ErrLimaOverrides) {
		t.Errorf("start with an override: %v", err)
	}
	os.Remove(filepath.Join(cfg, "override.yaml"))

	// Back to Lima's default mount type, and no shares.
	def := ""
	if err := l.Edit(ctx, "p-12345678", Settings{Mounts: &none, MountType: &def}); err != nil {
		t.Fatal(err)
	}
	if p, _ := l.Get(ctx, "p-12345678"); len(p.Mounts) != 0 || p.MountType == ReverseSSHFS {
		t.Errorf("reset: %+v", p)
	}

	// Never started with a share not confined to its folder.
	plain := []Mount{{Location: proj, Writable: true}}
	builtin := []Mount{{Location: proj, Writable: true, SSHFS: &SSHFS{SFTPDriver: "builtin"}}}
	for _, set := range []Settings{{Mounts: &plain, MountType: &rev}, {Mounts: &builtin, MountType: &def}} {
		if err := l.Edit(ctx, "p-12345678", set); err != nil {
			t.Fatal(err)
		}
		if err := l.Start(ctx, "p-12345678", io.Discard); !errors.Is(err, ErrUnconfined) {
			t.Errorf("start, %+v: %v", set, err)
		}
	}
	if err := l.Edit(ctx, "p-12345678", Settings{Mounts: &none, MountType: &def}); err != nil {
		t.Fatal(err)
	}

	// _config/base.yaml is not mixed into a new VM.
	cfgDir := filepath.Join(os.Getenv("LIMA_HOME"), "_config")
	os.MkdirAll(cfgDir, 0o755)
	os.WriteFile(filepath.Join(cfgDir, "base.yaml"), []byte("cpus: 7\n"), 0o644)
	if err := l.Create(ctx, "b-12345678", "template:debian-13", Settings{Mounts: &none}, io.Discard); err != nil {
		t.Fatal(err)
	}
	if b, _ := l.Get(ctx, "b-12345678"); b == nil || b.CPUs == 7 {
		t.Errorf("base.yaml mixed in: %+v", b)
	}
	os.Remove(filepath.Join(cfgDir, "base.yaml"))
	l.Delete(ctx, "b-12345678")

	list, err := l.List(ctx)
	if err != nil || len(list) != 2 || list[0].Name != "base" || list[1].Name != "p-12345678" {
		t.Fatalf("list: %v %v", list, err)
	}
	for _, name := range []string{"base", "p-12345678"} {
		if err := l.Delete(ctx, name); err != nil {
			t.Fatal(err)
		}
		if _, err := l.Get(ctx, name); !errors.Is(err, ErrNotFound) {
			t.Errorf("%s after delete: %v", name, err)
		}
	}
}

// Only the builtin SFTP server over reverse-sshfs is confined.
// Lima reads a location back through filepath.Abs, C:\p on Windows: the
// share asked as C:/p, kept.
func TestSharesKeptWindows(t *testing.T) {
	old := paths.Windows
	paths.Windows = func() bool { return true }
	t.Cleanup(func() { paths.Windows = old })
	mp := "/c/p"
	want := []Mount{{Location: "C:/p", MountPoint: mp}}
	if err := sharesKept(want, []limatype.Mount{{Location: `C:\p`, MountPoint: &mp}}); err != nil {
		t.Errorf("C:\\p: %v", err)
	}
	if err := sharesKept(want, []limatype.Mount{{Location: `C:\q`, MountPoint: &mp}}); !errors.Is(err, ErrUnmountable) {
		t.Errorf("C:\\q: %v", err)
	}
}

func TestConfined(t *testing.T) {
	b := &SSHFS{SFTPDriver: "builtin"}
	for _, c := range []struct {
		inst *Instance
		ok   bool
	}{
		{&Instance{}, true},
		{&Instance{MountType: ReverseSSHFS, Mounts: []Mount{{Location: "/p", SSHFS: b}}}, true},
		{&Instance{MountType: ReverseSSHFS, Mounts: []Mount{{Location: "/p", SSHFS: b}, {Location: "/q"}}}, false},
		{&Instance{MountType: ReverseSSHFS, Mounts: []Mount{{Location: "/p", SSHFS: &SSHFS{SFTPDriver: "openssh-sftp-server"}}}}, false},
		{&Instance{MountType: "9p", Mounts: []Mount{{Location: "/p", SSHFS: b}}}, false},
		{&Instance{Mounts: []Mount{{Location: "/p", SSHFS: b}}}, false},
	} {
		if err := Confined(c.inst); (err == nil) != c.ok || err != nil && !errors.Is(err, ErrUnconfined) {
			t.Errorf("%+v: %v", c.inst, err)
		}
	}
}
