package ui

import (
	"bytes"
	"fmt"
	"strings"
	"testing"
)

// A 40-column terminal gets a 40-column box; never under 30, nor over 72.
func TestBoxWidth(t *testing.T) {
	for width, want := range map[int]int{40: 40, 20: 30, 200: 72} {
		var b bytes.Buffer
		u := &UI{Stderr: &b, Width: width}
		u.Box("Title", strings.Repeat("word ", 40))
		for _, l := range strings.Split(strings.TrimSuffix(b.String(), "\n"), "\n") {
			if len(l) > want {
				t.Errorf("width %d: line of %d: %q", width, len(l), l)
			}
		}
		if last := strings.Split(strings.TrimSuffix(b.String(), "\n"), "\n"); len(last[len(last)-1]) != want {
			t.Errorf("width %d: bottom rule %q", width, last[len(last)-1])
		}
	}
}

// On a terminal: the last lines only, at most height, each cut to the width,
// Lima's msg= kept, a progress bar's last redraw; cleared at Close. The log
// gets everything, as written.
func TestWindow(t *testing.T) {
	var out, log bytes.Buffer
	w := &Window{out: &out, log: &log, tty: true, width: 20, height: 3}
	var in strings.Builder
	for i := 1; i <= 5; i++ {
		fmt.Fprintf(&in, "line %d\n", i)
	}
	in.WriteString(`time="2026-10-04T10:00:00Z" level=info msg="Downloading the image"` + "\n")
	in.WriteString("10%\r50%\r100%\n")
	in.WriteString(strings.Repeat("x", 40) + "\n")
	in.WriteString("\x1b[31mred\x1b[0m\tend")
	w.Write([]byte(in.String()))
	if strings.Join(w.lines, "|") != "Downloading the ima|100%|"+strings.Repeat("x", 19) {
		t.Errorf("window: %q", w.lines)
	}
	if log.String() != in.String() {
		t.Errorf("log: %q", log.String())
	}
	w.Close()
	if !strings.HasSuffix(out.String(), "\033[3A\r\033[J") || w.drawn != 0 {
		t.Errorf("not cleared: %q", out.String()[max(len(out.String())-20, 0):])
	}
	if strings.Join(w.lines, "|") != "100%|"+strings.Repeat("x", 19)+"|red end" {
		t.Errorf("last line: %q", w.lines)
	}
	// Not a terminal: every line as is.
	out.Reset()
	w = &Window{out: &out, log: &log, width: 20, height: 3}
	w.Write([]byte("a\nb\n"))
	w.Close()
	if out.String() != "a\nb\n" {
		t.Errorf("no terminal: %q", out.String())
	}
}
