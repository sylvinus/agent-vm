package mounts

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/paths"
)

// What Lima cannot mount, or 0.2 refused: said why.
func TestUnmountable(t *testing.T) {
	for dir, want := range map[string]string{
		"/home/me/proj":     "",
		"/home/me/my proj":  "whitespace",
		"/home/me/a\tb":     "whitespace",
		`/home/me/a"b`:      "a quote",
		`/home/me/a\b`:      "a backslash",
		"/home/me/a\x01b":   "a control character",
		"/home/me/été/proj": "",
		"/home/me/R&D":      "",
		"/{{.Home}}":        "a template",
		"/home/me/a\xffb":   "not valid UTF-8",
		"/home/me/a\u2028b": "whitespace",
	} {
		why, bad := Unmountable(dir)
		if bad != (want != "") || !strings.Contains(why, want) {
			t.Errorf("%q: %q %v", dir, why, bad)
		}
	}
}

// A single file given as a symlink (stow's dotfiles) is staged as the file
// it names, in step with it: not as a link pointing out of the staging
// folder, which the VM could not follow.
func TestStageSymlink(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "dotfiles", "gitconfig")
	os.MkdirAll(filepath.Dir(real), 0o755)
	os.WriteFile(real, []byte("v1"), 0o644)
	link := filepath.Join(dir, ".gitconfig")
	os.Symlink(real, link)
	dst := filepath.Join(dir, "stage", "f")
	if !Stage(link, dst, io.Discard) {
		t.Fatal("not staged")
	}
	if fi, err := os.Lstat(dst); err != nil || fi.Mode()&os.ModeSymlink != 0 {
		t.Fatalf("staged as a link: %v %v", fi, err)
	}
	os.WriteFile(real, []byte("v2"), 0o644)
	if b, _ := os.ReadFile(dst); string(b) != "v2" {
		t.Errorf("not in step with the file: %q", b)
	}
}

// Where the file system ignores case, the home folder in other capitals is
// the home folder.
func TestUnsafeLocationNoCase(t *testing.T) {
	s := newSandbox(t)
	refs := Refs(s.home, filepath.Join(s.root, "self"), s.state, filepath.Join(s.state, "lima"))
	upper := strings.ToUpper(s.home)
	// On a file system that ignores case the uppercased home is the
	// home folder, and refused below; here case matters.
	if !paths.NoCase() {
		if _, bad := UnsafeLocation(upper, refs); bad {
			t.Error("refused where case matters")
		}
	}
	old := paths.NoCase
	paths.NoCase = func() bool { return true }
	t.Cleanup(func() { paths.NoCase = old })
	refs = Refs(s.home, filepath.Join(s.root, "self"), s.state, filepath.Join(s.state, "lima"))
	if why, bad := UnsafeLocation(upper, refs); !bad || !strings.Contains(why, "your home directory") {
		t.Errorf("home in capitals: %q %v", why, bad)
	}
	if why, bad := UnsafeLocation(strings.ToUpper(s.state)+"/x", refs); !bad {
		t.Errorf("inside the state dir in capitals: %q %v", why, bad)
	}
}
