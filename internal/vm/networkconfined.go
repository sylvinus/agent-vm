package vm

import (
	"errors"
	"fmt"

	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype"
)

// ErrNetworkOpen is returned by Start for a VM with a network besides its own
// isolated one: the network policy (netguard) applies to the connections of
// the VM's own netstack only.
var ErrNetworkOpen = errors.New("agent-vm starts no VM with a network besides its own")

// NetworkConfined fails when cfg gives the guest a network of Lima's `networks`
// (a shared usernet, a socket, vzNAT, a vmnet one): its traffic does not go
// through the netstack that the policy is applied to.
func NetworkConfined(cfg *limatype.LimaYAML) error {
	for i, n := range cfg.Networks {
		what := "a network"
		switch {
		case n.Lima != "":
			what = fmt.Sprintf("the shared network %q", n.Lima)
		case n.Socket != "":
			what = fmt.Sprintf("the socket %q", n.Socket)
		case n.VZNAT != nil && *n.VZNAT:
			what = "vzNAT"
		}
		return fmt.Errorf("%w: networks[%d] is %s", ErrNetworkOpen, i, what)
	}
	return nil
}
