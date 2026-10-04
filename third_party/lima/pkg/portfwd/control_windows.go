// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package portfwd

import (
	"errors"
	"syscall"

	"golang.org/x/sys/windows"
)

// soExclusiveAddrUse is SO_EXCLUSIVEADDRUSE, ~SO_REUSEADDR in winsock2.h. On
// Windows, SO_REUSEADDR lets a socket bind an address another program is
// listening on, and take its connections: exclusive use is what other systems
// do by default.
const soExclusiveAddrUse = ^windows.SO_REUSEADDR

func Control(_, _ string, c syscall.RawConn) (err error) {
	controlErr := c.Control(func(fd uintptr) {
		err = windows.SetsockoptInt(windows.Handle(int(fd)), windows.SOL_SOCKET, soExclusiveAddrUse, 1)
	})
	if controlErr != nil {
		err = controlErr
	}
	return err
}

func addrInUse(err error) bool {
	return errors.Is(err, windows.WSAEADDRINUSE) || errors.Is(err, windows.WSAEACCES)
}
