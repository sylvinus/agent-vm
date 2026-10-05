package vm

import (
	"os"
	"runtime"
	"testing"

	limaversion "github.com/lima-vm/lima/v2/pkg/version"

	"github.com/sylvinus/agent-vm/internal/limaembed"
)

// Lima starts its hostagent as this executable: the test binary, here.
// It is not stamped with Lima's version, as the Makefile's builds are.
func TestMain(m *testing.M) {
	limaversion.Version = "v2.3.0-test"
	// macOS's TMPDIR (/var/folders/...) is too long for Lima's socket
	// paths (104 bytes); real Lima homes are short.
	if runtime.GOOS == "darwin" {
		os.Setenv("TMPDIR", "/tmp")
	}
	if limaembed.Run(os.Args[1:]) {
		return
	}
	os.Exit(m.Run())
}
