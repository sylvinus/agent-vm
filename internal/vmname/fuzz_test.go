package vmname

import (
	"regexp"
	"strings"
	"testing"
)

// Lima's identifiers (pkg/identifiers): letters and digits, groups joined by
// one of . _ -, 76 characters at most.
var limaID = regexp.MustCompile(`^[A-Za-z0-9]+([._-][A-Za-z0-9]+)*$`)

// Any folder: a name Lima takes (Name's length aside: a long one is refused
// with the advice to rename the folder), never the base template's, and a
// scratch name that IsScratch knows and Name never gives.
func FuzzName(f *testing.F) {
	for _, s := range []string{"/home/u/proj", "/", "/home/u/__", "/home/u/-x-", "/home/u/café", "/home/u/base", "/home/u/x-scratch", "/a\nb", "/home/u/" + strings.Repeat("y", 90)} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, dir string) {
		n := Name(dir)
		if !limaID.MatchString(n) || n == Template {
			t.Fatalf("Name(%q) = %q", dir, n)
		}
		if IsScratch(n) && !strings.HasSuffix(strings.TrimSuffix(dir, "/"), "-scratch") && !strings.HasSuffix(strings.TrimSuffix(dir, "/"), "scratch") {
			t.Fatalf("Name(%q) = %q looks like a scratch VM", dir, n)
		}
		s, err := Scratch(dir)
		if err != nil {
			t.Fatal(err)
		}
		if !limaID.MatchString(s) || len(s) > 76 || !IsScratch(s) {
			t.Fatalf("Scratch(%q) = %q", dir, s)
		}
	})
}
