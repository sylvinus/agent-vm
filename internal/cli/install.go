package cli

import (
	"bytes"
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"

	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/version"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

// `install` puts agent-vm on the PATH: a link to this executable in
// AGENT_VM_BIN_DIR (default ~/.local/bin), or a copy where no link can be
// made (Windows without the symlink privilege). Safe to re-run.

func binLink() string {
	dir := os.Getenv("AGENT_VM_BIN_DIR")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".local", "bin")
	}
	name := "agent-vm"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	return filepath.Join(dir, name)
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
	a, err1 := os.ReadFile(link)
	b, err2 := os.ReadFile(exe)
	return err1 == nil && err2 == nil && bytes.Equal(a, b)
}

// installedCopy records the hash of the copy install made, so the next one
// recognises it once agent-vm itself was updated.
const installedCopy = "installed-copy.sha256"

func sha256Of(p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return fmt.Sprintf("%x", sha256.Sum256(b))
}

// earlier reports whether link is what an earlier install made: 0.2's link
// to its agent-vm.sh, or a copy install recorded.
func (e *app) earlier(link string) bool {
	if t, err := os.Readlink(link); err == nil {
		return filepath.Base(t) == "agent-vm.sh"
	}
	h := sha256Of(link)
	return h != "" && h == strings.TrimSpace(e.state.Read(e.state.Path(installedCopy)))
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
	home, _ := os.UserHomeDir()
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
	link := binLink()
	dir := filepath.Dir(link)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	_, lerr := os.Lstat(link)
	if lerr == nil && !ours(link, exe) && e.earlier(link) {
		if err := os.Remove(link); err != nil {
			fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
			return 1
		}
		fmt.Fprintf(w, "Replacing %s, from an earlier install\n", link)
		lerr = os.ErrNotExist
	}
	switch {
	case ours(link, exe):
		fmt.Fprintf(w, "agent-vm is already linked at %s\n", link)
	case lerr == nil:
		fmt.Fprintf(e.io.Stderr, "Error: %s already exists and is not a link to %s.\n  Move it aside, or set AGENT_VM_BIN_DIR to another directory.\n", link, exe)
		return 1
	case os.Symlink(exe, link) == nil:
		fmt.Fprintf(w, "Linked %s -> %s\n", link, exe)
	default:
		if err := copyFile(exe, link); err != nil {
			fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
			return 1
		}
		os.MkdirAll(string(e.state), 0o755)
		if err := os.WriteFile(e.state.Path(installedCopy), []byte(sha256Of(link)+"\n"), 0o644); err != nil {
			fmt.Fprintf(e.io.Stderr, "Warning: %v: the next install will not recognise this copy.\n", err)
		}
		fmt.Fprintf(w, "Installed %s, a copy of %s (no symlinks on this system)\n", link, exe)
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
	if b, err := e.backend(); err == nil {
		if base, err := b.Get(ctx, vmname.Template); err == nil && base != nil {
			if _, err := os.Stat(e.state.Path(state.BaseVersion)); err == nil {
				fmt.Fprintln(w, "Next:  cd your-project && agent-vm claude   # or opencode, codex, vibe")
				return 0
			}
		}
	}
	if e.ui.HaveTTY() && e.ui.AskYN("Build the base VM now with 'agent-vm setup'? It takes a few minutes.", true) {
		fmt.Fprintln(w)
		return e.setupCmd(ctx, nil)
	}
	fmt.Fprintln(w, "Next:\n  agent-vm setup     # build the base VM, once")
	return 0
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, in)
	if cerr := out.Close(); err == nil {
		err = cerr
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
	link := binLink()
	exe, _ := self()
	_, lerr := os.Lstat(link)
	switch {
	case exe != "" && ours(link, exe) || lerr == nil && e.earlier(link):
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
