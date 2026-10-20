// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package qemu

import (
	"errors"
	"net"
	"os"
)

// dgramPair: Windows has no unix datagram sockets, and cannot pass a file
// descriptor to QEMU.
func dgramPair() (net.Conn, *os.File, error) {
	return nil, nil, errors.ErrUnsupported
}
