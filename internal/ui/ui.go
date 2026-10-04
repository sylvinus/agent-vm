// Package ui asks questions on the terminal and prints agent-vm's boxed
// notices, as 0.2's lib/ui.sh did.
package ui

import (
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"

	"golang.org/x/term"
)

// UI asks on the controlling terminal and writes questions to Stderr.
type UI struct {
	Stderr io.Writer
	// OpenTTY opens the terminal answers are read from (the process's
	// own when nil; tests set their own).
	OpenTTY func() (io.ReadCloser, error)
	// StderrIsTerminal: where the questions go is seen by someone.
	StderrIsTerminal bool
	// Width of the terminal, for boxes; 0 asks the terminal.
	Width int
}

// New is the UI of this process.
func New() *UI {
	return &UI{Stderr: os.Stderr, StderrIsTerminal: term.IsTerminal(int(os.Stderr.Fd()))}
}

func (u *UI) open() (io.ReadCloser, error) {
	if u.OpenTTY != nil {
		return u.OpenTTY()
	}
	return openTTY()
}

// HaveTTY reports whether a terminal can be opened: a device node that
// exists does not say it (CI, cron), only opening it does.
func (u *UI) HaveTTY() bool {
	f, err := u.open()
	if err != nil {
		return false
	}
	f.Close()
	return true
}

// CanAsk reports whether a question can be asked and seen: a terminal to
// read the answer from, and stderr on a terminal too, or a caller capturing
// stderr would wait on a question nobody sees.
func (u *UI) CanAsk() bool {
	return u.HaveTTY() && u.StderrIsTerminal
}

// line reads one line from the terminal, a byte at a time so that nothing
// after it is taken from whoever reads next. "" when there is none.
func (u *UI) line() string {
	f, err := u.open()
	if err != nil {
		return ""
	}
	defer f.Close()
	var b strings.Builder
	var c [1]byte
	for {
		n, err := f.Read(c[:])
		if n == 1 {
			if c[0] == '\n' {
				break
			}
			b.WriteByte(c[0])
		}
		if err != nil {
			break
		}
	}
	return strings.TrimSuffix(b.String(), "\r")
}

// Ask asks for a value, def when the answer is empty.
func (u *UI) Ask(prompt, def string) string {
	fmt.Fprintf(u.Stderr, "  %s [%s]: ", prompt, def)
	if r := u.line(); r != "" {
		return r
	}
	return def
}

// AskYN asks a yes/no question; an empty answer is def.
func (u *UI) AskYN(prompt string, def bool) bool {
	ind, d := "[y/N]", "N"
	if def {
		ind, d = "[Y/n]", "Y"
	}
	fmt.Fprintf(u.Stderr, "  %s %s: ", prompt, ind)
	r := u.line()
	if r == "" {
		r = d
	}
	return r[0] == 'y' || r[0] == 'Y'
}

var positiveRe = regexp.MustCompile(`^[1-9][0-9]*$`)

// AskInt asks for a positive integer, at most max when max > 0, until it
// gets one: a typo such as "10G" is caught here.
func (u *UI) AskInt(prompt string, def, max int) int {
	for {
		r := u.Ask(prompt, fmt.Sprint(def))
		var n int
		if positiveRe.MatchString(r) {
			if _, err := fmt.Sscan(r, &n); err == nil && (max == 0 || n <= max) {
				return n
			}
		}
		if max > 0 {
			fmt.Fprintf(u.Stderr, "  (a number from 1 to %d; got: %s)\n", max, r)
		} else {
			fmt.Fprintf(u.Stderr, "  (must be a positive integer, e.g. 10; got: %s)\n", r)
		}
	}
}

// AskChoice lists options, numbered from 1, and returns the number picked.
func (u *UI) AskChoice(prompt string, def int, options ...string) int {
	for i, o := range options {
		fmt.Fprintf(u.Stderr, "    %d) %s\n", i+1, o)
	}
	return u.AskInt(prompt, def, len(options))
}

// Wrap word-wraps s to width columns. Lines indented by two spaces are
// commands, kept whole so they can be copied.
func Wrap(s string, width int) string {
	var out []string
	for _, l := range strings.Split(strings.TrimSuffix(s, "\n"), "\n") {
		if strings.HasPrefix(l, "  ") || len(l) <= width {
			out = append(out, l)
			continue
		}
		line := ""
		for _, w := range strings.Fields(l) {
			switch {
			case line == "":
				line = w
			case len(line)+1+len(w) <= width:
				line += " " + w
			default:
				out = append(out, line)
				line = w
			}
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n") + "\n"
}

// Box prints body on Stderr as a boxed notice, for the warnings and offers
// of setup and of a start: one paragraph per line, wrapped to the terminal
// (72 columns at most). No right border: it would need every line padded to
// its display width, unknown for non-ASCII text.
func (u *UI) Box(title, body string) {
	width := u.Width
	if width == 0 {
		width = 72
		if f, err := u.open(); err == nil {
			if fd, ok := f.(interface{ Fd() uintptr }); ok {
				if w, _, err := term.GetSize(int(fd.Fd())); err == nil {
					width = w
				}
			}
			f.Close()
		}
	}
	width = min(max(width, 30), 72)
	rule := strings.Repeat("-", width)
	n := max(width-len(title)-4, 1)
	var b strings.Builder
	fmt.Fprintf(&b, "\n+- %s %s\n|\n", title, rule[:n])
	for _, l := range strings.Split(strings.TrimSuffix(Wrap(body, width-2), "\n"), "\n") {
		b.WriteString(strings.TrimRight("| "+l, " ") + "\n")
	}
	fmt.Fprintf(&b, "|\n+%s\n", rule[:width-1])
	fmt.Fprint(u.Stderr, b.String())
}

// ResetTermModes turns off the input modes a full-screen program in the VM
// may have left on when it was killed or its connection dropped: mouse
// tracking, focus reports, bracketed paste, the kitty keyboard protocol and
// xterm's modifyOtherKeys, each of which types escape sequences into the
// host shell otherwise. Also shows the cursor. Only on a terminal.
func ResetTermModes(stdout *os.File) {
	if term.IsTerminal(int(stdout.Fd())) {
		fmt.Fprint(stdout, "\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1015l\033[?1004l\033[?2004l\033[<u\033[>4;0m\033[?25h")
	}
}
