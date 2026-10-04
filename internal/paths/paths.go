// Package paths compares and joins host paths as agent-vm's checks need:
// textually, as `cd` does, and whatever the case where the file system
// ignores it.
//
// Host paths are spelled with / separators everywhere: on Windows, C:/Users/me
// (Host), which Go's file functions take as they take C:\Users\me.
package paths

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"unicode/utf8"
)

// Windows reports whether host paths are Windows ones, with a drive. A
// variable, for tests.
var Windows = func() bool { return runtime.GOOS == "windows" }

// Host is p, as the OS gave it, in agent-vm's spelling: / separators on
// Windows, as is elsewhere.
func Host(p string) string {
	if Windows() {
		return strings.ReplaceAll(p, `\`, "/")
	}
	return p
}

// Home is the user's home folder, spelled as Host does; "" when unknown.
func Home() string {
	h, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return Host(h)
}

// Real is p with its links resolved (filepath.EvalSymlinks), spelled as
// Host does.
func Real(p string) (string, error) {
	r, err := filepath.EvalSymlinks(p)
	return Host(r), err
}

// volume is the length of p's drive ("C:"), 0 when it has none or this is
// not Windows.
func volume(p string) int {
	if Windows() && len(p) >= 2 && p[1] == ':' && ('a' <= p[0]|0x20 && p[0]|0x20 <= 'z') {
		return 2
	}
	return 0
}

// IsAbs reports whether p is absolute: it starts with /, after its drive
// on Windows (C:/x).
func IsAbs(p string) bool {
	return strings.HasPrefix(p[volume(p):], "/")
}

// Root is p's root: "/", or its drive's ("C:/") on Windows.
func Root(p string) string {
	return p[:volume(p)] + "/"
}

// Join is dir/p, with "." and ".." resolved in the text, as `cd` does: a
// path that only goes through dir on its way out of it (../x) names a file
// outside. The root ("/", "C:/") when nothing is left: ".." stops there.
func Join(dir, p string) string {
	v := volume(dir)
	drive, out := dir[:v], strings.TrimSuffix(dir[v:], "/")
	for _, comp := range strings.Split(p, "/") {
		switch comp {
		case "", ".":
		case "..":
			if i := strings.LastIndexByte(out, '/'); i >= 0 {
				out = out[:i]
			} else {
				out = ""
			}
		default:
			out += "/" + comp
		}
	}
	if out == "" {
		return drive + "/"
	}
	return drive + out
}

// Abs is p made absolute against dir, as Join, an absolute p against its
// root.
func Abs(dir, p string) string {
	if IsAbs(p) {
		r := Root(p)
		return Join(r, p[len(r):])
	}
	return Join(dir, p)
}

// Guest is the host path p as 0.2 spelled it, which is the path the VM sees
// it at, and which VM names hash: as is, but for Windows, where Git Bash
// spelled C:\Users\x as /c/Users/x.
func Guest(p string) string {
	if volume(p) == 0 {
		return p
	}
	return "/" + strings.ToLower(p[:1]) + strings.ReplaceAll(p[2:], `\`, "/")
}

// FromGitBash is p, on Windows, with Git Bash's spelling of a drive (/c/x,
// as 0.2's volumes file has it) made a drive again (C:/x); as is
// elsewhere.
func FromGitBash(p string) string {
	if !Windows() || len(p) < 2 || p[0] != '/' || !('a' <= p[1]|0x20 && p[1]|0x20 <= 'z') || (len(p) > 2 && p[2] != '/') {
		return p
	}
	return strings.ToUpper(p[1:2]) + ":" + Join("/", p[2:])
}

// NoCase reports whether this host's file systems ignore case by default:
// macOS, Windows. A variable, for tests.
var NoCase = func() bool {
	return runtime.GOOS == "darwin" || Windows()
}

// Fold is s as the file system compares it: lowercased where case is
// ignored, as is elsewhere.
func Fold(s string) string {
	if NoCase() {
		return strings.ToLower(s)
	}
	return s
}

// Equal compares two paths as the file system does.
func Equal(a, b string) bool {
	if NoCase() {
		return strings.EqualFold(a, b)
	}
	return a == b
}

// CutPrefix is s without prefix, compared as the file system does, and
// whether s starts with it. The rest is s's own spelling: case folding can
// change the length of a string, so it is cut where the match ends in s.
func CutPrefix(s, prefix string) (string, bool) {
	if !NoCase() {
		return strings.CutPrefix(s, prefix)
	}
	i := 0
	for _, pr := range prefix {
		if i >= len(s) {
			return s, false
		}
		sr, n := utf8.DecodeRuneInString(s[i:])
		if !strings.EqualFold(string(sr), string(pr)) {
			return s, false
		}
		i += n
	}
	return s[i:], true
}

// In is p relative to dir, "." for dir itself, compared as the file system
// does; false when p is not inside dir.
func In(p, dir string) (string, bool) {
	p, dir = strings.TrimSuffix(p, "/"), strings.TrimSuffix(dir, "/")
	if Equal(p, dir) {
		return ".", true
	}
	if dir == "" {
		return "", false
	}
	rest, ok := CutPrefix(p, dir+"/")
	return rest, ok
}
