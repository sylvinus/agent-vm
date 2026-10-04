package host

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
)

// A VM folder not made yet: the free space of the home folder, where it
// will be.
func TestWarnDiskSpace(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	missing := filepath.Join(t.TempDir(), "not", "yet")
	var b bytes.Buffer
	WarnDiskSpace(missing, 1<<30, &b)
	if !strings.HasPrefix(b.String(), "Warning: ~") {
		t.Errorf("no warning: %q", b.String())
	}
	b.Reset()
	WarnDiskSpace(missing, 0, &b)
	WarnDiskSpace(missing, 1, &b)
	if b.Len() != 0 {
		t.Errorf("warned: %q", b.String())
	}
}
