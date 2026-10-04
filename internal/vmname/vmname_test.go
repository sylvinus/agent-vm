package vmname

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/bashref"
)

var dirs = []string{
	"/home/u/proj",
	"/home/u/proj/",
	"/home/u/My Project.v2",
	"/home/u/café",
	"/home/u/-lead-",
	"/home/u/__",
	"/home/u/a__b",
	"/home/u/" + strings.Repeat("x", 40),
	"/home/u/a-very_long.name-with.many-parts-2026",
	"/",
	"/home/u/x\ty",
}

func TestName(t *testing.T) {
	cases := map[string]string{
		"/home/u/proj":          "proj-",
		"/home/u/My Project.v2": "My-Project-v2-",
		"/home/u/café":          "caf-",
		"/home/u/-lead-":        "lead-",
		"/":                     "project-",
		"/home/u/__":            "project-",
	}
	for dir, prefix := range cases {
		got := Name(dir)
		if !strings.HasPrefix(got, prefix) || len(got) != len(prefix)+8 {
			t.Errorf("Name(%q) = %q, want %q and 8 hex digits", dir, got, prefix)
		}
	}
	if Name("/a/b") == Name("/a/b/") {
		t.Error("the path is hashed as spelled: /a/b and /a/b/ differ")
	}
}

// The names 0.2 gave, without its prefix: its VMs are found once moved.
func TestNameBash(t *testing.T) {
	for _, dir := range dirs {
		r := bashref.Run(t, "", nil, "_agent_vm_name", dir)
		if r.Code != 0 {
			t.Fatalf("_agent_vm_name %q: %d %s", dir, r.Code, r.Stderr)
		}
		want := strings.TrimSuffix(r.Stdout, "\n")
		if strings.HasPrefix(want, OldPrefix+"-") {
			// Nothing of the folder's name: a name Lima refused in 0.2.
			continue
		}
		if Name(dir) != FromOld(want) {
			t.Errorf("Name(%q) = %q, bash %q", dir, Name(dir), want)
		}
	}
}

// A name longer than this machine allows is cut in its folder part, the
// hash of the whole path kept; 0.2's name of the same folder is cut alike.
func TestNameFits(t *testing.T) {
	old := MaxLen
	t.Cleanup(func() { MaxLen = old })
	MaxLen = 20
	dir := "/home/u/" + strings.Repeat("long-folder-", 4)
	n := Name(dir)
	full := strings.TrimSuffix(strings.Repeat("long-folder-", 4), "-")
	if len(n) != 20 || !strings.HasPrefix(n, "long-folder") || n[len(n)-9:] != Name(dir)[len(n)-9:] || strings.Contains(n, "--") {
		t.Errorf("Name = %q", n)
	}
	if other := Name("/elsewhere/" + strings.Repeat("long-folder-", 4)); other == n {
		t.Error("two folders, one name")
	}
	MaxLen = 76
	oldName := OldPrefix + Name(dir)
	MaxLen = 20
	if FromOld(oldName) != n {
		t.Errorf("FromOld(%q) = %q, Name %q", oldName, FromOld(oldName), n)
	}
	if s, _ := Scratch(dir); len(s) > 20 || !IsScratch(s) {
		t.Errorf("Scratch = %q", s)
	}
	MaxLen = 76
	if Name(dir) != full+"-"+Name(dir)[len(Name(dir))-8:] {
		t.Errorf("cut though it fits: %q", Name(dir))
	}
}

func TestFromOld(t *testing.T) {
	for old, want := range map[string]string{
		"agent-vm-base":               "base",
		"agent-vm-proj-1234abcd":      "proj-1234abcd",
		"agent-vm-base-1234abcd":      "base-1234abcd",
		"agent-vm-p-scratch-0123abcd": "p-scratch-0123abcd",
	} {
		if got := FromOld(old); got != want {
			t.Errorf("FromOld(%q) = %q, want %q", old, got, want)
		}
	}
}

func TestScratchBash(t *testing.T) {
	for _, dir := range dirs {
		got, err := Scratch(dir)
		if err != nil {
			t.Fatal(err)
		}
		if !IsScratch(got) || len(got) > 76 {
			t.Errorf("Scratch(%q) = %q", dir, got)
		}
		r := bashref.Run(t, "", nil, "_agent_vm_scratch_name", dir)
		want := FromOld(strings.TrimSuffix(r.Stdout, "\n"))
		if got[:len(got)-8] != want[:len(want)-8] {
			t.Errorf("Scratch(%q) = %q, bash %q", dir, got, want)
		}
	}
}

func TestIsScratch(t *testing.T) {
	for name, want := range map[string]bool{
		"proj-scratch-0123abcd":   true,
		"proj-scratch-0123abc":    false,
		"proj-1234abcd":           false,
		"base":                    false,
		"p/x-scratch-0123abcd":    false,
		"proj-scratch-0123abcd\n": false,
	} {
		if IsScratch(name) != want {
			t.Errorf("IsScratch(%q) != %v", name, want)
		}
	}
}

func TestAbsDir(t *testing.T) {
	tmp := t.TempDir()
	sub := filepath.Join(tmp, "sub")
	if err := os.Mkdir(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Chdir(tmp)
	for in, want := range map[string]string{
		"":          tmp,
		"sub":       sub,
		"sub/":      sub,
		"./sub/../": tmp,
		sub + "/":   sub,
	} {
		got, err := AbsDir(in)
		if err != nil || got != want {
			t.Errorf("AbsDir(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	if _, err := AbsDir(filepath.Join(tmp, "missing")); err == nil {
		t.Error("a missing directory was accepted")
	}
	ctl := filepath.Join(tmp, "a\nb")
	if err := os.Mkdir(ctl, 0o755); err == nil {
		if _, err := AbsDir(ctl); err == nil {
			t.Error("a control character was accepted")
		}
	}
}
