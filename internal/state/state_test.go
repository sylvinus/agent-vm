package state

import (
	"path/filepath"
	"testing"
)

func TestDefault(t *testing.T) {
	t.Setenv("AGENT_VM_STATE_DIR", "/elsewhere")
	if d, err := Default(); err != nil || d != "/elsewhere" {
		t.Errorf("override: %q, %v", d, err)
	}
	home := t.TempDir()
	t.Setenv("AGENT_VM_STATE_DIR", "")
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	if d, err := Default(); err != nil || string(d) != filepath.Join(home, ".agent-vm") {
		t.Errorf("default: %q, %v", d, err)
	}
}
