// Package vmname names the VM of a project directory, as 0.2 did but for
// its prefix: the VMs it made are moved under those names (FromOld).
package vmname

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/sylvinus/agent-vm/internal/paths"
)

// OldPrefix began every name 0.2 gave its VMs, in a Lima home it shared
// with the user's: agent-vm's own has no use for it (see FromOld).
const OldPrefix = "agent-vm-"

// Template is the base VM every project's VM is cloned from. No project VM
// has its name: theirs end with a hash.
const Template = "base"

// The names Scratch makes.
var scratchRe = regexp.MustCompile(`^[A-Za-z0-9-]+-scratch-[0-9a-f]{8}$`)

// MaxLen is the longest name a VM may have: Lima's 76 characters, or less
// where its sockets would not fit under the Lima home (set from it, see
// vm.MaxName). Names longer are cut in their folder part (fit).
var MaxLen = 76

// Name is the VM of the project dir, spelled as `pwd` spells it: the name
// hashes that string, so /tmp/ and /tmp give one VM and a symlink to the
// project another. <base>-<hash>, base the folder's name with every run of
// other characters than ASCII letters and digits made one "-" ("project"
// when nothing is left), and hash 8 hex digits of the path's SHA-256. On
// Windows, the path as Git Bash spelled it (/c/...), as 0.2 hashed it.
func Name(dir string) string {
	dir = paths.Guest(dir)
	sum := sha256.Sum256([]byte(dir))
	b := base(dir, 0)
	if b == "" {
		b = "project"
	}
	return fit(b, "-"+hex.EncodeToString(sum[:])[:8])
}

// fit is b+suffix, b cut to keep it within MaxLen, never to nothing.
func fit(b, suffix string) string {
	if n := MaxLen - len(suffix); len(b) > n {
		b = strings.TrimRight(b[:max(n, 1)], "-")
		if b == "" {
			b = "p"
		}
	}
	return b + suffix
}

// FromOld is the name of the VM 0.2 named old: without OldPrefix, its base
// template Template, cut as Name cuts a name too long here.
func FromOld(old string) string {
	if old == OldPrefix+"base" {
		return Template
	}
	n := strings.TrimPrefix(old, OldPrefix)
	if i := strings.LastIndexByte(n, '-'); i > 0 {
		return fit(n[:i], n[i:])
	}
	return n
}

// Scratch is a new name for a --scratch VM started in dir: its own, so it is
// never the folder's VM and several can run at once. Short enough for Lima:
// 76 characters, and a socket path under the Lima home of at most 104 on
// macOS.
func Scratch(dir string) (string, error) {
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("cannot read random bytes to name the VM: %w", err)
	}
	name := base(dir, 20)
	if name == "" {
		name = "project"
	}
	return fit(name, "-scratch-"+hex.EncodeToString(b[:])), nil
}

// IsScratch reports whether name is one Scratch makes: those are deleted
// unasked when left over.
func IsScratch(name string) bool {
	return scratchRe.MatchString(name)
}

// base is the last element of dir, every run of bytes other than ASCII
// letters and digits made one "-", cut to max bytes when max > 0, without a
// "-" at either end. As `basename | tr -cs 'a-zA-Z0-9' '-'` did, the newline
// basename prints counts as one of those bytes.
func base(dir string, max int) string {
	b := basename(dir) + "\n"
	var out []byte
	for i := 0; i < len(b); i++ {
		c := b[i]
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' {
			out = append(out, c)
		} else if len(out) == 0 || out[len(out)-1] != '-' {
			out = append(out, '-')
		}
	}
	if max > 0 && len(out) > max {
		out = out[:max]
	}
	s := string(out)
	if max > 0 {
		// Cut, it may end with several: the scratch name trims every one.
		return strings.Trim(s, "-")
	}
	s = strings.TrimPrefix(s, "-")
	return strings.TrimSuffix(s, "-")
}

// basename is what basename(1) prints for p: its last element, trailing
// slashes ignored, "/" for the root.
func basename(p string) string {
	if p == "" {
		return ""
	}
	t := strings.TrimRight(p, "/")
	if t == "" {
		return "/"
	}
	return t[strings.LastIndexByte(t, '/')+1:]
}

// ErrNoDir is returned by AbsDir for a directory that does not exist.
var ErrNoDir = errors.New("no such directory")

// AbsDir is dir (the current directory when empty) as the commands that
// start a VM spell theirs: absolute, logical (symlinks kept, as `pwd` does;
// os.Getwd returns $PWD when it names the current directory), without "."
// or "..". It refuses a directory that does not exist, and a path holding a
// control character, which would forge lines of `info`'s key=value output.
func AbsDir(dir string) (string, error) {
	if dir == "" || !filepath.IsAbs(dir) {
		wd, err := os.Getwd()
		if err != nil {
			return "", err
		}
		dir = filepath.Join(wd, dir)
	}
	dir = filepath.Clean(dir)
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return "", fmt.Errorf("%w: %s", ErrNoDir, dir)
	}
	for _, r := range dir {
		if r < 0x20 || r == 0x7f {
			return "", errors.New("the directory name contains a control character")
		}
	}
	return paths.Host(dir), nil
}
