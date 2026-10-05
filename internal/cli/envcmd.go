package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"golang.org/x/term"

	"github.com/sylvinus/agent-vm/internal/env"
	"github.com/sylvinus/agent-vm/internal/gitx"
	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

var keyRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// envFile is an env file: top is the project folder when the file is inside
// it, and is then only touched without following links (env.ReadIn).
type envFile struct {
	path, top string
}

func (f envFile) read() ([]byte, error) {
	if f.top != "" {
		return env.ReadIn(f.top, strings.TrimPrefix(f.path, strings.TrimSuffix(f.top, "/")+"/"))
	}
	fi, err := os.Stat(f.path)
	if errors.Is(err, os.ErrNotExist) || err == nil && !fi.Mode().IsRegular() {
		return nil, env.ErrNoFile
	}
	return os.ReadFile(f.path)
}

// write replaces the file, atomically, mode 600.
func (f envFile) write(data []byte) error {
	if f.top != "" {
		return env.WriteIn(f.top, strings.TrimPrefix(f.path, strings.TrimSuffix(f.top, "/")+"/"), data)
	}
	if err := os.MkdirAll(filepath.Dir(f.path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(f.path), filepath.Base(f.path)+".")
	if err != nil {
		return err
	}
	_, werr := tmp.Write(data)
	if err := errors.Join(werr, tmp.Chmod(0o600), tmp.Close()); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	if err := os.Rename(tmp.Name(), f.path); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return nil
}

// envVerb runs `env` (~/.agent-vm/env) and `project-env`: set, get, has,
// unset, list, on a file the VM's shell sources, so the quoting is done
// here, once. Writes are atomic and mode 600, other lines kept; list prints
// names, never values. The file is held in memory, never in a temporary
// file: it holds secrets.
func (e *app) envVerb(verb string, f envFile, args []string) int {
	stderr := e.io.Stderr
	usage := fmt.Sprintf("Usage: agent-vm %s {set KEY [VALUE]|get KEY|has KEY|unset KEY|list}", verb)
	action, key := "list", ""
	if len(args) > 0 {
		action = args[0]
	}
	if len(args) > 1 {
		key = args[1]
	}
	switch action {
	case "set", "get", "has", "unset":
		if key == "" {
			fmt.Fprintf(stderr, "Error: 'agent-vm %s %s' needs a KEY.\n", verb, action)
			return 1
		}
		if !keyRe.MatchString(key) {
			fmt.Fprintf(stderr, "Error: '%s' is not a valid environment variable name.\n", key)
			return 1
		}
	case "list":
	default:
		fmt.Fprintln(stderr, usage)
		return 1
	}
	// A word too many is refused: `set TOKEN my secret` would store "my".
	maxArgs := map[string]int{"set": 3, "list": 1}[action]
	if maxArgs == 0 {
		maxArgs = 2
	}
	if len(args) > maxArgs {
		fmt.Fprintf(stderr, "Error: too many arguments for 'agent-vm %s %s'. Quote a value with spaces.\n", verb, action)
		fmt.Fprintln(stderr, usage)
		return 1
	}
	// Without VALUE, read from stdin, typed unseen on a terminal: a value on
	// the command line lands in the shell history and in `ps`. From a pipe,
	// one trailing newline goes, as `echo` adds it.
	value := ""
	if action == "set" {
		if len(args) == 3 {
			value = args[2]
		} else if in, ok := e.io.Stdin.(*os.File); ok && term.IsTerminal(int(in.Fd())) {
			fmt.Fprintf(stderr, "Value for %s (not shown): ", key)
			b, err := term.ReadPassword(int(in.Fd()))
			fmt.Fprintln(stderr)
			if err == nil {
				value = string(b)
			}
		} else {
			b, _ := io.ReadAll(e.io.Stdin)
			value = strings.TrimSuffix(string(b), "\n")
		}
		if len(args) < 3 && value == "" {
			fmt.Fprintf(stderr, "Error: 'agent-vm %s set %s' needs a VALUE, as an argument or on stdin.\n", verb, key)
			return 1
		}
	}

	content, err := f.read()
	have := true
	switch {
	case err == nil:
	case errors.Is(err, env.ErrNoFile):
		have = false
	case errors.Is(err, env.ErrUnsafe):
		fmt.Fprintf(stderr, "Error: %s is a symlink, is reached through one, or is not a regular file.\n", f.path)
		fmt.Fprintln(stderr, "  agent-vm follows no link in the project, which the VM can write. Replace it with a plain file.")
		return 2
	default:
		fmt.Fprintf(stderr, "Error: could not read %s\n", f.path)
		return 2
	}

	switch action {
	case "set", "unset":
		if action == "unset" && !have {
			return 0
		}
		next := env.Drop(string(content), key)
		if action == "set" {
			next += fmt.Sprintf("%s='%s'\n", key, env.SQEscape(value))
		}
		// A write dropped silently would tell the caller a secret was stored
		// when it was not.
		if err := f.write([]byte(next)); err != nil {
			fmt.Fprintf(stderr, "Error: could not write %s\n", f.path)
			return 1
		}
	case "get", "has":
		if !have {
			return 1
		}
		// Read, never sourced: the project's file is one the VM can write.
		v, st := env.Lookup(string(content), key)
		switch st {
		case env.NotFound:
			return 1
		case env.Refused:
			fmt.Fprintf(stderr, "Error: %s in %s uses, or comes after, shell syntax agent-vm does not evaluate\n", key, f.path)
			fmt.Fprintf(stderr, "  ($, backquotes, backslashes, ~, ;, | ...). Rewrite it with 'agent-vm %s set'.\n", verb)
			return 2
		}
		if action == "get" {
			fmt.Fprintln(e.io.Stdout, v)
		}
	case "list":
		if !have {
			return 0
		}
		seen := map[string]bool{}
		for _, n := range env.Names(string(content)) {
			if !seen[n] {
				seen[n] = true
				fmt.Fprintln(e.io.Stdout, n)
			}
		}
	}
	return 0
}

func (e *app) sharedEnvCmd(args []string) int {
	return e.envVerb("env", envFile{path: e.state.Path("env")}, args)
}

func (e *app) projectEnvCmd(ctx context.Context, args []string) int {
	wd, err := vmname.AbsDir("")
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	f := envFile{path: env.ProjectEnvFile(wd)}
	if rel, ok := env.ProjectRel(wd, f.path); ok {
		f = envFile{path: wd + "/" + rel, top: wd}
	}
	if st := e.envVerb("project-env", f, args); st != 0 {
		return st
	}
	// After a write that worked: when the file is new to the repository,
	// and the user is looking.
	if len(args) > 0 && args[0] == "set" {
		e.warnUnignored(ctx, f.path)
	}
	return 0
}

// warnUnignored warns, with the line that fixes it, when file is tracked by
// git or not ignored. Silent without git or a repository.
func (e *app) warnUnignored(ctx context.Context, file string) {
	if !gitx.Have() {
		return
	}
	out, err := gitx.Untrusted(ctx, "-C", filepath.Dir(file), "rev-parse", "--show-toplevel").Output()
	top := strings.TrimSuffix(string(out), "\n")
	if err != nil || top == "" {
		return
	}
	// git prints the top resolved (/var is a link to /private/var on
	// macOS): the file's spelling must be, or the prefix below misses and
	// the warning never fires.
	if phys, err := filepath.EvalSymlinks(file); err == nil {
		file = phys
	}
	// git prints C:/... on Windows, in either case for the drive.
	rel, ok := paths.CutPrefix(filepath.ToSlash(file), filepath.ToSlash(top)+"/")
	if !ok {
		// A worktree elsewhere, an odd spelling: not something to lecture about.
		return
	}
	qTop, qRel := env.SQEscape(top), env.SQEscape(rel)
	if gitx.Untrusted(ctx, "-C", top, "ls-files", "--error-unmatch", file).Run() == nil {
		fmt.Fprintf(e.io.Stderr, "Warning: %s is tracked by git: its contents are in the repository.\n", rel)
		fmt.Fprintf(e.io.Stderr, "         git -C '%s' rm --cached '%s' && echo '/%s' >> '%s/.gitignore'\n", qTop, qRel, qRel, qTop)
		return
	}
	err = gitx.Untrusted(ctx, "-C", top, "check-ignore", "-q", file).Run()
	var ee interface{ ExitCode() int }
	if errors.As(err, &ee) && ee.ExitCode() == 1 {
		fmt.Fprintf(e.io.Stderr, "Warning: %s is not ignored by git: it can be committed by accident.\n", rel)
		fmt.Fprintf(e.io.Stderr, "         echo '/%s' >> '%s/.gitignore'\n", qRel, qTop)
	}
}
