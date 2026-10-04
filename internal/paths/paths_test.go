package paths

import (
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/bashref"
)

// windows makes the host a Windows one for the test.
func windows(t *testing.T, on bool) {
	old := Windows
	Windows = func() bool { return on }
	t.Cleanup(func() { Windows = old })
}

// On Windows, a drive is the root: ".." stops there, and C:/x is absolute.
func TestWindowsPaths(t *testing.T) {
	windows(t, true)
	for _, c := range [][3]string{
		{"C:/Users/me", "proj", "C:/Users/me/proj"},
		{"C:/Users/me", "../../../x", "C:/x"},
		{"C:/", "..", "C:/"},
		{"C:/Users", "D:/data", "D:/data"},
		{"C:/Users", "/x", "/x"},
		{"c:/a/", "./b/../c", "c:/a/c"},
	} {
		if got := Abs(c[0], c[1]); got != c[2] {
			t.Errorf("Abs(%q, %q) = %q, want %q", c[0], c[1], got, c[2])
		}
	}
	for p, want := range map[string]bool{"C:/x": true, "c:/": true, "/x": true, "C:x": false, "x": false, "1:/x": false} {
		if IsAbs(p) != want {
			t.Errorf("IsAbs(%q) != %v", p, want)
		}
	}
	for p, want := range map[string]string{`C:\Users\me`: "/c/Users/me", "D:/x/y": "/d/x/y", "C:/": "/c/", "/tmp": "/tmp"} {
		if got := Guest(p); got != want {
			t.Errorf("Guest(%q) = %q, want %q", p, got, want)
		}
	}
	for p, want := range map[string]string{"/c/Users/me": "C:/Users/me", "/d": "D:/", "/c/a/../b": "C:/b", "/cd/x": "/cd/x", "/1/x": "/1/x", "C:/x": "C:/x", "rel/x": "rel/x"} {
		if got := FromGitBash(p); got != want {
			t.Errorf("FromGitBash(%q) = %q, want %q", p, got, want)
		}
	}
	if Host(`C:\Users\me\proj`) != "C:/Users/me/proj" || Root("C:/Users") != "C:/" || Root("/x") != "/" {
		t.Error("Host or Root")
	}
	if rel, ok := In("C:/Users/me/proj/src", "c:/users/me/proj"); !ok || rel != "src" {
		t.Errorf("In, case ignored: %q %v", rel, ok)
	}
	// Elsewhere, none of it.
	windows(t, false)
	if Guest("C:/x") != "C:/x" || FromGitBash("/c/x") != "/c/x" || IsAbs("C:/x") || Host(`a\b`) != `a\b` || Join("C:", "x") != "C:/x" {
		t.Error("not Windows")
	}
}

func TestJoinBash(t *testing.T) {
	cases := [][2]string{
		{"/a/b", "c"}, {"/a/b/", "./c/"}, {"/a/b", "../c"}, {"/a/b", "../../.."}, {"/a/b", "../../../x"},
		{"/", "x"}, {"/", ".."}, {"", "x"}, {"/a", "b//c/./d/../e"}, {"/a/b", ""}, {"C:", "Users/x/../y"},
		{"/a", "../"}, {"/a/b", "c/.."},
	}
	for _, c := range cases {
		r := bashref.Run(t, "", nil, "_agent_vm_path_join", c[0], c[1])
		if want := strings.TrimSuffix(r.Stdout, "\n"); Join(c[0], c[1]) != want {
			t.Errorf("Join(%q, %q) = %q, bash %q", c[0], c[1], Join(c[0], c[1]), want)
		}
	}
}
