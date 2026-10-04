package env

import (
	"os"
	"testing"

	"github.com/sylvinus/agent-vm/internal/paths"
)

// A project file reached through a link, on Windows, on any host:
// paths.Windows on and, from a temporary folder, C:/... a relative path.
// The walk starts at the drive.
func TestProjectRelWindows(t *testing.T) {
	old := paths.Windows
	paths.Windows = func() bool { return true }
	t.Cleanup(func() { paths.Windows = old })
	t.Chdir(t.TempDir())
	os.MkdirAll("C:/p", 0o755)
	os.Symlink("p", "C:/link")
	for target, want := range map[string]string{"C:/p/.env": ".env", "C:/link/.env": ".env", "C:/link/sub/x": "sub/x"} {
		if rel, ok := ProjectRel("C:/p", target); !ok || rel != want {
			t.Errorf("ProjectRel(C:/p, %q) = %q, %v", target, rel, ok)
		}
	}
	if _, ok := ProjectRel("C:/p", "C:/other/.env"); ok {
		t.Error("C:/other is not in the project")
	}
}
