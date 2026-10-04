//go:build dragonfly || freebsd || netbsd || openbsd || solaris || aix || js || zos
// +build dragonfly freebsd netbsd openbsd solaris aix js zos

package sftp

import "syscall"

// statAtime is not implemented here: the access time stays the modification time.
func statAtime(*syscall.Stat_t) (int64, bool) {
	return 0, false
}
