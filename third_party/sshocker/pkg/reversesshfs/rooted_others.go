//go:build !linux && !darwin && !windows

package reversesshfs

import (
	"errors"
	"io"

	"github.com/sylvinus/agent-vm/third_party/sftp"
)

type rootedHandlers struct{}

func newRootedServer(io.ReadWriteCloser, string, bool, []string) (*sftp.RequestServer, *rootedHandlers, error) {
	return nil, nil, errors.New("the rooted builtin sftp server is supported only on Linux, macOS, and Windows")
}

func (*rootedHandlers) Close() error { return nil }

func (*rootedHandlers) expectRemove(string) bool { return false }
