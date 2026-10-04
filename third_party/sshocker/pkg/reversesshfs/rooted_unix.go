//go:build linux || darwin

package reversesshfs

import (
	"errors"
	"os"
	"path"
	"path/filepath"
	"strings"

	"github.com/pkg/sftp"
	"golang.org/x/sys/unix"
)

var errDenied error = unix.EACCES

// openNonblock: see openRead.
const openNonblock = unix.O_NONBLOCK

// appendWrite writes b at the end of f, which openFile opened with O_APPEND.
// pwrite(2) would honor its offset on macOS.
func appendWrite(f *os.File, b []byte) (int, error) {
	return f.Write(b)
}

type rootedSys struct {
	rootFD int
}

func openRootedSys(localPath string) (rootedSys, error) {
	rootFD, err := unix.Open(localPath, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return rootedSys{}, &os.PathError{Op: "open", Path: localPath, Err: err}
	}
	return rootedSys{rootFD: rootFD}, nil
}

func (s rootedSys) close() error {
	return unix.Close(s.rootFD)
}

// slashPath returns the request path of the host path p.
func slashPath(p string) string {
	return path.Clean(filepath.ToSlash(p))
}

func startDirectory(rootPath string) string {
	return rootPath
}

func realPath(rootPath, p string) string {
	if !path.IsAbs(p) {
		p = path.Join(rootPath, p)
	}
	return path.Clean(p)
}

func writableName(string) bool {
	return true
}

// openParent returns a directory fd for the parent of rel, and the base name.
// The caller must close the fd.
func (h *rootedHandlers) openParent(rel string) (int, string, error) {
	fd, err := unix.Dup(h.rootFD)
	if err != nil {
		return -1, "", err
	}
	if rel == "." {
		return fd, ".", nil
	}
	dir, base := path.Split(rel)
	if dir != "" {
		for _, c := range strings.Split(strings.TrimSuffix(dir, "/"), "/") {
			if c == "" || c == "." || c == ".." {
				unix.Close(fd)
				return -1, "", unix.EACCES
			}
			next, err := unix.Openat(fd, c, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC|unix.O_NONBLOCK, 0)
			unix.Close(fd)
			if err != nil {
				return -1, "", err
			}
			fd = next
		}
	}
	return fd, base, nil
}

func (h *rootedHandlers) openFile(r *sftp.Request) (*os.File, error) {
	rel, err := h.writableRel(r.Filepath)
	if err != nil {
		return nil, err
	}
	pf := r.Pflags()
	flags := unix.O_NOFOLLOW | unix.O_CLOEXEC
	switch {
	case pf.Read && (pf.Write || pf.Append):
		flags |= unix.O_RDWR
	case pf.Write || pf.Append:
		flags |= unix.O_WRONLY
	default:
		flags |= unix.O_RDONLY
	}
	// See writableFile.WriteAt.
	if pf.Append {
		flags |= unix.O_APPEND
	}
	if pf.Creat {
		flags |= unix.O_CREAT
	}
	if pf.Trunc {
		flags |= unix.O_TRUNC
	}
	if pf.Excl {
		flags |= unix.O_EXCL
	}
	var mode uint32 = 0o644
	if m, ok := openMode(r); ok {
		mode = m
	}
	dirfd, base, err := h.openParent(rel)
	if err != nil {
		return nil, err
	}
	defer unix.Close(dirfd)
	// O_NONBLOCK: a FIFO would block the server, which handles one request at a time.
	// It has no effect on regular files, the only ones served.
	fd, err := unix.Openat(dirfd, base, flags|unix.O_NONBLOCK, mode)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: r.Filepath, Err: err}
	}
	var st unix.Stat_t
	if err := unix.Fstat(fd, &st); err != nil || st.Mode&unix.S_IFMT != unix.S_IFREG {
		unix.Close(fd)
		if err == nil {
			err = errDenied
		}
		return nil, &os.PathError{Op: "open", Path: r.Filepath, Err: err}
	}
	return os.NewFile(uintptr(fd), r.Filepath), nil
}

// inParent calls f with the parent directory fd and the base name of the writable path p.
func (h *rootedHandlers) inParent(op, p string, f func(dirfd int, base string) error) error {
	rel, err := h.writableRel(p)
	if err != nil {
		return err
	}
	dirfd, base, err := h.openParent(rel)
	if err != nil {
		return err
	}
	defer unix.Close(dirfd)
	if err := f(dirfd, base); err != nil {
		return &os.PathError{Op: op, Path: p, Err: err}
	}
	return nil
}

func (h *rootedHandlers) remove(r *sftp.Request) error {
	var flags int
	if r.Method == "Rmdir" {
		flags = unix.AT_REMOVEDIR
	}
	return h.inParent(strings.ToLower(r.Method), r.Filepath, func(dirfd int, base string) error {
		return unix.Unlinkat(dirfd, base, flags)
	})
}

func (h *rootedHandlers) mkdir(r *sftp.Request) error {
	var mode uint32 = 0o755
	if a := r.Attributes(); a != nil && r.AttrFlags().Permissions {
		mode = a.Mode & 0o7777
	}
	return h.inParent("mkdir", r.Filepath, func(dirfd int, base string) error {
		return unix.Mkdirat(dirfd, base, mode)
	})
}

// symlink has the link target in Filepath and the link path in Target.
func (h *rootedHandlers) symlink(r *sftp.Request) error {
	return h.inParent("symlink", r.Target, func(dirfd int, base string) error {
		return unix.Symlinkat(r.Filepath, dirfd, base)
	})
}

func (h *rootedHandlers) link(r *sftp.Request) error {
	return h.twoPaths(r.Filepath, r.Target, func(oldfd int, oldBase string, newfd int, newBase string) error {
		return unix.Linkat(oldfd, oldBase, newfd, newBase, 0)
	})
}

func (h *rootedHandlers) rename(r *sftp.Request, noReplace bool) error {
	return h.twoPaths(r.Filepath, r.Target, func(oldfd int, oldBase string, newfd int, newBase string) error {
		if noReplace {
			err := renameNoReplace(oldfd, oldBase, newfd, newBase)
			if !errors.Is(err, unix.EINVAL) && !errors.Is(err, unix.ENOSYS) && !errors.Is(err, unix.ENOTSUP) && !errors.Is(err, unix.EOPNOTSUPP) {
				return err
			}
			// The file system cannot do it atomically.
			var st unix.Stat_t
			if err := unix.Fstatat(newfd, newBase, &st, unix.AT_SYMLINK_NOFOLLOW); err == nil {
				return os.ErrExist
			}
		}
		return unix.Renameat(oldfd, oldBase, newfd, newBase)
	})
}

func (h *rootedHandlers) twoPaths(oldPath, newPath string, f func(oldfd int, oldBase string, newfd int, newBase string) error) error {
	oldRel, err := h.writableRel(oldPath)
	if err != nil {
		return err
	}
	newRel, err := h.writableRel(newPath)
	if err != nil {
		return err
	}
	oldfd, oldBase, err := h.openParent(oldRel)
	if err != nil {
		return err
	}
	defer unix.Close(oldfd)
	newfd, newBase, err := h.openParent(newRel)
	if err != nil {
		return err
	}
	defer unix.Close(newfd)
	if err := f(oldfd, oldBase, newfd, newBase); err != nil {
		return &os.LinkError{Op: "rename", Old: oldPath, New: newPath, Err: err}
	}
	return nil
}

func (h *rootedHandlers) setstat(r *sftp.Request) error {
	rel, err := h.writableRel(r.Filepath)
	if err != nil {
		return err
	}
	flags := r.AttrFlags()
	attrs := r.Attributes()
	if attrs == nil {
		return unix.EINVAL
	}
	dirfd, base, err := h.openParent(rel)
	if err != nil {
		return err
	}
	defer unix.Close(dirfd)
	if flags.Size {
		fd, err := unix.Openat(dirfd, base, unix.O_WRONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC|unix.O_NONBLOCK, 0)
		if err != nil {
			return &os.PathError{Op: "truncate", Path: r.Filepath, Err: err}
		}
		err = unix.Ftruncate(fd, int64(attrs.Size))
		unix.Close(fd)
		if err != nil {
			return &os.PathError{Op: "truncate", Path: r.Filepath, Err: err}
		}
	}
	if flags.Permissions {
		if err := fchmodatNoFollow(dirfd, base, attrs.Mode&0o7777); err != nil {
			return &os.PathError{Op: "chmod", Path: r.Filepath, Err: err}
		}
	}
	if flags.UidGid {
		if err := unix.Fchownat(dirfd, base, int(attrs.UID), int(attrs.GID), unix.AT_SYMLINK_NOFOLLOW); err != nil {
			return &os.PathError{Op: "chown", Path: r.Filepath, Err: err}
		}
	}
	if flags.Acmodtime {
		ts := []unix.Timespec{
			unix.NsecToTimespec(int64(attrs.Atime) * 1e9),
			unix.NsecToTimespec(int64(attrs.Mtime) * 1e9),
		}
		if err := unix.UtimesNanoAt(dirfd, base, ts, unix.AT_SYMLINK_NOFOLLOW); err != nil {
			return &os.PathError{Op: "chtimes", Path: r.Filepath, Err: err}
		}
	}
	return nil
}

// fsetstat applies a FSETSTAT to the file f of the handle.
func (h *rootedHandlers) fsetstat(f *os.File, r *sftp.Request) error {
	flags := r.AttrFlags()
	attrs := r.Attributes()
	if attrs == nil {
		return unix.EINVAL
	}
	fd := int(f.Fd())
	if flags.Size {
		if err := unix.Ftruncate(fd, int64(attrs.Size)); err != nil {
			return &os.PathError{Op: "truncate", Path: f.Name(), Err: err}
		}
	}
	if flags.Permissions {
		if err := unix.Fchmod(fd, attrs.Mode&0o7777); err != nil {
			return &os.PathError{Op: "chmod", Path: f.Name(), Err: err}
		}
	}
	if flags.UidGid {
		if err := unix.Fchown(fd, int(attrs.UID), int(attrs.GID)); err != nil {
			return &os.PathError{Op: "chown", Path: f.Name(), Err: err}
		}
	}
	if flags.Acmodtime {
		tv := []unix.Timeval{
			unix.NsecToTimeval(int64(attrs.Atime) * 1e9),
			unix.NsecToTimeval(int64(attrs.Mtime) * 1e9),
		}
		if err := unix.Futimes(fd, tv); err != nil {
			return &os.PathError{Op: "chtimes", Path: f.Name(), Err: err}
		}
	}
	return nil
}

// StatVFS implements sftp.StatVFSFileCmder.
func (h *rootedHandlers) StatVFS(r *sftp.Request) (*sftp.StatVFS, error) {
	if _, err := h.rel(r.Filepath); err != nil {
		return nil, err
	}
	var st unix.Statfs_t
	if err := unix.Fstatfs(h.rootFD, &st); err != nil {
		return nil, err
	}
	return statVFS(&st), nil
}
