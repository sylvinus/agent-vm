//go:build linux || darwin || windows

package reversesshfs

import (
	"encoding/binary"
	"errors"
	"io"
	"os"
	"path"
	"strings"
	"sync"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

// rootedHandlers serves only the files under rootPath.
//
// Reads go through os.Root, which follows symlinks but never outside the root.
// Writes open the parent directory without following any symlink,
// and are denied when any path component matches readonlyNames.
// Following no symlink on writes is what prevents the client from
// swapping a directory for a symlink into a read-only one.
// The OS-specific part is in rootedSys.
type rootedHandlers struct {
	rootPath      string // slash-separated, cleaned
	root          *os.Root
	readonly      bool
	readonlyNames []string
	rootedSys

	mu           sync.Mutex
	noopRemovals map[string]time.Time // expiry, keyed by request path
}

// maxHandles bounds the files and directories a client keeps open.
const maxHandles = 4096

// noopRemovalTTL bounds how long an ExpectRemove token waits for the guest.
const noopRemovalTTL = 5 * time.Second

func newRootedServer(rwc io.ReadWriteCloser, localPath string, readonly bool, readonlyNames []string) (*sftp.RequestServer, *rootedHandlers, error) {
	root, err := os.OpenRoot(localPath)
	if err != nil {
		return nil, nil, err
	}
	sys, err := openRootedSys(localPath)
	if err != nil {
		root.Close()
		return nil, nil, err
	}
	h := &rootedHandlers{
		rootPath:      slashPath(localPath),
		root:          root,
		readonly:      readonly,
		readonlyNames: readonlyNames,
		rootedSys:     sys,
		noopRemovals:  make(map[string]time.Time),
	}
	handlers := sftp.Handlers{FileGet: h, FilePut: h, FileCmd: h, FileList: h}
	// Sequential, as OpenSSH's sftp-server: otherwise two writes to the same range, or a write
	// and the FSTAT or FSETSTAT sent after it, can run in either order.
	srv := sftp.NewRequestServer(rwc, handlers, sftp.WithStartDirectory(startDirectory(h.rootPath)), sftp.WithRSSequential(),
		// Each handle holds a file descriptor of this process, which may be the one running the VM.
		sftp.WithRSMaxHandles(maxHandles),
		// sshfs reads up to 64 KiB (max_read), and takes a shorter answer for the end of the file.
		sftp.WithRSMaxTxPacket(64*1024))
	return srv, h, nil
}

func (h *rootedHandlers) Close() error {
	return errors.Join(h.root.Close(), h.rootedSys.close())
}

// expectRemove makes the next Remove or Rmdir request for p, within noopRemovalTTL,
// succeed without touching the host. p is a host path under the root.
func (h *rootedHandlers) expectRemove(p string) {
	p = slashPath(p)
	now := time.Now()
	h.mu.Lock()
	defer h.mu.Unlock()
	for k, expiry := range h.noopRemovals {
		if now.After(expiry) {
			delete(h.noopRemovals, k)
		}
	}
	h.noopRemovals[p] = now.Add(noopRemovalTTL)
}

func (h *rootedHandlers) consumeNoopRemoval(p string) bool {
	p = path.Clean(p)
	h.mu.Lock()
	defer h.mu.Unlock()
	expiry, ok := h.noopRemovals[p]
	if !ok {
		return false
	}
	delete(h.noopRemovals, p)
	return time.Now().Before(expiry)
}

// rel maps a request path to a path relative to the root.
// The result has no "." or ".." component, except "." for the root itself.
func (h *rootedHandlers) rel(p string) (string, error) {
	if !path.IsAbs(p) {
		p = path.Join(h.rootPath, p)
	}
	p = path.Clean(p)
	if p == h.rootPath {
		return ".", nil
	}
	prefix := h.rootPath
	if prefix != "/" {
		prefix += "/"
	}
	if r, ok := strings.CutPrefix(p, prefix); ok {
		return r, nil
	}
	return "", errDenied
}

func (h *rootedHandlers) writableRel(p string) (string, error) {
	if h.readonly {
		return "", errDenied
	}
	r, err := h.rel(p)
	if err != nil {
		return "", err
	}
	if h.isReadonlyName(r) || !writableName(r) {
		return "", errDenied
	}
	if Guard != nil && !Guard(h.rootPath, r) {
		return "", errDenied
	}
	return r, nil
}

// Guard, when set by the program running the server, is asked before every
// write that the read-only names allow, with the served directory and the
// path relative to it: false refuses the write (EACCES). It may block, to ask
// the user; the client's requests wait meanwhile.
var Guard func(root, rel string) bool

func (h *rootedHandlers) isReadonlyName(rel string) bool {
	for _, c := range strings.Split(rel, "/") {
		for _, name := range h.readonlyNames {
			if sameName(c, name) {
				return true
			}
		}
	}
	return false
}

// sameName reports whether a file name may refer to the same entry as name
// on a case-insensitive (APFS, HFS+, NTFS) file system.
func sameName(s, name string) bool {
	return foldName(s) == foldName(name)
}

// foldName is s as such a file system compares it, or wider: without the
// code points HFS+ ignores (those of next_hfs_char() in git's utf8.c), in
// canonical decomposition (APFS and HFS+ ignore normalization), and fully
// case-folded (APFS folds "ß" as "ss").
func foldName(s string) string {
	s = strings.Map(func(r rune) rune {
		switch {
		case r >= 0x200c && r <= 0x200f, r >= 0x202a && r <= 0x202e, r >= 0x206a && r <= 0x206f, r == 0xfeff:
			return -1
		}
		return r
	}, s)
	return norm.NFD.String(cases.Fold().String(norm.NFD.String(s)))
}

// Fileread implements sftp.FileReader.
func (h *rootedHandlers) Fileread(r *sftp.Request) (io.ReaderAt, error) {
	rel, err := h.rel(r.Filepath)
	if err != nil {
		return nil, err
	}
	f, err := h.openRead(rel)
	if err != nil {
		return nil, err
	}
	return f, nil
}

// openRead opens rel for reading, if it is a regular file or a directory.
// Opening a FIFO, or a device, could block the server, which handles one request at a time.
func (h *rootedHandlers) openRead(rel string) (*os.File, error) {
	f, err := h.root.OpenFile(rel, os.O_RDONLY|openNonblock, 0)
	if err != nil {
		return nil, err
	}
	fi, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, err
	}
	if !fi.Mode().IsRegular() && !fi.IsDir() {
		f.Close()
		return nil, &os.PathError{Op: "open", Path: rel, Err: errDenied}
	}
	return f, nil
}

// writableFile is a file opened by openFile: checked against readonlyNames, without following symlinks.
// FSETSTAT applies to it directly. Files opened for reading only may have been opened through a symlink
// to a read-only name, so FSETSTAT on them goes through the path checks of setstat.
type writableFile struct {
	*os.File
	appends bool // opened with SSH_FXF_APPEND
}

// WriteAt ignores off for a file opened with SSH_FXF_APPEND, and writes at the end of the file
// as it is on the host, as OpenSSH's sftp-server does: the client computed off from the size it
// knew, and the host may have grown the file since. Requests are processed in order, so writes keep theirs.
func (f writableFile) WriteAt(b []byte, off int64) (int, error) {
	if f.appends {
		return appendWrite(f.File, b)
	}
	return f.File.WriteAt(b, off)
}

func (h *rootedHandlers) openWritable(r *sftp.Request) (writableFile, error) {
	f, err := h.openFile(r)
	if err != nil {
		return writableFile{}, err
	}
	return writableFile{File: f, appends: r.Pflags().Append}, nil
}

// Filewrite implements sftp.FileWriter.
func (h *rootedHandlers) Filewrite(r *sftp.Request) (io.WriterAt, error) {
	f, err := h.openWritable(r)
	if err != nil {
		return nil, err
	}
	return f, nil
}

// OpenFile implements sftp.OpenFileWriter.
func (h *rootedHandlers) OpenFile(r *sftp.Request) (sftp.WriterAtReaderAt, error) {
	f, err := h.openWritable(r)
	if err != nil {
		return nil, err
	}
	return f, nil
}

// openMode returns the permissions sent with an Open request.
// For Open, pkg/sftp puts the open flags in r.Flags and drops the attribute flags,
// so r.AttrFlags and r.Attributes must not be used: SSH_FXF_APPEND reads as permissions.
// Permissions alone are the only 4-byte attributes, which is what sshfs always sends.
func openMode(r *sftp.Request) (uint32, bool) {
	if len(r.Attrs) != 4 {
		return 0, false
	}
	return binary.BigEndian.Uint32(r.Attrs) & 0o7777, true
}

// Filecmd implements sftp.FileCmder.
func (h *rootedHandlers) Filecmd(r *sftp.Request) error {
	switch r.Method {
	case "Setstat":
		// FSETSTAT: r.Filepath is where the file was opened, which may now be another file.
		if f, ok := r.HandleFile().(writableFile); ok {
			return h.fsetstat(f.File, r)
		}
		// A read handle keeps the path checks, but only for the file it is open on.
		if f, ok := r.HandleFile().(*os.File); ok && !h.isOpenAt(f, r.Filepath) {
			return &os.PathError{Op: "setstat", Path: r.Filepath, Err: os.ErrNotExist}
		}
		if h.isNoopTimes(r) {
			return nil
		}
		return h.setstat(r)
	case "Rename":
		return h.rename(r, true)
	case "Link":
		return h.link(r)
	case "Remove", "Rmdir":
		// The guest agent removes a path deleted on the host, so that the guest emits IN_DELETE.
		// The path may have been created again on the host since, so it must not be removed.
		if h.consumeNoopRemoval(r.Filepath) {
			return nil
		}
		return h.remove(r)
	case "Mkdir":
		return h.mkdir(r)
	case "Symlink":
		return h.symlink(r)
	}
	return sftp.ErrSSHFxOpUnsupported
}

// PosixRename implements sftp.PosixRenameFileCmder.
func (h *rootedHandlers) PosixRename(r *sftp.Request) error {
	return h.rename(r, false)
}

// isOpenAt reports whether f is the file at p, a request path, without following a symlink at p.
func (h *rootedHandlers) isOpenAt(f *os.File, p string) bool {
	rel, err := h.rel(p)
	if err != nil {
		return false
	}
	fi, err := f.Stat()
	if err != nil {
		return false
	}
	at, err := h.root.Lstat(rel)
	return err == nil && os.SameFile(fi, at)
}

// isNoopTimes reports whether r only sets the access and modification times of a
// read-only name to its current modification time. Such a request is answered
// without touching the file, so that the guest kernel still emits IN_ATTRIB:
// this is how the guest agent relays host inotify events (mountInotify).
func (h *rootedHandlers) isNoopTimes(r *sftp.Request) bool {
	flags := r.AttrFlags()
	if h.readonly || flags.Size || flags.UidGid || flags.Permissions || !flags.Acmodtime {
		return false
	}
	rel, err := h.rel(r.Filepath)
	if err != nil || !h.isReadonlyName(rel) {
		return false
	}
	fi, err := h.root.Lstat(rel)
	if err != nil {
		return false
	}
	// SFTP v3 times are in seconds.
	mtime := uint32(fi.ModTime().Unix())
	attrs := r.Attributes()
	return attrs != nil && attrs.Atime == mtime && attrs.Mtime == mtime
}

// Filelist implements sftp.FileLister.
func (h *rootedHandlers) Filelist(r *sftp.Request) (sftp.ListerAt, error) {
	rel, err := h.rel(r.Filepath)
	if err != nil {
		return nil, err
	}
	switch r.Method {
	case "List":
		f, err := h.openRead(rel)
		if err != nil {
			return nil, err
		}
		return &dirLister{f: f}, nil
	case "Stat":
		// FSTAT: r.Filepath is where the file was opened, which may now be another file.
		var f *os.File
		switch hf := r.HandleFile().(type) {
		case writableFile:
			f = hf.File
		case *os.File:
			f = hf
		}
		if f != nil {
			fi, err := f.Stat()
			if err != nil {
				return nil, err
			}
			return listerAt{fi}, nil
		}
		fi, err := h.root.Stat(rel)
		if err != nil {
			return nil, err
		}
		return listerAt{fi}, nil
	}
	return nil, sftp.ErrSSHFxOpUnsupported
}

// Lstat implements sftp.LstatFileLister.
func (h *rootedHandlers) Lstat(r *sftp.Request) (sftp.ListerAt, error) {
	rel, err := h.rel(r.Filepath)
	if err != nil {
		return nil, err
	}
	fi, err := h.root.Lstat(rel)
	if err != nil {
		return nil, err
	}
	return listerAt{fi}, nil
}

// Readlink implements sftp.ReadlinkFileLister.
func (h *rootedHandlers) Readlink(p string) (string, error) {
	rel, err := h.rel(p)
	if err != nil {
		return "", err
	}
	return h.root.Readlink(rel)
}

// RealPath implements sftp.RealPathFileLister.
// It does not resolve symlinks, and does not access the file system.
func (h *rootedHandlers) RealPath(p string) (string, error) {
	return realPath(h.rootPath, p), nil
}

// dirLister reads a directory as the client lists it, instead of all of it when it is opened:
// a huge directory takes neither the memory nor the time of a full read up front.
// pkg/sftp lists sequentially from offset 0, and closes it with the handle.
type dirLister struct {
	mu   sync.Mutex
	f    *os.File
	buf  []os.FileInfo // read, not listed yet
	next int64         // offset of buf[0]
	eof  bool
}

func (d *dirLister) ListAt(ls []os.FileInfo, offset int64) (int, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if offset != d.next {
		return 0, &os.PathError{Op: "readdir", Path: d.f.Name(), Err: errors.ErrUnsupported}
	}
	for len(d.buf) < len(ls) && !d.eof {
		fis, err := d.f.Readdir(len(ls) - len(d.buf))
		d.buf = append(d.buf, fis...)
		if errors.Is(err, io.EOF) {
			d.eof = true
		} else if err != nil {
			return 0, err
		}
	}
	n := copy(ls, d.buf)
	d.buf = d.buf[n:]
	d.next += int64(n)
	if n < len(ls) && d.eof {
		return n, io.EOF
	}
	return n, nil
}

func (d *dirLister) Close() error {
	return d.f.Close()
}

type listerAt []os.FileInfo

func (l listerAt) ListAt(ls []os.FileInfo, offset int64) (int, error) {
	if offset >= int64(len(l)) {
		return 0, io.EOF
	}
	n := copy(ls, l[offset:])
	if n < len(ls) {
		return n, io.EOF
	}
	return n, nil
}
