package cli

import (
	"os"
	"testing"

	limaversion "github.com/lima-vm/lima/v2/pkg/version"

	"github.com/sylvinus/agent-vm/internal/limaembed"
)

// Lima starts its hostagent as this executable: the test binary, here.
// It is not stamped with Lima's version, as the Makefile's builds are.
func TestMain(m *testing.M) {
	limaversion.Version = "v2.3.0-test"
	if limaembed.Run(os.Args[1:]) {
		return
	}
	os.Exit(m.Run())
}
