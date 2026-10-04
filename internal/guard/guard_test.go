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
		if !g.Allow("/p", rel) {
			t.Errorf("%s refused", rel)
		}
	}
	if len(a.asked) != 0 {
		t.Fatalf("asked for unguarded paths: %q", a.asked)
	}
	if g.Allow("/p", "sub/.ENVRC") {
		t.Error("no was not a no")
	}
	if !strings.Contains(a.asked[0], "sub/.ENVRC in /p") || !strings.Contains(a.asked[0], "direnv runs it") {
		t.Errorf("question: %q", a.asked[0])
	}
	if g.Allow("/p", "sub/.ENVRC") || len(a.asked) != 1 {
		t.Error("asked again right after a no")
	}
	if !g.Allow("/p", ".vscode/tasks.json") || !g.Allow("/p", ".vscode/tasks.json") || len(a.asked) != 2 {
		t.Errorf("yes, then asked again: %d", len(a.asked))
	}
}

// The user adds paths (Makefile) and removes defaults.
func TestList(t *testing.T) {
	a := &asker{answers: []bool{false}}
	g := a.guard(t, "# mine\nMakefile\n!.envrc\n /scripts/deploy.sh \n")
	if !g.Allow("/p", ".envrc") {
		t.Error("removed default still guarded")
	}
	if g.Allow("/p", "Makefile") {
		t.Error("added path not guarded")
	}
	if !strings.Contains(a.asked[0], "You asked agent-vm to guard it") {
		t.Errorf("question: %q", a.asked[0])
	}
	if _, ok := g.match("app/scripts/deploy.sh"); !ok {
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
	if g.Allow("/p", ".envrc") || !g.Allow("/p", "main.go") {
		t.Error("deny mode")
	}
}

// No one to ask: refused, and said so.
func TestNoOneToAsk(t *testing.T) {
	a := &asker{}
	g := a.guard(t, "")
	if g.Allow("/p", ".envrc") {
		t.Error("allowed with no one to ask")
	}
	if len(a.told) != 1 || !strings.Contains(a.told[0], "no dialog could ask you") {
		t.Errorf("told: %q", a.told)
	}
}
