package cli

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/vm/vmtest"
)

// agent-vm takes every VM in its Lima home as its own (list, rm,
// destroy-all): never the user's own Lima home, however spelled.
func TestOwnLimaHome(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	lima := t.TempDir()
	t.Setenv("LIMA_HOME", lima)
	t.Setenv("AGENT_VM_LIMA_HOME", lima+"/")
	e, err := newApp(IO{Stdin: strings.NewReader(""), Stdout: io.Discard, Stderr: io.Discard})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.backend(); err == nil || !strings.Contains(err.Error(), "your own Lima's home") {
		t.Errorf("own home: %v", err)
	}
	// The LIMA_HOME agent-vm sets for Lima is not the user's: a second
	// command in the same process (setup, then a start) is not refused.
	os.Unsetenv("LIMA_HOME")
	t.Setenv("AGENT_VM_LIMA_HOME", "")
	for i := range 2 {
		e, _ := newApp(IO{Stdin: strings.NewReader(""), Stdout: io.Discard, Stderr: io.Discard})
		if _, err := e.backend(); err != nil {
			t.Errorf("command %d: %v", i+1, err)
		}
	}
}

// doctor and info only look: they never move 0.2's VMs, which stops running
// ones (an editor calls info unasked); a command that uses VMs does.
func TestMigrateNotFromReaders(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	for _, args := range [][]string{{"doctor"}, {"info"}, {"list"}} {
		te := newTestEnv(t, vmtest.New())
		moved := false
		te.migrate = func() { moved = true }
		te.run(args...)
		if want := args[0] == "list"; moved != want {
			t.Errorf("%s: moved %v", args[0], moved)
		}
	}
}

func TestMigrateOld(t *testing.T) {
	old := t.TempDir()
	now := filepath.Join(t.TempDir(), "lima")
	// Already at the new place, under its new name: the move fails, and says
	// so.
	os.MkdirAll(filepath.Join(now, "p-12345678"), 0o755)
	os.MkdirAll(filepath.Join(old, "agent-vm-p-12345678"), 0o755)
	os.WriteFile(filepath.Join(old, "agent-vm-p-12345678", "lima.yaml"), []byte("{"), 0o644)
	os.MkdirAll(filepath.Join(old, "theirs"), 0o755)
	os.WriteFile(filepath.Join(old, "theirs", "lima.yaml"), []byte("{"), 0o644)

	te := newTestEnv(t, vmtest.New(), "n\n")
	os.MkdirAll(string(te.state), 0o755)
	os.WriteFile(te.state.Marker(state.BuiltByOf, "agent-vm-p-12345678"), []byte("0.2.1\n"), 0o644)
	te.migrateOld(context.Background(), old, now)
	if out := te.out(); !strings.Contains(out, "  agent-vm-p-12345678, as p-12345678\n") || strings.Contains(out, "theirs") || !strings.Contains(out, "Not moved") {
		t.Errorf("declined:\n%s", out)
	}
	if _, err := os.Stat(te.state.Path(migratedMarker)); err == nil {
		t.Error("declined, and marked as done")
	}

	st := te.state
	te = newTestEnv(t, te.fake)
	te.state = st
	te.migrateOld(context.Background(), old, now)
	if out := te.out(); !strings.Contains(out, "Error: could not move agent-vm-p-12345678") {
		t.Errorf("no terminal, failed move:\n%s", out)
	}
	if _, err := os.Stat(te.state.Path(migratedMarker)); err == nil {
		t.Error("a failed move was marked as done")
	}

	// Without a terminal it goes ahead; Lima reads a broken config as a
	// broken VM, which moves all the same. Then it is done, once.
	os.RemoveAll(filepath.Join(now, "p-12345678"))
	te.stderr.Reset()
	te.migrateOld(context.Background(), old, now)
	if out := te.out(); !strings.HasSuffix(out, "Done: they keep their shares and settings, under their new names.\n") {
		t.Errorf("no terminal:\n%s", out)
	}
	if _, err := os.Stat(filepath.Join(now, "p-12345678", "lima.yaml")); err != nil {
		t.Error("not moved")
	}
	if te.state.Read(te.state.Marker(state.BuiltByOf, "p-12345678")) != "0.2.1" {
		t.Error("its markers did not follow")
	}
	if _, err := os.Stat(filepath.Join(old, "theirs", "lima.yaml")); err != nil {
		t.Error("another VM was moved")
	}
	if _, err := os.Stat(te.state.Path(migratedMarker)); err != nil {
		t.Error("not marked as done")
	}
	os.MkdirAll(filepath.Join(old, "agent-vm-q-12345678"), 0o755)
	os.WriteFile(filepath.Join(old, "agent-vm-q-12345678", "lima.yaml"), []byte("{"), 0o644)
	te.stderr.Reset()
	te.migrateOld(context.Background(), old, now)
	if te.out() != "" {
		t.Errorf("after the marker: %q", te.out())
	}
	// Nothing of agent-vm's: nothing said.
	te = newTestEnv(t, te.fake)
	te.migrateOld(context.Background(), t.TempDir(), now)
	if te.out() != "" {
		t.Errorf("nothing to move: %q", te.out())
	}
}
