// Package host is what this machine can give a VM.
package host

import (
	"fmt"
	"io"
	"os"
	"regexp"
	"runtime"
	"strconv"

	"github.com/pbnjay/memory"
)

// A VM handed more CPU or RAM than the host can spare makes the host
// unusable while the agent runs, unattended, for a while. So a --cpus or
// --memory above this host's share is clamped to it, out loud. The share is
// half the host by default: a policy, which AGENT_VM_HOST_SHARE overrides
// (1: the whole host).

// CPUs is the host's CPU count, 0 when it cannot be told.
var CPUs = func() int { return runtime.NumCPU() }

// MemGiB is the host's RAM in GiB, 0 when it cannot be told.
var MemGiB = func() int { return int(memory.TotalMemory() >> 30) }

var positiveRe = regexp.MustCompile(`^[1-9][0-9]*$`)

// Divisor is the number the host's resources are divided by to get a VM's
// share: AGENT_VM_HOST_SHARE, or 2 when it is unset or is not a positive
// integer. In the second case invalid is true and bad is what the variable
// holds.
func Divisor() (div int, bad string, invalid bool) {
	s, ok := os.LookupEnv("AGENT_VM_HOST_SHARE")
	if !ok {
		return 2, "", false
	}
	if n, err := strconv.Atoi(s); err == nil && positiveRe.MatchString(s) {
		return n, "", false
	}
	return 2, s, true
}

// share is the share of total this host gives a VM, never below floor.
func share(total, floor int, warn io.Writer) int {
	div, bad, invalid := Divisor()
	if invalid {
		fmt.Fprintf(warn, "Warning: AGENT_VM_HOST_SHARE='%s' is not a positive integer; using 2.\n", bad)
	}
	return max(total/div, floor)
}

// Cap is the value of --cpus (kind "cpus") or --memory ("memory", GiB) to
// apply: above this host's share, clamped, with a notice; else as asked. 0
// (nothing asked) and a host that cannot be read leave it alone: guessing
// low would hand a 1-CPU VM to a 64-core host.
func Cap(kind string, val int, warn io.Writer) int {
	return capWith(func(total, floor int) int { return share(total, floor, warn) }, kind, val, warn)
}

// CapShare is Cap with the divisor given (0: 2): for a program that reads no
// environment variable.
func CapShare(div int, kind string, val int, warn io.Writer) int {
	if div <= 0 {
		div = 2
	}
	return capWith(func(total, floor int) int { return max(total/div, floor) }, kind, val, warn)
}

func capWith(share func(total, floor int) int, kind string, val int, warn io.Writer) int {
	if val == 0 {
		return 0
	}
	total, floor := 0, 0
	switch kind {
	case "cpus":
		total, floor = CPUs(), 1
	case "memory":
		total, floor = MemGiB(), 2
	default:
		return val
	}
	if total <= 0 {
		return val
	}
	if s := share(total, floor); val > s {
		fmt.Fprintf(warn, "Note: --%s %d exceeds this host's share (%d detected); using %d.\n", kind, val, total, s)
		return s
	}
	return val
}

// WarnDiskSpace warns when the file system of dir has less free space than
// a disk of want GiB. Disks are sparse, allocated as they fill: a warning,
// not an error.
func WarnDiskSpace(dir string, want int, warn io.Writer) {
	if want == 0 {
		return
	}
	if _, err := os.Stat(dir); err != nil {
		if h, err := os.UserHomeDir(); err == nil {
			dir = h
		}
	}
	free, ok := FreeGiB(dir)
	if ok && free < want {
		fmt.Fprintf(warn, "Warning: ~%d GiB free for a %d GiB VM disk (sparse: allocated as used).\n", free, want)
	}
}
