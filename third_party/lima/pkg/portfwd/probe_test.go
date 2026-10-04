// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package portfwd

import (
	"context"
	"net"
	"strconv"
	"testing"

	"gotest.tools/v3/assert"

	"github.com/lima-vm/lima/v2/pkg/guestagent/api"
	"github.com/lima-vm/lima/v2/pkg/hostagent/events"
	"github.com/lima-vm/lima/v2/pkg/limatype"
	"github.com/lima-vm/lima/v2/pkg/limayaml"
)

// A port a program of the host serves, on any address its loopback clients
// reach, is not forwarded: the guest would take those clients.
func TestForwardNotNextToHostProgram(t *testing.T) {
	for _, hostIP := range []string{"0.0.0.0", "127.0.0.1", "::1"} {
		t.Run(hostIP, func(t *testing.T) {
			host, err := net.Listen("tcp", net.JoinHostPort(hostIP, "0"))
			if err != nil {
				t.Skipf("cannot listen on %s: %v", hostIP, err)
			}
			defer host.Close()
			port := host.Addr().(*net.TCPAddr).Port

			rule := limatype.PortForward{}
			limayaml.FillPortForwardDefaults(&rule, "", limatype.User{}, nil)
			var got []*events.PortForwardEvent
			fw := NewPortForwarder([]limatype.PortForward{rule}, false, false, func(ev *events.PortForwardEvent) { got = append(got, ev) })
			defer fw.Close()
			fw.OnEvent(context.Background(), nil, &api.Event{AddedLocalPorts: []*api.IPPort{{Ip: "127.0.0.1", Port: int32(port), Protocol: "tcp"}}})

			assert.Equal(t, len(got), 1)
			assert.Equal(t, got[0].Type, events.PortForwardEventFailed)
			assert.Assert(t, !fw.closableListeners.has("tcp", got[0].HostAddr, got[0].GuestAddr))
			// The host's program still has its port.
			c, err := net.Dial("tcp", host.Addr().String())
			assert.NilError(t, err)
			c.Close()
		})
	}
}

// A free port is forwarded as before.
func TestForwardFreePort(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	assert.NilError(t, err)
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()

	rule := limatype.PortForward{}
	limayaml.FillPortForwardDefaults(&rule, "", limatype.User{}, nil)
	var got []*events.PortForwardEvent
	fw := NewPortForwarder([]limatype.PortForward{rule}, false, false, func(ev *events.PortForwardEvent) { got = append(got, ev) })
	defer fw.Close()
	fw.OnEvent(context.Background(), nil, &api.Event{AddedLocalPorts: []*api.IPPort{{Ip: "127.0.0.1", Port: int32(port), Protocol: "tcp"}}})
	assert.Equal(t, len(got), 1)
	assert.Equal(t, got[0].Type, events.PortForwardEventForwarding)
	assert.Equal(t, got[0].HostAddr, net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
}
