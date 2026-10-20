//go:build !windows

// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package qemu

import (
	"net"
	"testing"

	"gotest.tools/v3/assert"
)

// Each write is one datagram, both ways, and QEMU's end is a file that stays
// usable once ours is a net.Conn.
func TestDgramPair(t *testing.T) {
	ours, qemu, err := dgramPair()
	assert.NilError(t, err)
	t.Cleanup(func() { ours.Close(); qemu.Close() })
	theirs, err := net.FileConn(qemu)
	assert.NilError(t, err)
	t.Cleanup(func() { theirs.Close() })

	for _, c := range []struct{ from, to net.Conn }{{ours, theirs}, {theirs, ours}} {
		_, err = c.from.Write([]byte("abc"))
		assert.NilError(t, err)
		_, err = c.from.Write([]byte("defgh"))
		assert.NilError(t, err)
		buf := make([]byte, 64)
		n, err := c.to.Read(buf)
		assert.NilError(t, err)
		assert.Equal(t, string(buf[:n]), "abc")
		n, err = c.to.Read(buf)
		assert.NilError(t, err)
		assert.Equal(t, string(buf[:n]), "defgh")
	}
}

// fd_dgram hands QEMU the datagram socket as the next file descriptor, after
// those fd_connect made.
func TestFdDgramTemplate(t *testing.T) {
	_, qemu, err := dgramPair()
	assert.NilError(t, err)
	t.Cleanup(func() { qemu.Close() })

	a := &qArgTemplateApplier{dgram: qemu}
	got, err := a.applyTemplate("dgram,id=net0,local.type=fd,local.str={{ fd_dgram }}")
	assert.NilError(t, err)
	assert.Equal(t, got, "dgram,id=net0,local.type=fd,local.str=3")
	assert.DeepEqual(t, len(a.files), 1)
	assert.Equal(t, a.files[0], qemu)

	_, err = (&qArgTemplateApplier{}).applyTemplate("{{ fd_dgram }}")
	assert.ErrorContains(t, err, "no datagram socket")
}
