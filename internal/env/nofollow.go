package env

import (
	"errors"
	"strings"
)

// The ways a NoFollow call fails.
var (
	// ErrNoFile: the file is not there (Read only).
	ErrNoFile = errors.New("no such file")
	// ErrUnsafe: a symlink, or something other than a folder or a regular
	// file, is on the way.
	ErrUnsafe = errors.New("a symlink, or not a regular file or folder, on the way")
)

// The NoFollow operations, each on top/rel, following no symlink below top:
// the one way the host touches the project, which the VM can write. Through
// a link planted there, a plain read would copy any file of the user's into
// the project, and a write could land anywhere; checking for links first is
// not enough, the VM can swap one in between the check and the use.
//
// Missing folders are made, except by Read. Write replaces the file with a
// new one, mode 600, renamed over it: a link there is replaced, not followed.

// ReadIn is the content of top/rel.
func ReadIn(top, rel string) ([]byte, error) { return noFollow("read", top, rel, nil) }

// WriteIn replaces top/rel with data.
func WriteIn(top, rel string, data []byte) error {
	_, err := noFollow("write", top, rel, data)
	return err
}

// MkdirIn makes the folder top/rel and those above it.
func MkdirIn(top, rel string) error {
	_, err := noFollow("mkdir", top, rel, nil)
	return err
}

// TouchIn makes top/rel an empty file unless it is a regular file already.
func TouchIn(top, rel string) error {
	_, err := noFollow("touch", top, rel, nil)
	return err
}

// split is rel's folders and its last name; ErrUnsafe for ".." anywhere, or
// no name.
func split(rel string) (dirs []string, name string, err error) {
	for _, c := range strings.Split(rel, "/") {
		if c != "" && c != "." {
			dirs = append(dirs, c)
		}
	}
	if len(dirs) == 0 {
		return nil, "", ErrUnsafe
	}
	for _, c := range dirs {
		if c == ".." {
			return nil, "", ErrUnsafe
		}
	}
	return dirs[:len(dirs)-1], dirs[len(dirs)-1], nil
}
