package gitguard

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
	"unicode"
)

// hops must list every symlink the path goes through: a link the VM can
// write chooses where git looks. The oracle: a link the path depends on is
// one whose retargeting changes where the path leads.
func FuzzHops(f *testing.F) {
	for _, seed := range [][]byte{
		{0, 1, 2, 3, 4, 5, 6, 7, 8},
		{4, 4, 4, 4, 1, 2},
		{2, 3, 9, 1, 0, 5, 11, 7, 4},
		{7, 6, 5, 4, 8, 8, 0, 10},
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, in []byte) {
		if len(in) > 24 {
			return
		}
		next := func() int {
			if len(in) == 0 {
				return 0
			}
			b := in[0]
			in = in[1:]
			return int(b)
		}
		root, err := filepath.EvalSymlinks(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		root = filepath.ToSlash(root)
		sentinel := root + "/sentinel"
		for _, d := range []string{"d0/d0", "d1/d0", "d2", "d3", "sentinel"} {
			if err := os.MkdirAll(root+"/"+d, 0o755); err != nil {
				t.Fatal(err)
			}
		}
		targets := []string{"d0", "../d1", "l1", root + "/d2", "/", ".", "..", "l0", root + "/l3/d0", "d0/d0", "missing", "../l2"}
		var links []string
		for _, l := range []string{"l0", "l1", "l2", "l3", "d0/l0", "d1/l1"} {
			p := root + "/" + l
			if err := os.Symlink(targets[next()%len(targets)], p); err != nil {
				t.Fatal(err)
			}
			links = append(links, p)
		}
		comps := []string{"d0", "d1", "d2", "d3", "l0", "l1", "l2", "l3", "..", ".", "x"}
		p := root
		for n := next()%5 + 1; n > 0; n-- {
			p += "/" + comps[next()%len(comps)]
		}
		want, err := filepath.EvalSymlinks(p)
		if err != nil {
			return // a loop, or not there: nothing to compare with
		}
		got := hops(p)
		if last := got[len(got)-1]; filepath.Clean(last) != filepath.Clean(want) {
			t.Fatalf("hops(%q) ends at %q, the path leads to %q (%q)", p, last, want, got)
		}
		for _, l := range links {
			old, _ := os.Readlink(l)
			os.Remove(l)
			os.Symlink(sentinel, l)
			moved, err := filepath.EvalSymlinks(p)
			os.Remove(l)
			os.Symlink(old, l)
			if (err != nil || moved != want) && !slices.Contains(got, l) {
				t.Fatalf("%q goes through %q, which hops leaves out: %q", p, l, got)
			}
		}
	})
}

// A hooks name Lima would read otherwise is no name: the folder is a risk
// to accept instead.
func TestHooksName(t *testing.T) {
	for rel, want := range map[string]string{
		".husky/_":   ".husky",
		"tools/h":    "tools",
		"R&D/hooks":  "R&D",
		".":          "",
		`a"b/x`:      "",
		"a\xffb/x":   "",
		"a\u2028b/x": "",
	} {
		if got, _ := HooksName(rel); got != want {
			t.Errorf("HooksName(%q) = %q, want %q", rel, got, want)
		}
	}
}

func FuzzVisible(f *testing.F) {
	for _, s := range []string{"core.editor = vi", "a\x1b[2Jb", "\u009b31m", "x\ny", "\xff\x9b"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		for _, r := range visible(s) {
			if unicode.IsControl(r) {
				t.Fatalf("control character %U left in %q", r, visible(s))
			}
		}
	})
}
