//go:build !windows

package env

import (
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"os"

	"golang.org/x/sys/unix"
)

// noFollow enters each folder with openat and O_NOFOLLOW, checking it is
// the one lstat saw, and opens the file with O_NOFOLLOW and O_NONBLOCK (a
// FIFO cannot hang it).
func noFollow(op, top, rel string, data []byte) ([]byte, error) {
	dirs, name, err := split(rel)
	if err != nil {
		return nil, err
	}
	if op == "mkdir" {
		dirs = append(dirs, name)
	}
	fd, err := unix.Open(top, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	defer func() { unix.Close(fd) }()
	for _, d := range dirs {
		var st unix.Stat_t
		err := unix.Fstatat(fd, d, &st, unix.AT_SYMLINK_NOFOLLOW)
		if errors.Is(err, unix.ENOENT) {
			if op == "read" {
				return nil, ErrNoFile
			}
			if err := unix.Mkdirat(fd, d, 0o777); err != nil && !errors.Is(err, unix.EEXIST) {
				return nil, err
			}
			err = unix.Fstatat(fd, d, &st, unix.AT_SYMLINK_NOFOLLOW)
		}
		if err != nil {
			return nil, err
		}
		if st.Mode&unix.S_IFMT != unix.S_IFDIR {
			return nil, ErrUnsafe
		}
		next, err := unix.Openat(fd, d, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if err != nil {
			return nil, ErrUnsafe
		}
		var in unix.Stat_t
		if err := unix.Fstat(next, &in); err != nil || in.Dev != st.Dev || in.Ino != st.Ino {
			unix.Close(next)
			return nil, ErrUnsafe
		}
		unix.Close(fd)
		fd = next
	}
	switch op {
	case "mkdir":
		return nil, nil
	case "touch":
		var st unix.Stat_t
		if err := unix.Fstatat(fd, name, &st, unix.AT_SYMLINK_NOFOLLOW); err == nil {
			if st.Mode&unix.S_IFMT == unix.S_IFREG {
				return nil, nil
			}
			return nil, ErrUnsafe
		}
		f, err := unix.Openat(fd, name, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0o666)
		if err != nil {
			return nil, err
		}
		return nil, unix.Close(f)
	case "read":
		f, err := unix.Openat(fd, name, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
		if errors.Is(err, unix.ENOENT) {
			return nil, ErrNoFile
		}
		if err != nil {
			return nil, ErrUnsafe
		}
		file := os.NewFile(uintptr(f), name)
		defer file.Close()
		if fi, err := file.Stat(); err != nil || !fi.Mode().IsRegular() {
			return nil, ErrUnsafe
		}
		return io.ReadAll(file)
	}
	// write: a new file, renamed over the old one.
	var tmp string
	f := -1
	for range 20 {
		tmp = fmt.Sprintf(".%s.agent-vm.%d.%d", name, os.Getpid(), rand.IntN(1e9))
		if f, err = unix.Openat(fd, tmp, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0o600); err == nil {
			break
		}
	}
	if f < 0 {
		return nil, err
	}
	file := os.NewFile(uintptr(f), tmp)
	_, werr := file.Write(data)
	cerr := file.Close()
	if err := errors.Join(werr, cerr); err != nil {
		unix.Unlinkat(fd, tmp, 0)
		return nil, err
	}
	if err := unix.Renameat(fd, tmp, fd, name); err != nil {
		unix.Unlinkat(fd, tmp, 0)
		return nil, err
	}
	return nil, nil
}
