package mounts

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/bashref"
	"github.com/sylvinus/agent-vm/internal/paths"
)

// sandbox: a home with a project in it, and folders around.
type sandbox struct {
	root, home, proj, state string
}

func newSandbox(t *testing.T) sandbox {
	t.Helper()
	root, _ := filepath.EvalSymlinks(t.TempDir())
	// Host-spelled, as the callers pass their folders: mixed separators
	// never compare on Windows.
	root = paths.Host(root)
	s := sandbox{root: root, home: root + "/home", proj: root + "/home/proj"}
	s.state = s.home + "/.agent-vm"
	for _, d := range []string{s.proj + "/sub", s.state, root + "/data/a", root + "/data/b", root + "/bare.git/objects", root + "/bare.git/refs", root + "/repo/.git/hooks", s.home + "/.lima"} {
		os.MkdirAll(d, 0o755)
	}
	os.WriteFile(root+"/bare.git/HEAD", []byte("ref: refs/heads/main\n"), 0o644)
	os.WriteFile(root+"/data/file.txt", []byte("x"), 0o644)
	os.Symlink(root+"/data/a", root+"/alink")
	return s
}

func (s sandbox) refs() []Ref {
	return Refs(s.home, bashref.Root(), s.state, s.home+"/.lima")
}

func (s sandbox) bash(t *testing.T, snippet string, args ...string) bashref.Result {
	return bashref.Script(t, "", []string{"HOME=" + s.home, "AGENT_VM_STATE_DIR=" + s.state}, snippet, args...)
}

func TestEntriesBash(t *testing.T) {
	s := newSandbox(t)
	lines := []string{
		"# a comment",
		"",
		"   " + s.root + "/data/a   ",
		s.root + "/data/a:/mnt/a:rw",
		s.root + "/data/b:/mnt/b:ro # trailing",
		s.root + "/data/b:/mnt/a:rw",
		s.root + "/data/a:/mnt/x/../y/:rw",
		s.root + "/data/file.txt:/etc/f",
		s.root + "/missing:/mnt/m",
		"~/proj:/mnt/p",
		s.home + ":/mnt/h",
		s.state + ":/mnt/s",
		s.root + "/bare.git:/mnt/bare:rw",
		s.root + "/bare.git:/mnt/bare2:ro",
		s.root + "/repo/.git/hooks:/mnt/hooks:rw",
		s.root + "/data/a:" + filepath.Dir(s.proj) + ":ro",
		s.root + "/data/a:" + s.proj + "/inside:ro",
		s.root + "/data/a:rel/dir:ro",
		s.root + "/data/a:/mnt/f1:rw:" + s.proj,
		s.root + "/data/b:/mnt/f2:rw:/other/*",
		s.root + "/data/b:/mnt/f3:rw:~/pr*",
		s.root + "/data/b:/mnt/f4:rw:relative/p",
		s.root + "/data/b:/mnt/f5:rw:",
		s.root + "/data/b:/mnt/f6:/p",
		s.root + "/data/b:/mnt/f7:rw:/p:x",
		s.root + "/data/a:/mnt/q\"uote",
		s.root + "/data/a:/mnt/tab\there",
		"crlf:" + s.root + "/data/b:/mnt/crlf\r",
		s.root + "/alink:/mnt/alink:rw",
	}
	content := strings.Join(lines, "\n") + "\n"
	os.WriteFile(filepath.Join(s.state, "volumes"), []byte(content), 0o644)

	var warn bytes.Buffer
	got := Entries(filepath.Join(s.state, "volumes"), s.proj, s.home, s.refs(), &warn)
	var b strings.Builder
	for _, e := range got {
		fmt.Fprintf(&b, "%s|%s|%s|%s\n", e.Src, e.Dst, e.Mode, e.Line)
	}
	r := s.bash(t, `_agent_vm_volume_entries "$1"`, s.proj)
	if b.String() != r.Stdout {
		t.Errorf("entries:\n%s\nbash:\n%s", b.String(), r.Stdout)
	}
	if warn.String() != r.Stderr {
		t.Errorf("warnings:\n%s\nbash:\n%s", warn.String(), r.Stderr)
	}
}

func TestMatchesBash(t *testing.T) {
	s := newSandbox(t)
	for _, f := range []string{s.proj, s.proj + "/", s.home + "/*", "~/proj", "~", "~/p?oj", "~/[pq]roj", "~/[!p]roj", "/*", "/", "relative", "~other/proj", s.home + "/*/sub", "~/pro[", `~/pro\j`} {
		var warn bytes.Buffer
		got := Matches(f, s.proj, s.home, &warn)
		r := s.bash(t, `_agent_vm_volume_matches "$1" "$2"`, f, s.proj)
		if got != (r.Code == 0) || warn.String() != r.Stderr {
			t.Errorf("Matches(%q) = %v %q, bash %d %q", f, got, warn.String(), r.Code, r.Stderr)
		}
	}
}

func TestUnsafeProjectBash(t *testing.T) {
	s := newSandbox(t)
	for _, d := range []string{s.proj, s.home, s.root, s.state, s.state + "/x", bashref.Root(), bashref.Root() + "/lib", s.home + "/.lima",
		s.root + "/bare.git", s.root + "/bare.git/objects", s.root + "/repo/.git", s.root + "/repo/.GIT", s.root + "/repo/.git/hooks", s.root + "/repo", s.root + "/alink"} {
		os.MkdirAll(d, 0o755)
		why, bad := UnsafeProject(d, s.refs())
		r := s.bash(t, `_agent_vm_unsafe_project "$1"`, d)
		if bad != (r.Code == 0) || (bad && why+"\n" != r.Stdout) {
			t.Errorf("UnsafeProject(%q) = %q %v, bash %q %d", d, why, bad, r.Stdout, r.Code)
		}
	}
}

func TestProjectMountpointBash(t *testing.T) {
	for _, c := range []struct{ rel, src string }{
		{"sub/new", "dir"}, {"deep/a/b", "dir"}, {"f.txt", "file"}, {"../out", "dir"}, {".", "dir"}, {"link/x", "dir"},
		{"sub", "file"}, {"plainfile", "dir"}, {"./sub/./x/", "dir"},
	} {
		var gs, bs sandbox
		for _, s := range []*sandbox{&gs, &bs} {
			*s = newSandbox(t)
			os.Symlink(s.root+"/data/a", s.proj+"/link")
			os.WriteFile(s.proj+"/plainfile", nil, 0o644)
		}
		src := func(s sandbox) string {
			if c.src == "dir" {
				return s.root + "/data/a"
			}
			return s.root + "/data/file.txt"
		}
		var warn bytes.Buffer
		p, ok := ProjectMountpoint(gs.proj, c.rel, src(gs), &warn)
		r := bs.bash(t, `_agent_vm_project_mountpoint "$@"`, bs.proj, c.rel, src(bs))
		norm := func(s, root string) string { return strings.ReplaceAll(s, root, "ROOT") }
		if ok != (r.Code == 0) || (ok && norm(p, gs.root)+"\n" != norm(r.Stdout, bs.root)) || norm(warn.String(), gs.root) != norm(r.Stderr, bs.root) {
			t.Errorf("ProjectMountpoint(%q, %s) = %q %v %q, bash %q %d %q", c.rel, c.src, p, ok, warn.String(), r.Stdout, r.Code, r.Stderr)
		}
		if _, err := os.Stat(gs.root + "/data/a/x"); err == nil {
			t.Errorf("%q made something through the link", c.rel)
		}
	}
}
