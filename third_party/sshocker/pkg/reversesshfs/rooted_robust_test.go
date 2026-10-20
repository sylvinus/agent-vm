//go:build linux || darwin || windows

package reversesshfs

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/third_party/sftp"
)

// An opened directory renamed, with a symlink to a folder outside the root put in its place,
// must not list the metadata of the files outside. (This holds because Go's File.Readdir stats
// relative to the directory; go.mod requires a Go that does.)
func TestRootedListNoEscape(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("no symlinks")
	}
	_, root, h := setupRootedHandlers(t, false)
	outside := filepath.Join(filepath.Dir(root), "outside")
	if err := os.Mkdir(filepath.Join(root, "d"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, f := range []struct{ path, content string }{
		{filepath.Join(root, "d", "a"), "x"},
		{filepath.Join(root, "d", "b"), "x"},
		{filepath.Join(outside, "a"), strings.Repeat("secret", 100)},
	} {
		if err := os.WriteFile(f.path, []byte(f.content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	l, err := h.Filelist(sftp.NewRequest("List", filepath.Join(root, "d")))
	if err != nil {
		t.Fatal(err)
	}
	defer l.(interface{ Close() error }).Close()
	if err := os.Rename(filepath.Join(root, "d"), filepath.Join(root, "d2")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "d")); err != nil {
		t.Fatal(err)
	}
	ls := make([]os.FileInfo, 10)
	n, _ := l.ListAt(ls, 0)
	for _, fi := range ls[:n] {
		if fi.Size() != 1 {
			t.Errorf("%s: size %d, the metadata of a file outside the root", fi.Name(), fi.Size())
		}
	}
}

// The setuid, setgid and sticky bits are never set by the client.
func TestRootedNoSpecialBits(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("no mode bits")
	}
	c, root, h := setupRootedHandlers(t, false)
	p := func(s string) string { return filepath.Join(root, s) }
	special := func(s string) os.FileMode {
		t.Helper()
		fi, err := os.Stat(p(s))
		if err != nil {
			t.Fatal(err)
		}
		return fi.Mode() & (os.ModeSetuid | os.ModeSetgid | os.ModeSticky)
	}
	const mode = 0o7755
	attrs := []byte{0, 0, byte(mode >> 8), byte(mode & 0xff)}

	r := sftp.NewRequest("Put", p("src/open"))
	r.Flags = 0x2 | 0x8 // write, creat
	r.Attrs = attrs
	f, err := h.openFile(r)
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
	if m := special("src/open"); m != 0 {
		t.Errorf("open: %v", m)
	}

	if err := c.Chmod(p("src/main.go"), mode); err != nil {
		t.Fatal(err)
	}
	if m := special("src/main.go"); m != 0 {
		t.Errorf("chmod: %v", m)
	}

	hf, err := c.OpenFile(p("src/main.go"), os.O_RDWR)
	if err != nil {
		t.Fatal(err)
	}
	if err := hf.Chmod(mode); err != nil {
		t.Fatal(err)
	}
	hf.Close()
	if m := special("src/main.go"); m != 0 {
		t.Errorf("fchmod: %v", m)
	}

	// Mkdir takes its attributes through the sftp package; the handler applies them.
	mk := sftp.NewRequest("Mkdir", p("src/dir"))
	mk.Flags = 0x4 // permissions
	mk.Attrs = append(make([]byte, 0, 4), attrs...)
	if err := h.Filecmd(mk); err != nil {
		t.Fatal(err)
	}
	if m := special("src/dir"); m != 0 {
		t.Errorf("mkdir: %v", m)
	}
}
