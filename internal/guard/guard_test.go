package guard

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type asker struct {
	answers []bool // nil: no one to ask
	asked   []string
	told    []string
}

func (a *asker) guard(t *testing.T, list string) *Guard {
	t.Helper()
	dir := t.TempDir()
	if list != "" {
		os.WriteFile(filepath.Join(dir, FileName), []byte(list), 0o644)
	}
	g, err := Load(dir, "proj-1a2b3c4d")
	if err != nil {
		t.Fatal(err)
	}
	g.Ask = func(_ context.Context, title, msg string) (bool, bool) {
		a.asked = append(a.asked, msg)
		if a.answers == nil {
			return false, false
		}
		ans := a.answers[0]
		a.answers = a.answers[1:]
		return ans, true
	}
	g.Tell = func(title, msg string) { a.told = append(a.told, msg) }
	return g
}

// Only the guarded paths ask, at any depth, case ignored; an answer holds:
// a yes until the VM stops, a no for a while.
func TestAllow(t *testing.T) {
	a := &asker{answers: []bool{false, true}}
	g := a.guard(t, "")
	for _, rel := range []string{"src/main.go", "Makefile", "package.json", ".envrc.bak", "x.vscode/tasks.json"} {
		if !g.Allow("/p", rel, false) {
			t.Errorf("%s refused", rel)
		}
	}
	if len(a.asked) != 0 {
		t.Fatalf("asked for unguarded paths: %q", a.asked)
	}
	if g.Allow("/p", "sub/.ENVRC", false) {
		t.Error("no was not a no")
	}
	if !strings.Contains(a.asked[0], "change .envrc in /p") || !strings.Contains(a.asked[0], "Path: sub/.ENVRC") || !strings.Contains(a.asked[0], "direnv runs it") {
		t.Errorf("question: %q", a.asked[0])
	}
	if g.Allow("/p", "sub/.ENVRC", false) || len(a.asked) != 1 {
		t.Error("asked again right after a no")
	}
	if !g.Allow("/p", ".vscode/tasks.json", false) || !g.Allow("/p", ".vscode/tasks.json", false) || len(a.asked) != 2 {
		t.Errorf("yes, then asked again: %d", len(a.asked))
	}
}

// The user adds paths (Makefile) and removes defaults.
// The program is named in the question as it was opened, agent-vm by default.
func TestAppName(t *testing.T) {
	for _, c := range []struct{ app, title, why string }{
		{"", "agent-vm: p", "You asked agent-vm to guard it (~/.agent-vm/guarded)."},
		{"mytool", "mytool: p", "You asked mytool to guard it."},
	} {
		var title, msg string
		g := &Guard{App: c.app, VM: "p", Paths: map[string]string{"Makefile": ""},
			Ask: func(_ context.Context, ti, m string) (bool, bool) { title, msg = ti, m; return true, true }}
		if !g.Allow(t.TempDir(), "Makefile", false) || title != c.title || !strings.Contains(msg, c.why) {
			t.Errorf("%q: %q %q", c.app, title, msg)
		}
	}
}

func TestList(t *testing.T) {
	a := &asker{answers: []bool{false}}
	g := a.guard(t, "# mine\nMakefile\n!.envrc\n /scripts/deploy.sh \n")
	if !g.Allow("/p", ".envrc", false) {
		t.Error("removed default still guarded")
	}
	if g.Allow("/p", "Makefile", false) {
		t.Error("added path not guarded")
	}
	if !strings.Contains(a.asked[0], "You asked agent-vm to guard it") {
		t.Errorf("question: %q", a.asked[0])
	}
	if _, ok := g.match("app/scripts/deploy.sh", false); !ok {
		t.Error("a path with folders")
	}
}

// AGENT_VM_GUARDED_WRITES=deny: refused, no dialog.
func TestDenyMode(t *testing.T) {
	t.Setenv("AGENT_VM_GUARDED_WRITES", "deny")
	g, err := Load(t.TempDir(), "p")
	if err != nil {
		t.Fatal(err)
	}
	g.Tell = func(string, string) { t.Error("told") }
	if g.Allow("/p", ".envrc", false) || !g.Allow("/p", "main.go", false) {
		t.Error("deny mode")
	}
}

// No one to ask: refused, and said so.
func TestNoOneToAsk(t *testing.T) {
	a := &asker{}
	g := a.guard(t, "")
	if g.Allow("/p", ".envrc", false) {
		t.Error("allowed with no one to ask")
	}
	if len(a.told) != 1 || !strings.Contains(a.told[0], "no dialog could ask you") {
		t.Errorf("told: %q", a.told)
	}
}

// On a Windows host Explorer sends your NTLM hash to the server a shortcut,
// a library or a desktop.ini names, when it shows the file: they are guarded
// by extension, and under the names Windows makes into them.
func TestWindowsHostGuards(t *testing.T) {
	old := windowsHost
	t.Cleanup(func() { windowsHost = old })
	for _, rel := range []string{"a.lnk", "docs/B.URL", "x.library-ms", "x.searchConnector-ms", "z.scf", "sub/desktop.ini",
		"a.lnk.", "a.lnk ", "a.lnk:Zone.Identifier", "a.lnk::$DATA", "A.LnK. . "} {
		windowsHost = true
		a := &asker{answers: []bool{false}}
		g := a.guard(t, "")
		if g.Allow("/p", rel, false) || len(a.asked) != 1 {
			t.Errorf("%q: let through (asked %d)", rel, len(a.asked))
		}
		windowsHost = false
		a = &asker{}
		if g = a.guard(t, ""); !g.Allow("/p", rel, false) || len(a.asked) != 0 {
			t.Errorf("%q: asked on a host that is not Windows", rel)
		}
	}
	windowsHost = true
	a := &asker{}
	g := a.guard(t, "")
	for _, rel := range []string{"a.txt", "lnk", "a.lnkx", "notes/url", "src/main.go"} {
		if !g.Allow("/p", rel, false) {
			t.Errorf("%q: refused", rel)
		}
	}
	if len(a.asked) != 0 {
		t.Errorf("asked: %q", a.asked)
	}
	// The user's list removes a default, in any case.
	g = a.guard(t, "!*.LNK\n")
	if !g.Allow("/p", "a.lnk", false) || g.Allow("/p", "a.url", false) {
		t.Error("!*.LNK")
	}
}

// A folder moved or removed is looked into for a guarded file; one with more
// entries than are looked at is asked about, not let through.
func TestEntryTooBig(t *testing.T) {
	root := t.TempDir()
	os.MkdirAll(filepath.Join(root, "d", "z"), 0o755)
	for _, f := range []string{"d/a", "d/b", "d/c", "d/z/.envrc"} {
		os.WriteFile(filepath.Join(root, f), nil, 0o644)
	}
	old := maxScan
	t.Cleanup(func() { maxScan = old })
	maxScan = 2
	a := &asker{answers: []bool{false}}
	g := a.guard(t, "")
	if g.Allow(root, "d", true) {
		t.Error("a folder too big to look into was let through")
	}
	if len(a.asked) != 1 || !strings.Contains(a.asked[0], "more than 2 entries") {
		t.Errorf("asked: %q", a.asked)
	}
	maxScan = old
	a = &asker{answers: []bool{false}}
	g = a.guard(t, "")
	if g.Allow(root, "d", true) || len(a.asked) != 1 || !strings.Contains(a.asked[0], "holds .envrc") {
		t.Errorf("a folder holding .envrc: %q", a.asked)
	}
}
