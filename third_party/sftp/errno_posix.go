//go:build !plan9
// +build !plan9

package sftp

import (
	"errors"
	"io/fs"
	"os"
	"syscall"
)

const EBADF = syscall.EBADF

func wrapPathError(filepath string, err error) error {
	if errno, ok := err.(syscall.Errno); ok {
		return &os.PathError{Path: filepath, Err: errno}
	}
	return err
}

// translateErrno translates a syscall error number to a SFTP error code,
// as OpenSSH's errno_to_portable does.
func translateErrno(errno syscall.Errno) uint32 {
	switch errno {
	case 0:
		return sshFxOk
	case syscall.ENOENT, syscall.ENOTDIR, syscall.ELOOP:
		return sshFxNoSuchFile
	case syscall.EACCES, syscall.EPERM:
		return sshFxPermissionDenied
	case syscall.ENAMETOOLONG, syscall.EINVAL:
		return sshFxBadMessage
	case syscall.ENOSYS:
		return sshFxOPUnsupported
	}
	// Errors of other systems with the same meaning, such as ERROR_ACCESS_DENIED on Windows.
	switch {
	case errors.Is(errno, fs.ErrNotExist):
		return sshFxNoSuchFile
	case errors.Is(errno, fs.ErrPermission):
		return sshFxPermissionDenied
	}
	return sshFxFailure
}

// translateSyscallError finds a syscall.Errno in err, also wrapped in an
// *os.PathError, *os.LinkError or *os.SyscallError.
func translateSyscallError(err error) (uint32, bool) {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		debug("statusFromError: errno %#v in %T", errno, err)
		return translateErrno(errno), true
	}
	return 0, false
}
