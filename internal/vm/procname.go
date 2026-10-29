package vm

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/lima-vm/lima/v2/pkg/limatype"
	"github.com/lima-vm/lima/v2/pkg/limatype/filenames"
)

// isQEMU reports whether pid is the QEMU of the VM name, whose files are in
// dir: its command line has the -name and -pidfile Lima gave it. A PID file
// outlives a QEMU that aborted, and its number may belong to another program
// or another VM by now: that one must not be killed.
func isQEMU(pid int, dir, name string) bool {
	var args string
	switch runtime.GOOS {
	case "linux":
		b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/cmdline")
		if err != nil {
			return false
		}
		args = strings.ReplaceAll(string(b), "\x00", " ")
	case "windows":
		out, err := exec.Command("powershell", "-NoProfile", "-Command",
			"(Get-CimInstance Win32_Process -Filter 'ProcessId="+strconv.Itoa(pid)+"').CommandLine").Output()
		if err != nil {
			return false
		}
		args = string(out)
	default:
		out, err := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "args=").Output()
		if err != nil {
			return false
		}
		args = string(out)
	}
	// Padded, so that an option is matched whole.
	args = " " + strings.TrimSpace(args) + " "
	pidfile := filepath.Join(dir, filenames.PIDFile(string(limatype.QEMU)))
	prog, _, found := strings.Cut(args, " -name lima-"+name+" ")
	return found && strings.Contains(strings.ToLower(prog), "qemu") &&
		strings.Contains(args, " -pidfile "+pidfile+" ")
}
