package env

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// Lookup reads a value "as a shell sourcing the file would": whenever it
// answers, sh sourcing the file as the VM gets it gives the same value. It only answers for
// files of plain assignments, so sh runs nothing else here.
func FuzzLookup(f *testing.F) {
	for _, s := range []string{"K=v\n", "K='a b'\n", "export K=\"x\" # note\n", "K='multi\nline'\n", "K=a'b'\"c\"\n", "  K=1\nK=2\n", "K=v\r\n", "# c\n\nK=\n"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, content string) {
		if strings.ContainsRune(content, 0) {
			return
		}
		v, st := Lookup(content, "K")
		if st != Found {
			return
		}
		dir := t.TempDir()
		file := dir + "/env"
		// As the VM gets it: CRs dropped (a file from a Windows editor).
		if err := os.WriteFile(file, []byte(StripCR(content)), 0o600); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command("sh", "-c", `. "$1" && printf %s "$K"`, "sh", file)
		cmd.Dir, cmd.Env = dir, []string{"PATH=/usr/bin:/bin"}
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("Lookup accepted %q, sh refused it: %v", content, err)
		}
		if string(out) != v {
			t.Fatalf("Lookup(%q) = %q, sh reads %q", content, v, out)
		}
	})
}

// A value written as key='SQEscape(value)' is read back by the shell as
// itself: nothing in it ends the quotes and runs.
func FuzzSQEscape(f *testing.F) {
	for _, s := range []string{"plain", "it's", "'", "''", `'"'"'`, "$(id)", "`id`", "a\nb", "\\'", "x'; touch /tmp/pwned; '"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		if strings.ContainsRune(s, 0) {
			return // not in a shell word, nor in an env file
		}
		out, err := exec.Command("sh", "-c", "printf %s '"+SQEscape(s)+"'").Output()
		if err != nil {
			t.Fatalf("sh refused %q: %v", SQEscape(s), err)
		}
		if string(out) != s {
			t.Fatalf("%q came back as %q", s, out)
		}
	})
}
