//go:build !windows

// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package usernet

import (
	"bytes"
	"context"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"gotest.tools/v3/assert"
)

// A frame sent as a datagram is served by the netstack, and the answer comes
// back as one: an ARP request for the gateway gets its reply.
func TestDgramConn(t *testing.T) {
	dir, err := os.MkdirTemp("", "usernet")
	assert.NilError(t, err)
	t.Cleanup(func() { os.RemoveAll(dir) })

	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_DGRAM, 0)
	assert.NilError(t, err)
	serverFile, peerFile := os.NewFile(uintptr(fds[0]), "server"), os.NewFile(uintptr(fds[1]), "peer")
	server, err := net.FileConn(serverFile)
	assert.NilError(t, err)
	peer, err := net.FileConn(peerFile)
	assert.NilError(t, err)
	serverFile.Close()
	peerFile.Close()
	t.Cleanup(func() { peer.Close() })

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	err = StartGVisorNetstack(ctx, &GVisorNetstackOpts{
		MTU:       1500,
		Endpoint:  filepath.Join(dir, "ep.sock"),
		DgramConn: server,
		Async:     true,
		Subnet:    "192.168.5.0/24",
	})
	assert.NilError(t, err)

	guestMAC := net.HardwareAddr{0x52, 0x54, 0x00, 0x00, 0x00, 0x01}
	gatewayMAC, err := net.ParseMAC(gatewayMacAddr)
	assert.NilError(t, err)
	arp := bytes.Join([][]byte{
		{0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, guestMAC, {0x08, 0x06}, // Ethernet: broadcast, ARP
		{0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01}, // Ethernet, IPv4, request
		guestMAC, {192, 168, 5, 15},
		make([]byte, 6), {192, 168, 5, 2}, // who has the gateway
	}, nil)
	_, err = peer.Write(arp)
	assert.NilError(t, err)

	buf := make([]byte, 2048)
	assert.NilError(t, peer.SetReadDeadline(time.Now().Add(10*time.Second)))
	n, err := peer.Read(buf)
	assert.NilError(t, err)
	reply := buf[:n]
	assert.Assert(t, n >= 42, "frame of %d bytes", n)
	assert.DeepEqual(t, reply[0:6], []byte(guestMAC))
	assert.DeepEqual(t, reply[6:12], []byte(gatewayMAC))
	assert.DeepEqual(t, reply[12:14], []byte{0x08, 0x06})
	assert.DeepEqual(t, reply[20:22], []byte{0x00, 0x02}) // ARP reply

	// The connection ends with the netstack's context.
	cancel()
	assert.NilError(t, peer.SetWriteDeadline(time.Now().Add(10*time.Second)))
	_, err = peer.Write(arp)
	for i := 0; err == nil && i < 100; i++ {
		time.Sleep(50 * time.Millisecond)
		_, err = peer.Write(arp)
	}
	assert.ErrorContains(t, err, "")
}
