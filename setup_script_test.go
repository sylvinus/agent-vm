package agentvm

import (
	"os/exec"
	"runtime"
	"testing"
)

// tests/setup-script.sh: the setup script's blocks, run against stubs.
func TestSetupScript(t *testing.T) {
	runScript(t, "tests/setup-script.sh")
}

// tests/installer.sh: the curl installer and agent-vm.sh, against stub
// releases and a stub clone.
func TestInstaller(t *testing.T) {
	runScript(t, "tests/installer.sh")
}

// tests/release.sh: release.sh's dry runs, against a throwaway repository.
func TestRelease(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	runScript(t, "tests/release.sh")
}

func runScript(t *testing.T, script string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("runs in a Linux guest, or on macOS and Linux")
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("no bash")
	}
	out, err := exec.Command(bash, script).CombinedOutput()
	if err != nil {
		t.Errorf("%v\n%s", err, out)
	}
}
