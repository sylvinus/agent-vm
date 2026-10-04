package ui

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode"
	"unicode/utf8"
)

// Text the guest printed, shown on the user's terminal: nothing in it may
// drive the terminal. Only tabs are kept.
func checkPlain(t *testing.T, what, s string) {
	t.Helper()
	if !utf8.ValidString(s) {
		t.Fatalf("%s: invalid UTF-8 (a raw C1 byte to some terminals): %q", what, s)
	}
	for _, r := range s {
		if r != '\t' && unicode.IsControl(r) {
			t.Fatalf("%s: control character %U in %q", what, r, s)
		}
	}
}

var guestSeeds = []string{
	"plain line",
	"\x1b[31mred\x1b[0m",
	"\x1b]0;title\x07",
	"\u009b31m C1 CSI",
	"\u009d0;title\u009c",
	"bell\x07 bs\x08 del\x7f",
	"\xff\x9b2J raw bytes",
	`time="2026" level=info msg="Downloading \x1b[2J"`,
	"progress 10%\rprogress 20%",
}

func FuzzTail(f *testing.F) {
	for _, s := range guestSeeds {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		p := filepath.Join(t.TempDir(), "log")
		if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
		for _, l := range strings.Split(strings.TrimSuffix(Tail(p, 20), "\n"), "\n") {
			checkPlain(t, "Tail", l)
		}
	})
}

func FuzzWindowLine(f *testing.F) {
	for _, s := range guestSeeds {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		w := &Window{out: io.Discard, log: io.Discard, tty: true, width: 80, height: 10}
		w.Write([]byte(s + "\n"))
		w.Close()
		for _, l := range w.lines {
			checkPlain(t, "Window", l)
			if strings.Contains(l, "\t") {
				t.Fatalf("Window: a tab breaks the width: %q", l)
			}
		}
	})
}
