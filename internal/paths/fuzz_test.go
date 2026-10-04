package paths

import (
	"strings"
	"testing"
)

// In and CutPrefix, case ignored or not: no panic, the rest is a suffix of
// the path as spelled, and joined back it is the path again.
func FuzzIn(f *testing.F) {
	for _, s := range [][2]string{{"/a/b/c", "/a/b"}, {"/A/B", "/a/b"}, {"/a/bc", "/a/b"}, {"/İ/x", "/i̇"}, {"/ß/x", "/SS"}, {"/K/x", "/k"}, {"/", "/"}} {
		f.Add(s[0], s[1], false)
		f.Add(s[0], s[1], true)
	}
	f.Fuzz(func(t *testing.T, p, dir string, nocase bool) {
		old := NoCase
		NoCase = func() bool { return nocase }
		defer func() { NoCase = old }()
		if rest, ok := CutPrefix(p, dir); ok && !strings.HasSuffix(p, rest) {
			t.Fatalf("CutPrefix(%q, %q) = %q, not the end of the path", p, dir, rest)
		}
		rel, ok := In(p, dir)
		if !ok {
			return
		}
		if rel == "." {
			// dir itself, or dir/. as spelled.
			p, dir := strings.TrimSuffix(p, "/"), strings.TrimSuffix(dir, "/")
			if !Equal(p, dir) && !Equal(p, dir+"/.") {
				t.Fatalf("In(%q, %q) = \".\"", p, dir)
			}
			return
		}
		if p := strings.TrimSuffix(p, "/"); !strings.HasSuffix(p, rel) || !Equal(p, strings.TrimSuffix(dir, "/")+"/"+rel) {
			t.Fatalf("In(%q, %q) = %q", p, dir, rel)
		}
	})
}
