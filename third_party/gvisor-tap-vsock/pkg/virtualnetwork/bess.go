package virtualnetwork

import (
	"context"
	"net"

	"github.com/sylvinus/agent-vm/third_party/gvisor-tap-vsock/pkg/types"
)

func (n *VirtualNetwork) AcceptBess(ctx context.Context, conn net.Conn) error {
	return n.networkSwitch.Accept(ctx, conn, types.BessProtocol)
}
