//go:build linux || darwin || windows

package reversesshfs

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// Guard is asked before each write the read-only names allow, with the path
// relative to the served directory; a no refuses it and nothing changes.
// Reads never ask.
func TestRootedGuard(t *testing.T) {
	var asked []string
	allow := false
	Guard = func(root, rel string) bool {
		asked = append(asked, rel)
		return allow || rel != ".envrc" && rel != "src/new"
	}
	t.Cleanup(func() { Guard = nil })
	c, root := setupRooted(t, false)
	os.WriteFile(filepath.Join(root, ".envrc"), []byte("orig"), 0o644)
	p := func(s string) string { return filepath.Join(root, s) }

	for _, op := range []struct {
		name string
		rel  string
		f    func() error
	}{
		{"write", ".envrc", func() error {
			f, err := c.OpenFile(p(".envrc"), os.O_WRONLY|os.O_TRUNC)
			if err == nil {
				f.Close()
			}
			return err
		}},
		{"remove", ".envrc", func() error { return c.Remove(p(".envrc")) }},
		{"rename onto", ".envrc", func() error { return c.PosixRename(p("src/main.go"), p(".envrc")) }},
		{"chmod", ".envrc", func() error { return c.Chmod(p(".envrc"), 0o755) }},
		{"mkdir", "src/new", func() error { return c.Mkdir(p("src/new")) }},
	} {
		asked = nil
		if err := op.f(); err == nil {
			t.Errorf("%s: allowed though Guard said no", op.name)
		}
		if !slices.Contains(asked, op.rel) {
			t.Errorf("%s: Guard asked %q, not %q", op.name, asked, op.rel)
		}
	}
	if b, _ := os.ReadFile(p(".envrc")); string(b) != "orig" {
		t.Errorf(".envrc changed: %q", b)
	}
	if _, err := os.Stat(p("src/main.go")); err != nil {
		t.Error("src/main.go moved")
	}
	asked = nil
	f, err := c.Open(p(".envrc"))
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
	if len(asked) != 0 {
		t.Errorf("a read asked: %q", asked)
	}
	allow = true
	if err := c.Chmod(p(".envrc"), 0o600); err != nil {
		t.Errorf("allowed: %v", err)
	}
}
