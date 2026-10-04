package ui

import (
	"bytes"
	"errors"
	"io"
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/bashref"
)

const para = "An agent could write .git/config or .git/hooks in your projects, and git on this machine would run them, even when your editor or shell prompt calls git.\n\n  brew unlink lima 2>/dev/null; brew install sylvinus/tap/lima-sylvinus with a long command line that must stay whole\nshort\n" +
	"averyveryveryveryveryveryveryveryveryveryveryveryveryveryveryveryveryveryverylongword and then some more words after it\n"

func TestWrapBash(t *testing.T) {
	for w := 8; w <= 72; w++ {
		r := bashref.Script(t, "", nil, `printf '%s' "$2" | _agent_vm_wrap "$1"`, strconv.Itoa(w), para)
		if got := Wrap(para, w); got != r.Stdout {
			t.Errorf("Wrap(%d):\n%s\nbash:\n%s", w, got, r.Stdout)
		}
	}
}

func TestBoxBash(t *testing.T) {
	for _, title := range []string{"Lima cannot keep .git read-only", strings.Repeat("t", 80)} {
		r := bashref.Script(t, "", nil, `_agent_vm_have_tty() { return 1; }; printf '%s' "$2" | _agent_vm_box "$1"`, title, para)
		var b bytes.Buffer
		u := &UI{Stderr: &b, Width: 72}
		u.Box(title, para)
		if b.String() != r.Stderr {
			t.Errorf("Box(%q):\n%s\nbash:\n%s", title, b.String(), r.Stderr)
		}
	}
}

// A log's tail is shown without what could drive the terminal.
func TestTail(t *testing.T) {
	p := t.TempDir() + "/log"
	lines := []string{"one", "two \033[31mred\033[0m", "title \033]0;pwned\007 set", "tab\there\r", "last"}
	os.WriteFile(p, []byte(strings.Join(lines, "\n")+"\n"), 0o644)
	got := Tail(p, 4)
	if strings.ContainsAny(got, "\033\007\r") {
		t.Errorf("control characters left: %q", got)
	}
	if got != "two red\ntitle ]0;pwned set\ntab\there\nlast\n" {
		t.Errorf("Tail = %q", got)
	}
}

func fakeTTY(answers ...string) func() (io.ReadCloser, error) {
	return func() (io.ReadCloser, error) {
		if len(answers) == 0 {
			return io.NopCloser(strings.NewReader("")), nil
		}
		a := answers[0]
		answers = answers[1:]
		return io.NopCloser(strings.NewReader(a)), nil
	}
}

func TestAsk(t *testing.T) {
	var b bytes.Buffer
	u := &UI{Stderr: &b, OpenTTY: fakeTTY("\n", "y\n", "no\n", "Yes\r\n")}
	if !u.AskYN("Q?", true) || !u.AskYN("Q?", false) || u.AskYN("Q?", true) || !u.AskYN("Q?", false) {
		t.Error("AskYN answers")
	}
	if b.String() != "  Q? [Y/n]:   Q? [y/N]:   Q? [Y/n]:   Q? [y/N]: " {
		t.Errorf("prompts: %q", b.String())
	}
	// No terminal: the default, never a yes it was not given.
	u = &UI{Stderr: io.Discard, OpenTTY: func() (io.ReadCloser, error) { return nil, errors.New("no tty") }}
	if u.AskYN("Q?", false) || !u.AskYN("Q?", true) || u.CanAsk() {
		t.Error("without a terminal")
	}
	b.Reset()
	u = &UI{Stderr: &b, OpenTTY: fakeTTY("10G\n", "0\n", "7\n")}
	if n := u.AskInt("Disk", 10, 0); n != 7 {
		t.Errorf("AskInt = %d", n)
	}
	if !strings.Contains(b.String(), "(must be a positive integer, e.g. 10; got: 10G)") {
		t.Errorf("AskInt said: %q", b.String())
	}
	u = &UI{Stderr: io.Discard, OpenTTY: fakeTTY("4\n", "\n")}
	if n := u.AskChoice("Pick", 2, "a", "b", "c"); n != 2 {
		t.Errorf("AskChoice = %d", n)
	}
}
