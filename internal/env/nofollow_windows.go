package env

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"math/rand/v2"
	"os"
	"path/filepath"
)

// noFollow on Windows checks each step with Lstat, a reparse point (a
// symlink, a junction) being refused, then works in an os.Root, which
// cannot be left. A swap between the check and the use is not caught here as
// it is on Unix.
func noFollow(op, top, rel string, data []byte) ([]byte, error) {
	dirs, name, err := split(rel)
	if err != nil {
		return nil, err
	}
	if op == "mkdir" {
		dirs = append(dirs, name)
	}
	root, err := os.OpenRoot(top)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	sub := "."
	for _, d := range dirs {
		sub = filepath.Join(sub, d)
		fi, err := root.Lstat(sub)
		if errors.Is(err, fs.ErrNotExist) {
			if op == "read" {
				return nil, ErrNoFile
			}
			if err := root.Mkdir(sub, 0o777); err != nil && !errors.Is(err, fs.ErrExist) {
				return nil, err
			}
			fi, err = root.Lstat(sub)
		}
		if err != nil {
			return nil, err
		}
		if !fi.IsDir() || fi.Mode()&fs.ModeSymlink != 0 || fi.Mode()&fs.ModeIrregular != 0 {
			return nil, ErrUnsafe
		}
	}
	if op == "mkdir" {
		return nil, nil
	}
	p := filepath.Join(sub, name)
	fi, err := root.Lstat(p)
	switch {
	case err == nil && !fi.Mode().IsRegular():
		return nil, ErrUnsafe
	case errors.Is(err, fs.ErrNotExist) && op == "read":
		return nil, ErrNoFile
	}
	switch op {
	case "touch":
		if err == nil {
			return nil, nil
		}
		f, err := root.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o666)
		if err != nil {
			return nil, err
		}
		return nil, f.Close()
	case "read":
		f, err := root.Open(p)
		if err != nil {
			return nil, ErrUnsafe
		}
		defer f.Close()
		return io.ReadAll(f)
	}
	var tmp string
	var f *os.File
	for range 20 {
		tmp = filepath.Join(sub, fmt.Sprintf(".%s.agent-vm.%d.%d", name, os.Getpid(), rand.IntN(1e9)))
		if f, err = root.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600); err == nil {
			break
		}
	}
	if f == nil {
		return nil, err
	}
	_, werr := f.Write(data)
	if err := errors.Join(werr, f.Close()); err != nil {
		root.Remove(tmp)
		return nil, err
	}
	if err := root.Rename(tmp, p); err != nil {
		root.Remove(tmp)
		return nil, err
	}
	return nil, nil
}
