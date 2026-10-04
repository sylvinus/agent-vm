package version

import (
	"testing"

	"github.com/sylvinus/agent-vm/internal/bashref"
)

var atLeastCases = []struct {
	have, want string
	ok         bool
}{
	{"0.2.1", "0.2.0", true},
	{"0.2.0", "0.2.0", true},
	{"0.2.0", "0.2.1", false},
	{"0.10.0", "0.2.0", true},
	{"0.2.0", "0.10.0", false},
	{"1.2", "1.2.0", true},
	{"1.2.0", "1.2", true},
	{"1.2", "1.2.1", false},
	{"0.3.0-dev", "0.3.0", true},
	{"0.3.0", "0.3.0-rc.1", true},
	{"0.2.0", "18446744073709551616", false},
	{"18446744073709551617", "18446744073709551616", true},
	{"01.002", "1.2", true},
	{"1.x2", "1.2", true},
	{"", "0", true},
	{"", "1", false},
}

func TestAtLeast(t *testing.T) {
	for _, c := range atLeastCases {
		if got := AtLeast(c.have, c.want); got != c.ok {
			t.Errorf("AtLeast(%q, %q) = %v", c.have, c.want, got)
		}
	}
}

// The same answers as _agent_vm_ver_ge.
func TestAtLeastBash(t *testing.T) {
	for _, c := range atLeastCases {
		r := bashref.Run(t, "", nil, "_agent_vm_ver_ge", c.have, c.want)
		if (r.Code == 0) != c.ok {
			t.Errorf("_agent_vm_ver_ge %q %q: status %d, Go says %v", c.have, c.want, r.Code, c.ok)
		}
	}
}
