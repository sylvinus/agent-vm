// Package mounts is what a project's VM is given of this machine: the
// project, and the entries of ~/.agent-vm/volumes, each checked first.
package mounts

import (
	"fmt"
	"os"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/sylvinus/agent-vm/internal/paths"
)

// BaseNames are always read-only in every share. .hg: Mercurial runs the
// hooks of .hg/hgrc in a repository the user owns, which files written
// through a share are.
var BaseNames = []string{".git", ".hg"}

// UnderName reports whether the relative path rel goes through one of names
// (BaseNames when nil), matched as the SFTP server does: per component,
// whatever the case.
func UnderName(rel string, names []string) bool {
	if names == nil {
		names = BaseNames
	}
	for _, c := range strings.Split(rel, "/") {
		for _, n := range names {
			if c != "" && strings.EqualFold(c, n) {
				return true
			}
		}
	}
	return false
}

// Ref is a location no share may reach.
type Ref struct {
	What string // "your home directory", ...
	Path string // physical, folded
}

// Refs are the locations no share may reach: the home folder (dotfiles,
// SSH keys, every other project), agent-vm itself (the host runs its
// files), agent-vm's state (every VM's env) and Lima's homes, agent-vm's
// and the user's own (the VMs' SSH key and disks, its _config adding
// mounts to every VM).
func Refs(home, self, state string, limaHomes ...string) []Ref {
	refs := []Ref{{"your home directory", home}, {"agent-vm itself", self}, {"agent-vm's state", state}}
	for _, h := range limaHomes {
		refs = append(refs, Ref{"Lima's state", h})
	}
	var out []Ref
	for _, r := range refs {
		if r.Path == "" {
			continue
		}
		// Not resolved when it does not exist: as typed, never emptied, or
		// every path would be inside it.
		if p, err := paths.Real(r.Path); err == nil && p != "" {
			r.Path = p
		} else {
			r.Path = strings.TrimSuffix(r.Path, "/")
		}
		if r.Path == "" {
			continue
		}
		r.Path = paths.Fold(r.Path)
		out = append(out, r)
	}
	return out
}

// UnsafeLocation says why dir must not be shared with a VM, writable or
// not, when it is or contains the home folder, or is, contains or is inside
// one of the other refs. A project inside the home folder is what is
// expected. Compared as physical paths, whatever the case where the file
// system ignores it.
func UnsafeLocation(dir string, refs []Ref) (string, bool) {
	if p, err := paths.Real(dir); err == nil {
		dir = p
	}
	d := strings.TrimSuffix(paths.Fold(dir), "/") + "/"
	for _, r := range refs {
		p := strings.TrimSuffix(r.Path, "/") + "/"
		if strings.HasPrefix(p, d) {
			return "is, or contains, " + r.What, true
		}
		if r.What != "your home directory" && strings.HasPrefix(d, p) {
			return "is inside " + r.What, true
		}
	}
	return "", false
}

// GitDirShare says why dir must not be a writable share: it is, or is
// inside, a repository's own folder: a .git or .hg (by name, as the SFTP
// server matches them), or a bare repository (HEAD, objects/ and refs/, as
// git finds one). The read-only names apply below a share's root, so such a
// share would be writable whole, hooks and config included.
func GitDirShare(dir string) (string, bool) {
	if p, err := paths.Real(dir); err == nil {
		dir = p
	}
	// dir and each folder above it, the root ("/", "C:/") excepted.
	root := paths.Root(dir)
	for a := strings.TrimSuffix(dir, "/"); a+"/" != root; {
		if isFile(a+"/HEAD") && isDir(a+"/objects") && isDir(a+"/refs") {
			return fmt.Sprintf("is, or is inside, a git repository's own folder (%s)", a), true
		}
		i := strings.LastIndexByte(a, '/')
		if i < 0 {
			break
		}
		a = a[:i]
	}
	if UnderName(strings.TrimPrefix(dir, root), nil) {
		return "is, or is inside, a folder git or Mercurial keeps its repository in (.git, .hg)", true
	}
	return "", false
}

// UnsafeProject says why the project dir must not be shared: see
// UnsafeLocation and GitDirShare.
func UnsafeProject(dir string, refs []Ref) (string, bool) {
	if why, ok := UnsafeLocation(dir, refs); ok {
		return why, true
	}
	return GitDirShare(dir)
}

// Unmountable says why Lima cannot be given dir as a share: with whitespace
// the mount fails silently, leaving a bare, root-owned mount point; a quote,
// a backslash or a control character are refused as 0.2 refused them; and
// what Lima would read as another path (Unwritable).
func Unmountable(dir string) (string, bool) {
	if strings.IndexFunc(dir, unicode.IsSpace) >= 0 {
		return "contains whitespace, which Lima cannot mount", true
	}
	if strings.ContainsAny(dir, "\"\\") || strings.IndexFunc(dir, unicode.IsControl) >= 0 {
		return "contains a quote, a backslash or a control character", true
	}
	return Unwritable(dir)
}

// Unwritable says why s cannot go into Lima's config as written: Lima
// expands Go templates in share paths ({{.Home}} is the home folder), and a
// byte that is not UTF-8 becomes U+FFFD on the way.
func Unwritable(s string) (string, bool) {
	if strings.Contains(s, "{{") {
		return "contains {{, which Lima reads as a template", true
	}
	if !utf8.ValidString(s) {
		return "is not valid UTF-8", true
	}
	return "", false
}

func isFile(p string) bool { fi, err := os.Stat(p); return err == nil && fi.Mode().IsRegular() }
func isDir(p string) bool  { fi, err := os.Stat(p); return err == nil && fi.IsDir() }
