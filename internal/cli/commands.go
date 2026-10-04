package cli

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/ui"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

// session is what runs in the VM once it is up: an agent, a shell, a
// command. It returns the exit status.
type session func(s *start) int

// inVM starts this directory's VM with opts, runs fn, then deletes the VM
// when --rm asked. --scratch: see scratch.
func (e *app) inVM(ctx context.Context, opts VMOpts, fn session) int {
	dir, err := vmname.AbsDir("")
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	if opts.Scratch {
		return e.scratch(ctx, opts, dir, fn)
	}
	s := &start{app: e, ctx: ctx, opts: opts, dir: dir, name: vmname.Name(dir)}
	if s.ensureRunning() != nil {
		return 1
	}
	s.printResources()
	// A Ctrl-C is the command's, in the VM, as a shell leaves it to the job
	// it waits on: this run goes on to --rm and the terminal's reset.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)
	st := fn(s)
	signal.Stop(sig)
	ui.ResetTermModes(os.Stdout)
	if opts.RM {
		fmt.Fprintln(e.io.Stdout, "Removing VM...")
		e.rmCmd(ctx, nil)
	}
	return st
}

// printResources says what the VM has, and when the base it was cloned
// from was built: its agents and packages are that old.
func (s *start) printResources() {
	if inst, err := s.get(s.name); err == nil && inst != nil {
		fmt.Fprintf(s.io.Stdout, "  Resources: CPUs: %d, Memory: %d GiB, Disk: %d GiB\n", inst.CPUs, inst.Memory>>30, inst.Disk>>30)
	}
	if built, err := strconv.ParseInt(s.state.Read(s.state.Marker(state.VersionOf, s.name)), 10, 64); err == nil && built >= 0 {
		fmt.Fprintf(s.io.Stdout, "  Base VM: built %s\n", time.Unix(built, 0).Format("2006-01-02"))
	}
}

// lima runs args in the VM through a login zsh, from the project: agent PATH
// entries and ~/.agent-vm.env are in ~/.zshenv. The command and its
// arguments are positional parameters, never re-parsed; `env --` runs it,
// leading VAR=value assignments working and a command starting with - not
// taken for env's option. A command that is not there is said so, with
// env's status (an agent installed only as an editor extension has none);
// a path is env's to run, and to say why it cannot (126).
func (s *start) lima(tty bool, args ...string) int {
	b, err := s.backend()
	if err != nil {
		return 1
	}
	code, err := b.Shell(s.ctx, s.name, vm.ShellOpts{
		Workdir: paths.Guest(s.dir),
		Args: append([]string{"zsh", "-l", "-c",
			`case "$1" in *=*|*/*) ;; *) command -v -- "$1" >/dev/null || { print -r -- "agent-vm: $1 is not installed in this VM." >&2; exit 127; } ;; esac; exec env -- "$@"`,
			"agent-vm"}, args...),
		Stdin: s.io.Stdin, Stdout: s.io.Stdout, Stderr: s.io.Stderr, Interactive: tty,
	})
	if err != nil {
		s.warnf("Error: %v", err)
		return 1
	}
	return code
}

// The agents, with the flag that lets each work unattended (safe in the
// VM), and a terminal for the full-screen ones.
var agents = map[string]struct {
	cmd []string
	tty bool
}{
	// The VM also enforces bypass mode with managed settings: Claude Code
	// drops the flag when it relaunches itself.
	"claude": {[]string{"claude", "--dangerously-skip-permissions"}, false},
	// Approves every prompt that is not explicitly denied.
	"opencode": {[]string{"opencode", "--auto"}, true},
	"codex":    {[]string{"codex", "--dangerously-bypass-approvals-and-sandbox"}, false},
	"vibe":     {[]string{"vibe", "--agent", "auto-approve"}, true},
	// No permission prompts: it runs every tool as asked.
	"pi": {[]string{"pi"}, true},
}

func (e *app) agentCmd(ctx context.Context, agent string, opts VMOpts, args []string) int {
	a := agents[agent]
	rest, tty, err := opts.split(args)
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	cmd := append(append([]string(nil), a.cmd...), rest...)
	return e.inVM(ctx, opts, func(s *start) int { return s.lima(a.tty || tty, cmd...) })
}

// `run [--tty] <command> [args]`: --tty gives the command a terminal, which
// full-screen programs need to draw.
func (e *app) runCmd(ctx context.Context, opts VMOpts, args []string) int {
	rest, tty, err := opts.split(args)
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	if len(rest) == 0 {
		fmt.Fprintln(e.io.Stderr, "Usage: agent-vm run [--tty] <command> [args]")
		return 1
	}
	return e.inVM(ctx, opts, func(s *start) int { return s.lima(tty, rest...) })
}

// `shell [-c "command"]`: a login zsh in the VM, ~/.zshenv loaded. A word
// it does not know is an error, not something skipped.
func (e *app) shellCmd(ctx context.Context, opts VMOpts, args []string) int {
	command := ""
	for len(args) > 0 {
		n, err := opts.take(args)
		if err != nil {
			fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
			return 1
		}
		if n > 0 {
			args = args[n:]
			continue
		}
		switch args[0] {
		case "-c", "--command":
			if len(args) < 2 || args[1] == "" {
				fmt.Fprintln(e.io.Stderr, "Error: -c/--command requires a command string.")
				return 1
			}
			command, args = args[1], args[2:]
		default:
			fmt.Fprintf(e.io.Stderr, "Error: unknown argument for shell: %s\nUsage: agent-vm [vm options] shell [-c \"command\"]\n", args[0])
			return 1
		}
	}
	return e.inVM(ctx, opts, func(s *start) int {
		if command != "" {
			code, _ := s.shellTo(false, "zsh", "-l", "-c", command)
			return code
		}
		fmt.Fprintf(s.io.Stdout, "VM: %s | Dir: %s\n", s.name, s.dir)
		if s.opts.RM {
			fmt.Fprintln(s.io.Stdout, "Type 'exit' to leave. VM will be destroyed after exit.")
		} else {
			fmt.Fprintln(s.io.Stdout, "Type 'exit' to leave (VM keeps running). Use 'agent-vm stop' to stop it.")
		}
		code, _ := s.shellTo(true, "zsh", "-l")
		return code
	})
}

// shellTo runs args in the VM from the project, on the terminal.
func (s *start) shellTo(tty bool, args ...string) (int, error) {
	b, err := s.backend()
	if err != nil {
		return 1, err
	}
	return b.Shell(s.ctx, s.name, vm.ShellOpts{Workdir: paths.Guest(s.dir), Args: args,
		Stdin: s.io.Stdin, Stdout: s.io.Stdout, Stderr: s.io.Stderr, Interactive: tty})
}

// scratch: a new VM of its own, sharing nothing, deleted once fn returns,
// whatever it returns, unless the user keeps it a while to look inside. A
// Ctrl-C ends the command in the VM, not this run, which goes on to the
// deletion. A run killed outright leaves its VM recorded with its pid, and
// the next scratch run deletes it.
func (e *app) scratch(ctx context.Context, opts VMOpts, dir string, fn session) int {
	for _, left := range e.scratchLeftovers() {
		fmt.Fprintf(e.io.Stdout, "Deleting scratch VM '%s', left by a run that did not finish...\n", left)
		e.deleteVM(ctx, left)
	}
	name, err := vmname.Scratch(dir)
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	if err := os.MkdirAll(string(e.state), 0o755); err != nil {
		return 1
	}
	if err := os.WriteFile(e.state.Marker(state.ScratchOf, name), []byte(strconv.Itoa(os.Getpid())+"\n"), 0o644); err != nil {
		return 1
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)
	defer signal.Stop(sig)
	opts.RM = true
	s := &start{app: e, ctx: ctx, opts: opts, dir: dir, name: name}
	st := 1
	if s.ensureRunning() == nil {
		s.printResources()
		st = fn(s)
		ui.ResetTermModes(os.Stdout)
		// Asked before the deletion, when it can be (yes by default): a no
		// opens a shell in the VM, to look at what the command left, and
		// asks again on its exit. No terminal, or a question cut short,
		// deletes.
		for e.ui.CanAsk() && !e.ui.AskYN(fmt.Sprintf("Delete scratch VM '%s'?", name), true) {
			fmt.Fprintf(e.io.Stdout, "A shell in scratch VM '%s'. Type 'exit' to be asked again.\n", name)
			s.shellTo(true, "zsh", "-l")
			ui.ResetTermModes(os.Stdout)
		}
	}
	fmt.Fprintf(e.io.Stdout, "Deleting scratch VM '%s'...\n", name)
	if !e.deleteVM(ctx, name) {
		st = 1
	}
	return st
}

// scratchLeftovers are the scratch VMs a run could not delete (killed, its
// terminal closed): recorded by a run whose pid is gone. A reused pid only
// delays the cleanup. Only names Scratch makes: these go unasked.
func (e *app) scratchLeftovers() []string {
	ents, _ := os.ReadDir(string(e.state))
	var out []string
	for _, f := range ents {
		name, ok := strings.CutPrefix(f.Name(), state.ScratchOf)
		if !ok || !vmname.IsScratch(name) {
			continue
		}
		pid, err := strconv.Atoi(e.state.Read(filepath.Join(string(e.state), f.Name())))
		if err == nil && pid > 0 && alive(pid) {
			continue
		}
		out = append(out, name)
	}
	return out
}
