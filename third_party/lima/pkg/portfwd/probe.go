// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package portfwd

import (
	"context"
	"fmt"
	"net"
	"path/filepath"
	"strconv"
)

// probeAddrs are the addresses a host program can serve a port on, such that a
// client of the host's loopback reaches it.
var probeAddrs = []string{"127.0.0.1", "::1", "0.0.0.0", "::"}

// inUse reports whether a program of the host already serves the port of
// hostAddress, on any of probeAddrs. The listener of a forward binds with
// SO_REUSEADDR, which BSD (macOS) lets bind 127.0.0.1:port next to a program
// listening on 0.0.0.0:port: the guest would take the host's loopback clients
// of that program. Each address is bound and closed at once, with the same
// options as the forward (Control), so that only a socket bound to that exact
// address, not one in TIME_WAIT, counts.
func inUse(ctx context.Context, protocol, hostAddress string) error {
	if filepath.IsAbs(hostAddress) {
		return nil
	}
	_, portStr, err := net.SplitHostPort(hostAddress)
	if err != nil {
		return nil
	}
	if port, err := strconv.Atoi(portStr); err != nil || port == 0 {
		return nil
	}
	lc := net.ListenConfig{Control: Control}
	for _, ip := range probeAddrs {
		addr := net.JoinHostPort(ip, portStr)
		var err error
		switch protocol {
		case "tcp":
			var l net.Listener
			if l, err = lc.Listen(ctx, "tcp", addr); err == nil {
				l.Close()
			}
		case "udp":
			var c net.PacketConn
			if c, err = lc.ListenPacket(ctx, "udp", addr); err == nil {
				c.Close()
			}
		default:
			return nil
		}
		// Other errors (no IPv6, a privileged port) say nothing of the port.
		if err != nil && addrInUse(err) {
			return fmt.Errorf("%s port %s is in use on the host (%s)", protocol, portStr, addr)
		}
	}
	return nil
}
