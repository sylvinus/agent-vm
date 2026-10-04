package host

import (
	"bytes"
	"strconv"
	"testing"

	"github.com/sylvinus/agent-vm/internal/bashref"
)

// The same values and notices as _agent_vm_cap_resource, on a host of 8
// CPUs and 16 GiB.
func TestCapBash(t *testing.T) {
	CPUs = func() int { return 8 }
	MemGiB = func() int { return 16 }
	stub := `_agent_vm_host_cpus() { echo 8; }; _agent_vm_host_mem_gib() { echo 16; }; _agent_vm_cap_resource "$@"`
	for _, share := range []string{"", "1", "4", "0", "x", "08"} {
		var env []string
		if share != "" {
			t.Setenv("AGENT_VM_HOST_SHARE", share)
			env = []string{"AGENT_VM_HOST_SHARE=" + share}
		}
		for _, kind := range []string{"cpus", "memory"} {
			for _, v := range []int{1, 2, 3, 4, 5, 8, 9, 16, 64} {
				var warn bytes.Buffer
				got := Cap(kind, v, &warn)
				r := bashref.Script(t, "", env, stub, kind, strconv.Itoa(v))
				if strconv.Itoa(got)+"\n" != r.Stdout || warn.String() != r.Stderr {
					t.Errorf("share %q, %s %d: %d %q, bash %q %q", share, kind, v, got, warn.String(), r.Stdout, r.Stderr)
				}
			}
		}
	}
	if Cap("cpus", 0, nil) != 0 {
		t.Error("nothing asked")
	}
	CPUs = func() int { return 0 }
	if Cap("cpus", 64, nil) != 64 {
		t.Error("an unknown host clamped")
	}
}
