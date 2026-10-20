package engine

import (
	"context"
	"errors"
	"io"
	"os"
	"strconv"

	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

// VM is the VM of a project folder (or a scratch one): the handle to make it
// exist and run, to run commands in it, and to stop and remove it.
type VM struct {
	e *Engine
	// Name is the VM's name; Dir the project folder, as the shell spells it.
	Name, Dir string

	scratch, named bool
	created        bool
}

// ProjectVM is the VM of the folder dir ("" for the current one), named from
// the folder as `name` prints it. Nothing is made yet: see Ensure.
func (e *Engine) ProjectVM(dir string) (*VM, error) {
	abs, err := vmname.AbsDir(dir)
	if err != nil {
		return nil, err
	}
	return &VM{e: e, Name: vmname.Name(abs), Dir: abs}, nil
}

// NewScratchVM is a new VM of a name of its own that shares nothing, for dir
// ("" for the current folder): its owner is recorded so that a run that dies
// without removing it leaves it to be found (ScratchLeftovers). The caller
// removes it.
func (e *Engine) NewScratchVM(dir string) (*VM, error) {
	abs, err := vmname.AbsDir(dir)
	if err != nil {
		return nil, err
	}
	name, err := vmname.Scratch(abs)
	if err != nil {
		return nil, err
	}
	// Before the clone: the VM's folder, which holds the record, exists
	// before Lima makes its own in it.
	if err := e.state.UpdateMeta(name, func(m *state.Metadata) { m.ScratchPID = os.Getpid() }); err != nil {
		return nil, errors.New("could not record scratch VM '" + name + "': " + err.Error())
	}
	return &VM{e: e, Name: name, Dir: abs, scratch: true}, nil
}

// NamedVM is the VM the user calls name (see vmname.ValidateCustom for what
// a name is), for the folder dir ("" for the current one). It belongs to the
// folder it is made in, or to none when it is made with Spec.NoShares, and
// Ensure refuses it from another folder if it shares one.
func (e *Engine) NamedVM(name, dir string) (*VM, error) {
	if err := vmname.ValidateCustom(name); err != nil {
		return nil, err
	}
	abs, err := vmname.AbsDir(dir)
	if err != nil {
		return nil, err
	}
	return &VM{e: e, Name: name, Dir: abs, named: true}, nil
}

// VMOf is an existing VM reached by its name, as list prints it, whatever its
// kind: to stop it, remove it, look at it. Ensure is for the VMs the other
// constructors make.
func (e *Engine) VMOf(name string) *VM {
	return &VM{e: e, Name: name}
}

// ScratchLeftovers are the scratch VMs a run could not delete (killed, its
// terminal closed), by the record in their folder: dead are those recorded
// by a run whose pid is gone (a reused pid only delays the cleanup), unknown
// those whose record holds no pid or cannot be read, which is no proof that
// no run uses them. Only names NewScratchVM makes.
func (e *Engine) ScratchLeftovers() (dead, unknown []string) {
	for _, name := range e.state.Names() {
		if !vmname.IsScratch(name) {
			continue
		}
		m, err := e.state.Meta(name)
		switch {
		case err != nil || m.ScratchPID < 0:
			unknown = append(unknown, name)
		case m.ScratchPID == 0:
			// No record: a project's VM that looks like one.
		case !alive(m.ScratchPID):
			dead = append(dead, name)
		}
	}
	return dead, unknown
}

// Ensure makes the VM exist and run, with its shares as spec asks: cloned
// from the base, changed while stopped, the security checks done first. Under
// the VM's lock: another run for the same VM waits for this one to be done
// with it. Progress and warnings are events; an error is also told as an
// Error event, with a Failure (or a *RefusedError) that errors.Is matches
// against Err... values.
func (v *VM) Ensure(ctx context.Context, spec Spec) error {
	s := &session{Engine: v.e, ctx: ctx, spec: spec, base: spec.templateName(), name: v.Name, dir: v.Dir, scratch: v.scratch, named: v.named}
	err := s.ensureRunning()
	v.created = v.created || s.created
	return err
}

// Created reports whether Ensure made the VM, and it is still there: a
// start that failed after that is told so that the caller can remove it.
func (v *VM) Created() bool { return v.created }

// Details is what is known of a VM.
type Details struct {
	// Instance is the VM as the backend has it; nil when there is none.
	Instance *vm.Instance
	// Base is the template it was cloned from, as it was; nil when not
	// known.
	Base *state.Base
}

// Details are the VM's resources and where it comes from.
func (v *VM) Details(ctx context.Context) (*Details, error) {
	inst, err := v.e.get(ctx, v.Name)
	if err != nil {
		return nil, err
	}
	return &Details{Instance: inst, Base: v.e.state.Known(v.Name).Base}, nil
}

// Exec is a command to run in the VM.
type Exec struct {
	// Args is the command: its first word is looked up in the VM's PATH, or
	// a path. Leading NAME=value words set the environment. It runs from the
	// project folder, in a login zsh, so the PATH of the agents and
	// ~/.agent-vm.env apply.
	Args []string
	// TTY gives it a terminal, which full-screen programs need.
	TTY            bool
	Stdin          io.Reader
	Stdout, Stderr io.Writer
}

// Exec runs x.Args in the running VM through a login zsh, from the project:
// agent PATH entries and ~/.agent-vm.env are in ~/.zshenv. The command and
// its arguments are positional parameters, never re-parsed; `env --` runs
// it, leading VAR=value assignments working and a command starting with -
// not taken for env's option. A command that is not there is said so, with
// env's status (an agent installed only as an editor extension has none); a
// path is env's to run, and to say why it cannot (126). It returns the
// command's exit status.
func (v *VM) Exec(ctx context.Context, x Exec) (int, error) {
	b, err := v.e.Backend()
	if err != nil {
		return 1, err
	}
	script := `case "$1" in *=*|*/*) ;; *) command -v -- "$1" >/dev/null || { print -r -- "` + v.e.app + `: $1 is not installed in this VM." >&2; exit 127; } ;; esac; exec env -- "$@"`
	return b.Shell(ctx, v.Name, vm.ShellOpts{
		Workdir: paths.Guest(v.Dir),
		Args:    append([]string{"zsh", "-l", "-c", script, v.e.app}, x.Args...),
		Stdin:   x.Stdin, Stdout: x.Stdout, Stderr: x.Stderr, Interactive: x.TTY,
	})
}

// Shell runs x.Args by the VM user's login shell, from the project folder,
// as given: {"zsh", "-l"} is a shell. It returns the exit status.
func (v *VM) Shell(ctx context.Context, x Exec) (int, error) {
	b, err := v.e.Backend()
	if err != nil {
		return 1, err
	}
	return b.Shell(ctx, v.Name, vm.ShellOpts{Workdir: paths.Guest(v.Dir), Args: x.Args,
		Stdin: x.Stdin, Stdout: x.Stdout, Stderr: x.Stderr, Interactive: x.TTY})
}

// Stop stops the VM, and reports whether it is known to be stopped.
func (v *VM) Stop(ctx context.Context) bool { return v.e.Stop(ctx, v.Name) }

// Remove stops and deletes the VM with all that is known of it, and reports
// whether it is gone.
func (v *VM) Remove(ctx context.Context) bool { return v.e.Delete(ctx, v.Name) }

// ResourcesLine says what the VM has.
func ResourcesLine(inst *vm.Instance) string {
	return "  Resources: CPUs: " + strconv.Itoa(inst.CPUs) + ", Memory: " + strconv.FormatInt(inst.Memory>>30, 10) + " GiB, Disk: " + strconv.FormatInt(inst.Disk>>30, 10) + " GiB"
}
