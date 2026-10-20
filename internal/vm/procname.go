package vm

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

// isQEMU reports whether pid is a QEMU process. A PID file outlives a QEMU
// that aborted, and its number may belong to another program by now: that one
// must not be killed.
func isQEMU(pid int) bool {
	var name string
	switch runtime.GOOS {
	case "linux":
		// The kernel's name for it, cut to 15 characters: "qemu-system-x86".
		b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/comm")
		if err != nil {
			return false
		}
		name = string(b)
	case "windows":
		out, err := exec.Command("tasklist", "/FI", "PID eq "+strconv.Itoa(pid), "/FO", "CSV", "/NH").Output()
		if err != nil {
			return false
		}
		name = strings.Trim(strings.SplitN(string(out), ",", 2)[0], `"`)
	default:
		out, err := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "comm=").Output()
		if err != nil {
			return false
		}
		name = string(out)
	}
	return strings.HasPrefix(strings.ToLower(filepath.Base(strings.TrimSpace(name))), "qemu")
}
