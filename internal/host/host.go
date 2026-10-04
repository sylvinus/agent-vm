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

// share is the share of total this host gives a VM, never below floor.
func share(total, floor int, warn io.Writer) int {
	div := 2
	if s, ok := os.LookupEnv("AGENT_VM_HOST_SHARE"); ok {
		if n, err := strconv.Atoi(s); err == nil && positiveRe.MatchString(s) {
			div = n
		} else {
			fmt.Fprintf(warn, "Warning: AGENT_VM_HOST_SHARE='%s' is not a positive integer; using 2.\n", s)
		}
	}
	return max(total/div, floor)
}

// Cap is the value of --cpus (kind "cpus") or --memory ("memory", GiB) to
// apply: above this host's share, clamped, with a notice; else as asked. 0
// (nothing asked) and a host that cannot be read leave it alone: guessing
// low would hand a 1-CPU VM to a 64-core host.
func Cap(kind string, val int, warn io.Writer) int {
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
	if s := share(total, floor, warn); val > s {
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
