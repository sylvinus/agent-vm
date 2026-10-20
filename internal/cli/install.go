package cli

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"syscall"

	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/version"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

// `install` puts agent-vm on the PATH: a link to this executable in
// AGENT_VM_BIN_DIR (default ~/.local/bin), or a copy where links cannot be
// made (Windows without the symlink privilege). Safe to re-run.

// binName is the file install makes.
func binName() string {
	if runtime.GOOS == "windows" {
		return "agent-vm.exe"
	}
	return "agent-vm"
}

// binLink is where install puts agent-vm: in AGENT_VM_BIN_DIR, made
// absolute, or ~/.local/bin. An error without a home folder to put it in.
func binLink() (string, error) {
	dir := os.Getenv("AGENT_VM_BIN_DIR")
	if dir != "" {
		abs, err := filepath.Abs(dir)
		if err != nil {
			return "", err
		}
		return filepath.Join(abs, binName()), nil
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return "", errors.New("cannot find your home folder: set AGENT_VM_BIN_DIR to the folder to install in")
	}
	return filepath.Join(home, ".local", "bin", binName()), nil
}

// self is this executable, links resolved.
func self() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(exe)
}

// ours reports whether link is what install puts there for exe: a link to
// it, or a copy of it.
func ours(link, exe string) bool {
	if t, err := os.Readlink(link); err == nil {
		return t == exe
	}
	return sameContent(link, exe)
}

// sameContent reports whether the files a and b hold the same bytes, read
// in blocks: they are executables of tens of megabytes.
func sameContent(a, b string) bool {
	fa, err := os.Open(a)
	if err != nil {
		return false
	}
	defer fa.Close()
	fb, err := os.Open(b)
	if err != nil {
		return false
	}
	defer fb.Close()
	sa, erra := fa.Stat()
	sb, errb := fb.Stat()
	if erra != nil || errb != nil || !sa.Mode().IsRegular() || !sb.Mode().IsRegular() || sa.Size() != sb.Size() {
		return false
	}
	eof := func(err error) bool { return err == io.EOF || err == io.ErrUnexpectedEOF }
	ba, bb := make([]byte, 1<<16), make([]byte, 1<<16)
	for {
		na, erra := io.ReadFull(fa, ba)
		nb, errb := io.ReadFull(fb, bb)
		if na != nb || !bytes.Equal(ba[:na], bb[:nb]) {
			return false
		}
		if erra != nil || errb != nil {
			return eof(erra) && eof(errb)
		}
	}
}

// installedCopy records the hash of the copy install made, so the next one
// recognises it once agent-vm itself was updated.
const installedCopy = "installed-copy.sha256"

func sha256Of(p string) string {
	f, err := os.Open(p)
	if err != nil {
		return ""
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return ""
	}
	return fmt.Sprintf("%x", h.Sum(nil))
}

// earlier reports whether link is what an earlier install made: 0.2's link
// to its agent-vm.sh, a link to an agent-vm that is gone (a clone or a
// version since removed), or a copy install recorded.
func (e *app) earlier(link string) bool {
	if t, err := os.Readlink(link); err == nil {
		if filepath.Base(t) == "agent-vm.sh" {
			return true
		}
		_, err := os.Stat(link)
		return errors.Is(err, fs.ErrNotExist) && (filepath.Base(t) == "agent-vm" || filepath.Base(t) == "agent-vm.exe")
	}
	h := sha256Of(link)
	return h != "" && h == strings.TrimSpace(e.state.Read(installedCopy))
}

var rcSourcesRe = regexp.MustCompile(`(?m)^[^#\n]*agent-vm\.sh`)

// onPath reports whether dir is on PATH, compared as the file system does
// (C:\x and c:/x/ are one folder on Windows).
func onPath(dir string) bool {
	norm := func(p string) string { return strings.TrimSuffix(paths.Host(p), "/") }
	for _, p := range filepath.SplitList(os.Getenv("PATH")) {
		if paths.Equal(norm(p), norm(dir)) {
			return true
		}
	}
	return false
}

// rcSourcesUs: an uncommented line of a usual rc file names agent-vm.sh, as
// an install from before 0.2.0 added.
func rcSourcesUs() bool {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return false
	}
	for _, f := range []string{".zshrc", ".bashrc", ".bash_profile", ".profile", ".zshenv"} {
		if b, err := os.ReadFile(filepath.Join(home, f)); err == nil && rcSourcesRe.Match(b) {
			return true
		}
	}
	return false
}

func (e *app) installCmd(ctx context.Context, args []string) int {
	if len(args) > 0 {
		fmt.Fprintln(e.io.Stderr, "Usage: agent-vm install")
		return 2
	}
	w := e.io.Stdout
	exe, err := self()
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: cannot find this executable: %v\n", err)
		return 1
	}
	link, err := binLink()
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	dir := filepath.Dir(link)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	_, lerr := os.Lstat(link)
	isOurs := lerr == nil && ours(link, exe)
	if lerr == nil && !isOurs && e.earlier(link) {
		if err := os.Remove(link); err != nil {
			fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
			return 1
		}
		fmt.Fprintf(w, "Replacing %s, from an earlier install\n", link)
		lerr = os.ErrNotExist
	}
	var serr error
	if lerr != nil {
		serr = symlink(exe, link)
	}
	switch {
	case isOurs:
		fmt.Fprintf(w, "agent-vm is already linked at %s\n", link)
	case lerr == nil:
		fmt.Fprintf(e.io.Stderr, "Error: %s already exists and is not a link to %s.\n  Move it aside, or set AGENT_VM_BIN_DIR to another directory.\n", link, exe)
		return 1
	case serr == nil:
		fmt.Fprintf(w, "Linked %s -> %s\n", link, exe)
	case !symlinkUnsupported(serr):
		fmt.Fprintf(e.io.Stderr, "Error: could not link %s to %s: %v\n", link, exe, serr)
		return 1
	default:
		if err := copyFile(exe, link); err != nil {
			fmt.Fprintf(e.io.Stderr, "Error: could not copy %s to %s: %v\n", exe, link, err)
			return 1
		}
		if err := e.state.Write(installedCopy, []byte(sha256Of(link)+"\n")); err != nil {
			fmt.Fprintf(e.io.Stderr, "Warning: %v: the next install will not recognise this copy.\n", err)
		}
		fmt.Fprintf(w, "Installed %s, a copy of %s (links are not allowed here: %v)\n", link, exe, serr)
	}
	if !onPath(dir) {
		if paths.Windows() {
			fmt.Fprintf(w, "%s is not on your PATH. Add it from PowerShell, then open a new terminal:\n  [Environment]::SetEnvironmentVariable('Path', '%s;' + [Environment]::GetEnvironmentVariable('Path', 'User'), 'User')\n",
				dir, strings.ReplaceAll(dir, "'", "''"))
		} else {
			fmt.Fprintf(w, "%s is not on your PATH. Add this line to your shell rc:\n  export PATH=\"%s:$PATH\"\n", dir, dir)
		}
	}
	if rcSourcesUs() {
		fmt.Fprintln(w, "Your shell rc still sources agent-vm.sh, which this agent-vm replaces: remove that line.")
	}
	fmt.Fprintf(w, "\nagent-vm %s installed.\n", version.Version)
	// Looking only: installing must not move 0.2's VMs, which stops running ones.
	if b, err := e.readOnlyBackend(); err == nil {
		if base, err := b.Get(ctx, vmname.Template); err == nil && base != nil {
			if e.state.BaseReady(vmname.Template) {
				fmt.Fprintln(w, "Next:  cd your-project && agent-vm claude   # or opencode, codex, vibe, pi")
				return 0
			}
		}
	}
	if e.ui.CanAsk() && e.ui.AskYN("Build the base VM now with 'agent-vm setup'? It takes a few minutes.", true) {
		fmt.Fprintln(w)
		return e.setupCmd(ctx, nil)
	}
	fmt.Fprintln(w, "Next:\n  agent-vm setup     # build the base VM, once")
	return 0
}

// symlink makes a link; a variable for the tests, on machines that allow
// them.
var symlink = os.Symlink

// symlinkUnsupported reports whether err says that links cannot be made
// here (Windows without the privilege, a file system without them), where a
// copy does the work, as opposed to a failure a copy would meet too (a
// read-only folder, a full disk).
func symlinkUnsupported(err error) bool {
	const errPrivilegeNotHeld = syscall.Errno(1314) // Windows
	return errors.Is(err, errors.ErrUnsupported) || errors.Is(err, syscall.EPERM) || errors.Is(err, errPrivilegeNotHeld)
}

// copyFile copies src to dst through a temporary file in dst's folder,
// renamed once complete: a copy that fails half way leaves nothing behind,
// and dst is never a truncated executable.
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.CreateTemp(filepath.Dir(dst), ".agent-vm-install-*")
	if err != nil {
		return err
	}
	_, err = io.Copy(out, in)
	if err == nil {
		err = out.Chmod(0o755)
	}
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(out.Name(), dst)
	}
	if err != nil {
		os.Remove(out.Name())
	}
	return err
}

// `uninstall` removes what install made, and nothing else: the VMs,
// ~/.agent-vm and the executable itself stay.
func (e *app) uninstallCmd(args []string) int {
	if len(args) > 0 {
		fmt.Fprintln(e.io.Stderr, "Usage: agent-vm uninstall")
		return 2
	}
	w := e.io.Stdout
	link, err := binLink()
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	exe, _ := self()
	_, lerr := os.Lstat(link)
	switch {
	case lerr == nil && (exe != "" && ours(link, exe) || e.earlier(link)):
		if err := os.Remove(link); err != nil {
			fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
			return 1
		}
		fmt.Fprintf(w, "Removed %s\n", link)
	case lerr == nil:
		fmt.Fprintf(w, "%s is not a link to this agent-vm: left alone.\n", link)
	default:
		fmt.Fprintf(w, "No link to remove at %s\n", link)
	}
	if rcSourcesUs() {
		fmt.Fprintln(w, "Your shell rc still sources agent-vm.sh: remove that line to drop the shell function.")
	}
	fmt.Fprintf(w, "Left as they are: the VMs ('agent-vm destroy-all' deletes them, run it first), ~/.agent-vm, and agent-vm itself at %s.\n", exe)
	return 0
}
