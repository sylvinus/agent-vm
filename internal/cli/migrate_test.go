package cli

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/limaembed"
	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vm/vmtest"
)

// agent-vm takes every VM in its Lima home as its own (list, rm,
// destroy-all): never the user's own Lima home, however spelled.
func TestOwnLimaHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	// Go reads the home from USERPROFILE on Windows, not HOME.
	t.Setenv("USERPROFILE", home)
	lima := t.TempDir()
	t.Setenv("LIMA_HOME", lima)
	t.Setenv("AGENT_VM_LIMA_HOME", lima+"/")
	e, err := newApp(IO{Stdin: strings.NewReader(""), Stdout: io.Discard, Stderr: io.Discard})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.backend(context.Background()); err == nil || !strings.Contains(err.Error(), "your own Lima's home") {
		t.Errorf("own home: %v", err)
	}
	// The LIMA_HOME agent-vm sets for Lima is not the user's: a second
	// command in the same process (setup, then a start) is not refused.
	os.Unsetenv("LIMA_HOME")
	t.Setenv("AGENT_VM_LIMA_HOME", "")
	for i := range 2 {
		e, _ := newApp(IO{Stdin: strings.NewReader(""), Stdout: io.Discard, Stderr: io.Discard})
		if _, err := e.backend(context.Background()); err != nil {
			t.Errorf("command %d: %v", i+1, err)
		}
	}
}

// doctor, info and list only look: they never move 0.2's VMs, which stops
// running ones (an editor calls info unasked); a command that changes VMs
// does.
func TestMigrateNotFromReaders(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	// Go reads the home from USERPROFILE on Windows, not HOME.
	t.Setenv("USERPROFILE", home)
	for _, args := range [][]string{{"doctor"}, {"info"}, {"list"}, {"stop", "x"}} {
		te := newTestEnv(t, vmtest.New())
		moved := false
		te.migrate = func() { moved = true }
		te.run(args...)
		if want := args[0] == "stop"; moved != want {
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
	// 0.2's markers, named as 0.3.0 named them.
	os.WriteFile(te.state.Path(".agent-vm-built-by-agent-vm-p-12345678"), []byte("0.2.1\n"), 0o644)
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
	if te.state.Read(".agent-vm-built-by-p-12345678") != "0.2.1" {
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

// 0.3.0's VMs, made by a real Lima in its Lima home, move to a folder each
// and are found there by the Lima that agent-vm now runs.
func TestMigrateLayoutLima(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	t.Setenv("LIMA_HOME", "")
	t.Setenv("LIMA_INSTANCES_DIR", "")
	t.Setenv("LIMA_TEMPLATES_PATH", "")
	st := state.Dir(filepath.Join(home, ".agent-vm"))
	t.Setenv("AGENT_VM_STATE_DIR", string(st))
	ctx := context.Background()

	// How 0.3.0 had them: in the Lima home, with markers.
	old, err := vm.NewLima(st.LimaHome(), "", string(st))
	if err != nil {
		t.Fatal(err)
	}
	none := []vm.Mount{}
	for _, name := range []string{"base", "proj-12345678"} {
		if err := old.Create(ctx, name, "template:debian-13", vm.Settings{CPUs: 1, Mounts: &none}, io.Discard); errors.Is(err, limaembed.ErrNoAssets) {
			t.Skip("built without the guest agent: make assets")
		} else if err != nil {
			t.Fatal(err)
		}
	}
	for name, content := range map[string]string{
		".agent-vm-base-version": "1759000000\n", ".agent-vm-base-built-by": "0.3.0\n",
		".agent-vm-version-proj-12345678": "1759000000\n", ".agent-vm-built-by-proj-12345678": "0.3.0\n",
		".agent-vm-term-proj-12345678": "xterm\n",
	} {
		os.WriteFile(st.Path(name), []byte(content), 0o644)
	}

	var stderr bytes.Buffer
	e, err := newApp(IO{Stdin: strings.NewReader(""), Stdout: io.Discard, Stderr: &stderr})
	if err != nil {
		t.Fatal(err)
	}
	if got := e.layoutPending(); len(got) != 2 {
		t.Fatalf("pending: %v", got)
	}
	b, err := e.backend(ctx) // moves them
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(stderr.String(), "Moving base, proj-12345678") {
		t.Errorf("said: %q", stderr.String())
	}
	if got := e.layoutPending(); len(got) != 0 || st.PendingLayout(st.LimaHome()) {
		t.Errorf("still pending: %v\n%s", got, stderr.String())
	}
	all, err := b.List(ctx)
	if err != nil || len(all) != 2 {
		t.Fatalf("list: %v %v", all, err)
	}
	inst, err := b.Get(ctx, "proj-12345678")
	if err != nil || inst.Status != vm.Stopped || inst.CPUs != 1 || inst.Dir != st.Lima("proj-12345678") {
		t.Errorf("moved VM: %+v %v", inst, err)
	}
	if m := st.Known("proj-12345678"); m.Base == nil || m.Base.BuiltBy != "0.3.0" || m.Term != "xterm" {
		t.Errorf("metadata: %+v", m)
	}
	if !st.BaseReady("base") {
		t.Error("the base is not ready")
	}
	if _, err := os.Stat(filepath.Join(st.LimaHome(), "proj-12345678")); err == nil {
		t.Error("left in the Lima home")
	}
	// Cloned and deleted at the new place, as a start does.
	if err := b.Clone(ctx, "base", "other-12345678"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(st.Lima("other-12345678"), "lima.yaml")); err != nil {
		t.Errorf("clone: %v", err)
	}
	if !e.deleteVM(ctx, "other-12345678") {
		t.Error("delete")
	} else if _, err := os.Stat(st.VM("other-12345678")); err == nil {
		t.Error("the folder of a deleted VM is left")
	}
}
