package host

import (
	"bytes"
	"strconv"
	"testing"

	"github.com/sylvinus/agent-vm/internal/bashref"
)

// The same values and notices as _agent_vm_cap_resource, on a host of 8
// CPUs and 16 GiB.
// setHost is a host of cpus CPUs and mem GiB, until the test ends.
func setHost(t *testing.T, cpus, mem int) {
	t.Helper()
	oc, om := CPUs, MemGiB
	t.Cleanup(func() { CPUs, MemGiB = oc, om })
	CPUs = func() int { return cpus }
	MemGiB = func() int { return mem }
}

func TestCapBash(t *testing.T) {
	setHost(t, 8, 16)
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
	setHost(t, 0, 16)
	if Cap("cpus", 64, nil) != 64 {
		t.Error("an unknown host clamped")
	}
}

// QEMU's package by the host's package manager, as the .deb and .rpm
// recommend it.
func TestQemuBinaryFor(t *testing.T) {
	for _, c := range []struct {
		goarch, manager string
		bin, cmd        string
	}{
		{"amd64", "apt-get", "qemu-system-x86_64", "sudo apt-get install qemu-system-x86"},
		{"arm64", "apt-get", "qemu-system-aarch64", "sudo apt-get install qemu-system-arm"},
		{"amd64", "dnf", "qemu-system-x86_64", "sudo dnf install qemu-system-x86-core qemu-img"},
		{"arm64", "dnf", "qemu-system-aarch64", "sudo dnf install qemu-system-aarch64-core qemu-img"},
		{"amd64", "", "qemu-system-x86_64", "your distribution's QEMU package (with Nix, 'nix run github:sylvinus/agent-vm' brings its own)"},
	} {
		if bin, cmd := qemuBinaryFor(c.goarch, c.manager); bin != c.bin || cmd != c.cmd {
			t.Errorf("%s %q: %s %q", c.goarch, c.manager, bin, cmd)
		}
	}
}
