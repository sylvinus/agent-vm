package mounts

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/paths"
)

// Any volumes file: no panic, and every entry kept is one that may be
// mounted: an existing source, a mode, a place that does not cover the
// project, each place once.
func FuzzEntries(f *testing.F) {
	// ROOT is the sandbox's folder: data/a, data/b, data/file.txt, alink,
	// repo/.git, bare.git, home/proj.
	for _, s := range []string{
		"ROOT/data/a:/mnt/data:rw\n",
		"ROOT/data/b:rel/dir:ro:ROOT/home/*\n",
		"ROOT/data/a:/mnt/a\nROOT/data/b:/mnt/a\n",
		"ROOT/data/a:ROOT/home:rw\n",
		"ROOT/data/a:ROOT/home/proj/../proj:rw\n",
		"ROOT/data/a:..:rw\n",
		"ROOT/data/file.txt:.claude.json:rw\n",
		"ROOT/alink:/mnt/l:rw\n",
		"ROOT/repo/.git:/mnt/g:rw\n",
		"ROOT/data/a:/mnt/x:ro:[\n",
		"# c\n  ROOT/data/b  \r\n",
		"ROOT:/mnt/r:ro\n",
	} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, content string) {
		s := newSandbox(t)
		content = strings.ReplaceAll(content, "ROOT", s.root)
		file := filepath.Join(s.state, "volumes")
		if err := os.WriteFile(file, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		refs := Refs(s.home, filepath.Join(s.root, "self"), s.state, filepath.Join(s.state, "lima"))
		seen := map[string]bool{}
		for _, e := range Entries(file, s.proj, s.home, refs, io.Discard) {
			if _, err := os.Stat(e.Src); err != nil {
				t.Fatalf("%q: source %q does not exist", content, e.Src)
			}
			if e.Mode != "ro" && e.Mode != "rw" {
				t.Fatalf("%q: mode %q", content, e.Mode)
			}
			if _, bad := UnsafeLocation(e.Src, refs); bad {
				t.Fatalf("%q: unsafe source %q kept", content, e.Src)
			}
			mp := e.Dst
			if mp == "" {
				mp = e.Src
			}
			if !strings.HasPrefix(mp, "/") {
				mp = s.proj + "/" + mp
			}
			mp = paths.Join("/", mp)
			if _, in := paths.In(s.proj, mp); in {
				t.Fatalf("%q: %q is mounted at %q, which covers the project", content, e.Src, mp)
			}
			if seen[mp] {
				t.Fatalf("%q: two entries at %q", content, mp)
			}
			seen[mp] = true
		}
	})
}

// A filter with non-ASCII characters matches as written (0.3 took each byte
// of é for a character before this test). A backslash escapes elsewhere,
// and separates on Windows: both spellings, on every host.
func TestMatchesNonASCII(t *testing.T) {
	for _, win := range []bool{false, true} {
		old := paths.Windows
		paths.Windows = func() bool { return win }
		wantEscape := !win
		for _, c := range []struct {
			filter, dir string
			want        bool
		}{
			{"/home/café", "/home/café", true},
			{"/home/caf?", "/home/café", true},
			{"/home/caf\\é/*", "/home/café/x", wantEscape},
			{"/home/café", "/home/cafe", false},
		} {
			if got := Matches(c.filter, c.dir, "/home", io.Discard); got != c.want {
				t.Errorf("windows=%v Matches(%q, %q) = %v", win, c.filter, c.dir, got)
			}
		}
		paths.Windows = old
	}
}

// Any project filter: no panic, and a filter without pattern characters
// matches the folder it names.
func FuzzMatches(f *testing.F) {
	for _, s := range []string{"/home/*", "~/p", "[", "[!a]*", "[]]", "\\", "a\\*", "/x[a-", "/**/y"} {
		f.Add(s, "/home/u/proj")
	}
	f.Fuzz(func(t *testing.T, filter, dir string) {
		Matches(filter, dir, "/home/u", io.Discard)
		if strings.HasPrefix(dir, "/") && !strings.ContainsAny(dir, "*?[\\") && dir != "/" && !strings.HasSuffix(dir, "/") {
			if !Matches(dir, dir, "/home/u", io.Discard) {
				t.Fatalf("%q does not match itself", dir)
			}
		}
	})
}
