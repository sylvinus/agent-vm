package cli

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	agentvm "github.com/sylvinus/agent-vm"
	"github.com/sylvinus/agent-vm/agents"
	"github.com/sylvinus/agent-vm/internal/engine"
	"github.com/sylvinus/agent-vm/internal/ui"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

// start is one run of a command in a project's VM.
type start struct {
	*app
	ctx  context.Context
	opts VMOpts
	vm   *agentvm.VM
	name string // the VM
	dir  string // the project, as the shell spells it
}

func (s *start) warnf(format string, a ...any) {
	fmt.Fprintf(s.io.Stderr, format+"\n", a...)
}

// spec is what the options ask of the VM.
func (o VMOpts) spec() agentvm.Spec {
	sp := agentvm.Spec{
		CPUs: o.CPUs, MemoryGiB: o.Memory, DiskGiB: o.Disk,
		Reset: o.Reset, ReadOnly: o.ReadOnly, NoShares: o.NoShares || o.Scratch, UnsafeWritableGit: o.UnsafeWritableGit,
	}
	if o.SSHPort >= 0 {
		p := o.SSHPort
		sp.SSHPort = &p
	}
	switch {
	case o.UnsafeNoPrompts:
		sp.UnsafeNoPrompts = "--unsafe-disable-security-prompts"
	case os.Getenv("AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS") == "1":
		sp.UnsafeNoPrompts = "AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1"
	}
	return sp
}

// session is what runs in the VM once it is up: an agent, a shell, a
// command. It returns the exit status.
type session func(s *start) int

// endedBySignal is ctx for a run that a kill or a closed terminal (SIGTERM,
// SIGHUP) must end: the command in the VM stops with it, and the cleanup
// that follows (--rm, --scratch) runs on a context that does not end. A
// Ctrl-C is not one: see inVM. Signals after the first are swallowed until
// stop, so that the cleanup is not cut short.
func endedBySignal(parent context.Context) (ctx context.Context, stop func()) {
	ctx, cancel := context.WithCancel(parent)
	sig := make(chan os.Signal, 4)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGHUP)
	done := make(chan struct{})
	go func() {
		for {
			select {
			case <-sig:
				cancel()
			case <-done:
				return
			}
		}
	}()
	return ctx, func() {
		signal.Stop(sig)
		close(done)
		cancel()
	}
}

// removeVM stops and deletes name, saying so, and reports whether it is gone.
func (e *app) removeVM(ctx context.Context, name string) bool {
	fmt.Fprintf(e.io.Stdout, "Stopping and deleting VM '%s'...\n", name)
	eng, err := e.engine()
	if err != nil || !eng.Delete(ctx, name) {
		return false
	}
	fmt.Fprintln(e.io.Stdout, "VM destroyed.")
	return true
}

// inVM starts this directory's VM with opts, runs fn, then deletes the VM
// when --rm asked: after fn whatever it returns, and after a start that
// failed when this run made the VM (a VM that was there before is not
// deleted for a start that did not go through). A kill or a closed terminal
// (SIGTERM, SIGHUP) ends the command and still deletes. --scratch: see
// scratch.
func (e *app) inVM(ctx context.Context, opts VMOpts, fn session) int {
	if err := opts.check(); err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return exitUsage
	}
	dir, err := vmname.AbsDir("")
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	cleanup := context.WithoutCancel(ctx)
	ctx, stop := endedBySignal(ctx)
	defer stop()
	if opts.Scratch {
		return e.scratch(ctx, cleanup, opts, dir, fn)
	}
	eng, err := e.engine()
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	var v *agentvm.VM
	if opts.Name != "" {
		v, err = eng.NamedVM(opts.Name, dir)
	} else {
		v, err = eng.ProjectVM(dir)
	}
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	s := &start{app: e, ctx: ctx, opts: opts, vm: v, dir: dir, name: v.Name}
	st := 1
	started := v.Ensure(ctx, opts.spec()) == nil
	if started {
		s.printResources()
		// A Ctrl-C is the command's, in the VM, as a shell leaves it to the job
		// it waits on: this run goes on to --rm and the terminal's reset.
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, os.Interrupt)
		st = fn(s)
		signal.Stop(sig)
		ui.ResetTermModes(os.Stdout)
	}
	if opts.RM && (started || v.Created()) && !e.removeVM(cleanup, s.name) && st == 0 {
		st = 1
	}
	return st
}

// printResources says what the VM has, and when the base it was cloned
// from was built: its agents and packages are that old.
func (s *start) printResources() {
	d, err := s.vm.Details(s.ctx)
	if err != nil || d == nil {
		return
	}
	if inst := d.Instance; inst != nil {
		fmt.Fprintln(s.io.Stdout, engine.ResourcesLine(inst))
	}
	if b := d.Base; b != nil && b.Built > 0 {
		fmt.Fprintf(s.io.Stdout, "  Base VM: built %s\n", time.Unix(b.Built, 0).Format("2006-01-02"))
	}
}

// lima runs args in the VM through a login zsh, from the project (see
// engine.VM.Exec).
func (s *start) lima(tty bool, args ...string) int {
	code, err := s.vm.Exec(s.ctx, agentvm.Exec{Args: args, TTY: tty, Stdin: s.io.Stdin, Stdout: s.io.Stdout, Stderr: s.io.Stderr})
	if err != nil {
		s.warnf("Error: %v", err)
		return 1
	}
	return code
}

// agentCmd runs one of the agents (see package agents), with the flag that
// lets it work unattended, and a terminal for the full-screen ones.
func (e *app) agentCmd(ctx context.Context, a agents.Agent, opts VMOpts, args []string) int {
	rest, tty, err := opts.split(args)
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return exitUsage
	}
	cmd := append(append([]string(nil), a.Command...), rest...)
	return e.inVM(ctx, opts, func(s *start) int { return s.lima(a.TTY || tty, cmd...) })
}

// `run [--tty] <command> [args]`: --tty gives the command a terminal, which
// full-screen programs need to draw.
func (e *app) runCmd(ctx context.Context, opts VMOpts, args []string) int {
	rest, tty, err := opts.split(args)
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return exitUsage
	}
	if len(rest) == 0 {
		fmt.Fprintln(e.io.Stderr, "Usage: agent-vm run [--tty] <command> [args]")
		return exitUsage
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
			return exitUsage
		}
		if n > 0 {
			args = args[n:]
			continue
		}
		switch args[0] {
		case "-c", "--command":
			if len(args) < 2 || args[1] == "" {
				fmt.Fprintln(e.io.Stderr, "Error: -c/--command requires a command string.")
				return exitUsage
			}
			command, args = args[1], args[2:]
		default:
			fmt.Fprintf(e.io.Stderr, "Error: unknown argument for shell: %s\nUsage: agent-vm [vm options] shell [-c \"command\"]\n", args[0])
			return exitUsage
		}
	}
	return e.inVM(ctx, opts, func(s *start) int {
		if command != "" {
			return s.shell(false, "zsh", "-l", "-c", command)
		}
		fmt.Fprintf(s.io.Stdout, "VM: %s | Dir: %s\n", s.name, s.dir)
		if s.opts.RM {
			fmt.Fprintln(s.io.Stdout, "Type 'exit' to leave. VM will be destroyed after exit.")
		} else {
			fmt.Fprintln(s.io.Stdout, "Type 'exit' to leave (VM keeps running). Use 'agent-vm stop' to stop it.")
		}
		return s.shell(true, "zsh", "-l")
	})
}

// shell runs args in the VM from the project, on the terminal, and returns
// the exit status. When the shell could not run at all (the VM is not
// running, ssh fails), the reason is said and the status is 1: a caller must
// not read that as the command's success.
func (s *start) shell(tty bool, args ...string) int {
	code, err := s.vm.Shell(s.ctx, agentvm.Exec{Args: args, TTY: tty, Stdin: s.io.Stdin, Stdout: s.io.Stdout, Stderr: s.io.Stderr})
	if err != nil {
		s.warnf("Error: %v", err)
		return 1
	}
	return code
}

// scratch: a new VM of its own, sharing nothing, deleted once fn returns,
// whatever it returns, unless the user keeps it a while to look inside. A
// Ctrl-C ends the command in the VM, not this run, which goes on to the
// deletion. A run killed outright leaves its VM recorded with its pid, and
// the next scratch run deletes it. cleanup is the context of the deletions,
// which a kill of this run (ctx) does not end.
func (e *app) scratch(ctx, cleanup context.Context, opts VMOpts, dir string, fn session) int {
	eng, err := e.engine()
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	dead, unknown := eng.ScratchLeftovers()
	for _, left := range dead {
		fmt.Fprintf(e.io.Stdout, "Deleting scratch VM '%s', left by a run that did not finish...\n", left)
		eng.Delete(cleanup, left)
	}
	for _, left := range unknown {
		fmt.Fprintf(e.io.Stderr, "Note: scratch VM '%s' has a record without a process number, so it is not known whether a run still uses it: left alone. 'agent-vm rm %s' deletes it.\n", left, left)
	}
	v, err := eng.NewScratchVM(dir)
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	name := v.Name
	opts.RM = true
	s := &start{app: e, ctx: ctx, opts: opts, vm: v, dir: dir, name: name}
	st := 1
	if v.Ensure(ctx, opts.spec()) == nil {
		s.printResources()
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, os.Interrupt)
		st = fn(s)
		signal.Stop(sig)
		ui.ResetTermModes(os.Stdout)
		// Asked before the deletion, when it can be (yes by default): a no
		// opens a shell in the VM, to look at what the command left, and
		// asks again on its exit. No terminal, a question cut short, or a
		// kill, deletes.
		for ctx.Err() == nil && e.ui.CanAsk() && !e.ui.AskYN(fmt.Sprintf("Delete scratch VM '%s'?", name), true) {
			fmt.Fprintf(e.io.Stdout, "A shell in scratch VM '%s'. Type 'exit' to be asked again.\n", name)
			s.shell(true, "zsh", "-l")
			ui.ResetTermModes(os.Stdout)
		}
	}
	fmt.Fprintf(e.io.Stdout, "Deleting scratch VM '%s'...\n", name)
	if !eng.Delete(cleanup, name) {
		st = 1
	}
	return st
}
