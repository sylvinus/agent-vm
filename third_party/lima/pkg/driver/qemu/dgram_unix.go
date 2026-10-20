//go:build !windows

// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package qemu

import (
	"net"
	"os"
	"syscall"
)

// dgramPair returns the two ends of a connected datagram socket, as vz does
// for its network: ours as a net.Conn for the netstack, and QEMU's as a file
// to pass to it (-netdev dgram,local.type=fd). A datagram is a frame, and
// unix datagram sockets neither lose nor reorder them: a full buffer blocks
// the sender.
func dgramPair() (ours net.Conn, qemu *os.File, err error) {
	// The descriptors must not leak into the processes started meanwhile:
	// QEMU gets its end through ExtraFiles.
	syscall.ForkLock.RLock()
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_DGRAM, 0)
	if err == nil {
		syscall.CloseOnExec(fds[0])
		syscall.CloseOnExec(fds[1])
	}
	syscall.ForkLock.RUnlock()
	if err != nil {
		return nil, nil, err
	}
	for _, fd := range fds {
		// Best effort: the kernel caps these (net.core.wmem_max, rmem_max).
		_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_SNDBUF, 1<<20)
		_ = syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_RCVBUF, 4<<20)
	}
	f := os.NewFile(uintptr(fds[0]), "usernet-dgram")
	defer f.Close()
	ours, err = net.FileConn(f)
	if err != nil {
		syscall.Close(fds[1])
		return nil, nil, err
	}
	return ours, os.NewFile(uintptr(fds[1]), "qemu-dgram"), nil
}
