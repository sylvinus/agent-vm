package ui

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"strings"
	"unicode"

	"golang.org/x/term"
)

// Window copies what is written to log and, on a terminal, shows only the
// last lines, redrawn in place and cleared at Close; elsewhere it passes
// every line through. Lines are cut to the terminal's width, since a wrapped
// one would break the redraw, and colour codes are dropped, since a cut one
// would leave the terminal coloured.
type Window struct {
	out           io.Writer
	log           io.Writer
	tty           bool
	width, height int
	lines         []string
	drawn         int
	partial       []byte
}

// IsTerminal reports whether f is a terminal.
func IsTerminal(f *os.File) bool { return term.IsTerminal(int(f.Fd())) }

// NewWindow writes to out, a terminal or not, and to log.
func (u *UI) NewWindow(out io.Writer, log io.Writer) *Window {
	w := &Window{out: out, log: log, width: 80, height: 10}
	if f, ok := out.(*os.File); ok && term.IsTerminal(int(f.Fd())) {
		w.tty = true
		if t, err := u.open(); err == nil {
			if fd, ok := t.(interface{ Fd() uintptr }); ok {
				if cols, rows, err := term.GetSize(int(fd.Fd())); err == nil {
					if cols > 1 {
						w.width = cols
					}
					if rows < w.height+2 {
						w.height = 1
						if rows > 3 {
							w.height = rows - 2
						}
					}
				}
			}
			t.Close()
		}
	}
	return w
}

func (w *Window) Write(p []byte) (int, error) {
	w.log.Write(p)
	if !w.tty {
		return w.out.Write(p)
	}
	w.partial = append(w.partial, p...)
	for {
		i := bytes.IndexByte(w.partial, '\n')
		if i < 0 {
			break
		}
		w.show(string(w.partial[:i]))
		w.partial = w.partial[i+1:]
	}
	return len(p), nil
}

// show adds a line to the window and redraws it.
func (w *Window) show(line string) {
	// A progress bar redraws with \r: keep what the last redraw left.
	line = strings.TrimSuffix(line, "\r")
	if i := strings.LastIndexByte(line, '\r'); i >= 0 {
		line = line[i+1:]
	}
	// Lima logs `time="…" level=info msg="…" key=value`: the message is
	// what fits and what says something.
	if strings.HasPrefix(line, "time=") {
		if _, m, ok := strings.Cut(line, ` msg="`); ok {
			line, _, _ = strings.Cut(m, `"`)
		}
	}
	line = strings.ReplaceAll(plain(line), "\t", " ")
	if r := []rune(line); len(r) > w.width-1 {
		line = string(r[:w.width-1])
	}
	if len(w.lines) == w.height {
		w.lines = w.lines[1:]
	}
	w.lines = append(w.lines, line)
	if w.drawn > 0 {
		fmt.Fprintf(w.out, "\033[%dA", w.drawn)
	}
	fmt.Fprintf(w.out, "\r\033[J\033[2m%s\033[0m", strings.Join(w.lines, "\n")+"\n")
	w.drawn = len(w.lines)
}

// plain is s without what could drive a terminal: CSI sequences (stripCSI),
// then every control character but tab, C1 included (U+009B is CSI to some
// terminals); invalid UTF-8 becomes U+FFFD.
func plain(s string) string {
	return strings.Map(func(r rune) rune {
		if r != '\t' && unicode.IsControl(r) {
			return -1
		}
		return r
	}, stripCSI(s))
}

// stripCSI drops each ESC, and the [...letter that follows it when there is
// one.
func stripCSI(s string) string {
	for {
		i := strings.IndexByte(s, 0x1b)
		if i < 0 {
			return s
		}
		rest := s[i+1:]
		if strings.HasPrefix(rest, "[") {
			if j := strings.IndexFunc(rest[1:], func(r rune) bool { return r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' }); j >= 0 {
				rest = rest[j+2:]
			}
		}
		s = s[:i] + rest
	}
}

// Close shows a last line without a newline, then clears the window.
func (w *Window) Close() {
	if !w.tty {
		return
	}
	if len(w.partial) > 0 {
		w.show(string(w.partial))
		w.partial = nil
	}
	if w.drawn > 0 {
		fmt.Fprintf(w.out, "\033[%dA\r\033[J", w.drawn)
		w.drawn = 0
	}
}

// Tail is the last n lines of the file at p, for when a step failed and
// its window is gone. Cleaned as the window cleans them: the log holds what
// the guest printed, and printing it raw would let it drive the terminal.
func Tail(p string, n int) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	lines := strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	for i, l := range lines {
		lines[i] = plain(l)
	}
	return strings.Join(lines, "\n") + "\n"
}
