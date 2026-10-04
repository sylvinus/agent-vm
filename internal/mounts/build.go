package mounts

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/vm"
)

// FileMount is a single file of ~/.agent-vm/volumes: hardlinked into a
// staging folder of its own, which is shared, then bound in place in the VM
// (BindSrc onto BindDst), so the VM never sees the file's folder.
type FileMount struct {
	Src, Staging, BindSrc, BindDst string
}

// Line is how the state folder records it, as 0.2 did.
func (f FileMount) Line() string {
	return strings.Join([]string{f.Src, f.Staging, f.BindSrc, f.BindDst}, "|")
}

// CacheOn is sshfs's cache mode asked from the shell: on with
// AGENT_VM_SSHFS_CACHE=1, never from the project. With it, a file the host
// adds, deletes or extends shows as it was for up to 20 seconds, and an
// agent writing back what it read would undo the host's change; it is off
// on the writable shares otherwise.
func CacheOn() bool { return os.Getenv("AGENT_VM_SSHFS_CACHE") == "1" }

// Shares is what Build is given.
type Shares struct {
	VM       string
	Dir      string // the project
	Writable bool   // false for --readonly, every share
	// Names are read-only on every share (none with .git left writable).
	// Every share is served by the builtin SFTP server: the one confined to
	// its folder (vm.Confined).
	Names    []string
	Entries  []Entry // see Entries
	StateDir string  // where single files are staged
	Warn     io.Writer
}

// Build is the shares of the project's VM: the project first, then the
// entries, read-only unless rw (and never writable under --readonly: a
// writable volume holding the project would be a second way to write it).
func Build(s Shares) ([]vm.Mount, []FileMount) {
	w := func(format string, a ...any) { fmt.Fprintf(s.Warn, format+"\n", a...) }
	opts := func(writable bool) *vm.SSHFS {
		o := &vm.SSHFS{SFTPDriver: "builtin", ReadonlyNames: append([]string(nil), s.Names...)}
		if writable && !CacheOn() {
			off := false
			o.Cache = &off
		}
		return o
	}
	out := []vm.Mount{{Location: s.Dir, MountPoint: paths.Guest(s.Dir), Writable: s.Writable, SSHFS: opts(s.Writable)}}
	var files []FileMount
	idx := 0
	for _, e := range s.Entries {
		dst := e.Dst
		if dst != "" && !strings.HasPrefix(dst, "/") {
			p, ok := ProjectMountpoint(s.Dir, dst, e.Src, s.Warn)
			if !ok {
				continue
			}
			dst = paths.Guest(p)
		}
		if isFile(e.Src) {
			if e.Mode == "rw" {
				w("Warning: Mount entry '%s' (from ~/.agent-vm/volumes) requests rw on a file; only directories support rw. Mount the parent directory instead. Skipping.", e.Line)
				continue
			}
			dir := paths.Host(filepath.Join(s.StateDir, "file-mounts", s.VM, strconv.Itoa(idx)))
			staged := dir + "/" + filepath.Base(e.Src)
			if !Stage(e.Src, staged, s.Warn) {
				w("Warning: Failed to stage '%s', skipping.", e.Src)
				os.RemoveAll(dir)
				continue
			}
			mp := "/tmp/.agent-vm-file-mounts/" + strconv.Itoa(idx)
			bind := dst
			if bind == "" {
				bind = paths.Guest(e.Src)
			}
			files = append(files, FileMount{Src: e.Src, Staging: staged, BindSrc: mp + "/" + filepath.Base(e.Src), BindDst: bind})
			out = append(out, vm.Mount{Location: dir, MountPoint: mp, SSHFS: opts(false)})
			idx++
			continue
		}
		if !isDir(e.Src) {
			w("Warning: Mount path '%s' (from ~/.agent-vm/volumes) is not a regular file or directory, skipping.", e.Src)
			continue
		}
		writable := false
		if e.Mode == "rw" {
			if s.Writable {
				writable = true
			} else {
				w("Note: --readonly: '%s' (rw in ~/.agent-vm/volumes) is mounted read-only too.", e.Src)
			}
		}
		mp := dst
		if mp == "" {
			mp = paths.Guest(e.Src)
		}
		out = append(out, vm.Mount{Location: e.Src, MountPoint: mp, Writable: writable, SSHFS: opts(writable)})
	}
	return out, files
}

// Stage puts src at dst by a hardlink, which keeps it in step with the host
// (same inode) without sharing its folder; by a copy when they are on two
// file systems, with a warning: then changes reach the VM on its next start.
func Stage(src, dst string, warn io.Writer) bool {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return false
	}
	os.Remove(dst)
	// The file itself: link(2) links a symlink as one (stow's dotfiles), which
	// would leave dst pointing out of the folder the VM is given. The checks
	// made on src were on that file too (UnsafeLocation).
	if p, err := filepath.EvalSymlinks(src); err == nil {
		src = p
	}
	if os.Link(src, dst) == nil {
		return true
	}
	in, err := os.Open(src)
	if err != nil {
		return false
	}
	defer in.Close()
	fi, err := in.Stat()
	if err != nil {
		return false
	}
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, fi.Mode().Perm())
	if err != nil {
		return false
	}
	_, cerr := io.Copy(out, in)
	if err := out.Close(); cerr != nil || err != nil {
		return false
	}
	os.Chtimes(dst, fi.ModTime(), fi.ModTime())
	fmt.Fprintf(warn, "Warning: Staged '%s' via copy (cross-filesystem hardlink failed); live host changes will not propagate until VM (re)start.\n", src)
	return true
}
