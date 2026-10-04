//go:build !windows

package cli

import (
	"errors"
	"syscall"
)

// alive reports whether the process pid exists: signal 0 reaches it, or it
// belongs to someone else.
func alive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
