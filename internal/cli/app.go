package cli

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	agentvm "github.com/sylvinus/agent-vm"
	"github.com/sylvinus/agent-vm/internal/engine"
	"github.com/sylvinus/agent-vm/internal/env"
	"github.com/sylvinus/agent-vm/internal/host"
	"github.com/sylvinus/agent-vm/internal/mounts"
	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/policy"
	"github.com/sylvinus/agent-vm/internal/runscript"
	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/ui"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

// app is what the commands work with.
type app struct {
	io    IO
	ui    *ui.UI
	state state.Dir

	// migrate moves 0.2's VMs, when set: the first use of the backend by a
	// command that changes VMs runs it (see Options.BeforeChange).
	migrate func()
	// backend replaces Lima, for tests.
	testBackend vm.Backend

	eng    *agentvm.Engine
	engErr error
}

// engine is the engine the commands run VMs with, opened on first use: most
// commands never need Lima. It is opened again for each command, so that the
// environment it reads is the command's.
func (e *app) engine() (*agentvm.Engine, error) {
	if e.eng == nil && e.engErr == nil {
		e.eng, e.engErr = agentvm.Open(e.engineOptions())
	}
	return e.eng, e.engErr
}

// engineOptions are the options agent-vm's command line gives the engine:
// its files in the state folder, and the AGENT_VM_* variables.
func (e *app) engineOptions() agentvm.Options {
	div, _, _ := host.Divisor()
	return agentvm.Options{
		StateDir: string(e.state),
		LimaHome: LimaHome(e.state),
		AppName:  "agent-vm",
		Asker:    cliAsker{e},
		OnEvent:  e.onEvent,
		Backend:  e.testBackend,
		Policy:   func() (*policy.File, error) { return policy.Current(string(e.state), "agent-vm") },

		VolumesFile:    e.state.Path("volumes"),
		EnvFile:        e.state.Path("env"),
		RuntimeScript:  e.state.Path("runtime.sh"),
		ProjectEnvFile: env.ProjectEnvFile,
		ProjectRuntime: runscript.ProjectPath,

		UnsafeWritableGit: os.Getenv("AGENT_VM_UNSAFE_WRITABLE_GIT") == "1",
		SSHFSCache:        mounts.CacheOn(),
		HostShare:         div,
		Quiet:             quiet(),
		NeverShare:        []string{oldLimaHome()},
		TERM:              os.Getenv("TERM"),
		BeforeChange: func(context.Context) {
			if e.migrate != nil {
				e.migrate()
			}
		},
	}
}

// onEvent prints what the engine tells: progress on stdout, the rest on
// stderr.
func (e *app) onEvent(ev agentvm.Event) {
	switch {
	case ev.Title != "":
		e.ui.Box(ev.Title, ev.Text)
	case ev.Level == agentvm.Info:
		fmt.Fprintln(e.io.Stdout, ev.Text)
	default:
		fmt.Fprintln(e.io.Stderr, ev.Text)
	}
}

// cliAsker puts the engine's questions to the user on the terminal.
type cliAsker struct{ e *app }

func (a cliAsker) CanAsk() bool { return a.e.ui.CanAsk() }

func (a cliAsker) Ask(_ context.Context, q agentvm.Question) bool {
	if q.Title != "" && q.Detail != "" {
		a.e.ui.Box(q.Title, q.Detail)
	}
	return a.e.ui.AskYN(q.Prompt, q.Default)
}

// backend is the backend for a command that changes VMs: the first use also
// moves the VMs of older versions.
func (e *app) backend(ctx context.Context) (vm.Backend, error) {
	eng, err := e.engine()
	if err != nil {
		return nil, err
	}
	return eng.Change(ctx)
}

// readOnlyBackend is the backend for the commands that only look (list,
// status, doctor, info, install): no VM is moved. A command that goes on to
// change VMs asks for backend, which moves them then.
func (e *app) readOnlyBackend() (vm.Backend, error) {
	eng, err := e.engine()
	if err != nil {
		return nil, err
	}
	return eng.Backend()
}

// migratedMarker says the VMs of 0.2 were moved into agent-vm's Lima home.
const migratedMarker = ".agent-vm-lima-migrated"

// oldLimaHome is where 0.2 kept its VMs: Lima's home, $LIMA_HOME or ~/.lima.
func oldLimaHome() string { return engine.UserLimaHome() }

// absOr is p made absolute, as it is when that cannot be done: a relative
// folder would defeat the checks that compare locations.
func absOr(p string) string {
	if abs, err := filepath.Abs(p); err == nil {
		return abs
	}
	return p
}

// migrated reports whether 0.2's VMs were moved already.
func (e *app) migrated() bool {
	_, err := os.Stat(e.state.Path(migratedMarker))
	return err == nil
}

// unmovedOld are 0.2's VMs that have not been moved yet, and the Lima home
// they are in. None for an app with no move wired (migrate unset).
func (e *app) unmovedOld() ([]vm.OldVM, string) {
	old := oldLimaHome()
	if e.migrate == nil || e.migrated() || sameDir(old, LimaHome(e.state)) {
		return nil, old
	}
	vms, _ := vm.FindOld(old, vmname.OldPrefix)
	return vms, old
}

// layoutPending are the VMs of 0.3.0 that have not been moved yet to a
// folder each. None for an app with no move wired.
func (e *app) layoutPending() []string {
	if e.migrate == nil {
		return nil
	}
	return e.state.LegacyVMs(LimaHome(e.state))
}

// migrateOld moves, once, the VMs agent-vm 0.2 made in the user's Lima home
// into its own (see LimaHome). Asked on a terminal, yes by default. Without
// one, the stopped ones are moved and the running ones left: moving stops
// them, which cuts sessions nobody agreed to cut. A VM that could not be
// moved stays, and is offered again.
func (e *app) migrateOld(ctx context.Context, old, now string) {
	if e.migrated() || sameDir(old, now) {
		return
	}
	vms, err := vm.FindOld(old, vmname.OldPrefix)
	if err != nil || len(vms) == 0 {
		return
	}
	w := e.io.Stderr
	fmt.Fprintf(w, "agent-vm now keeps its VMs in %s, apart from your own Lima's. Found in %s:\n", now, old)
	running := false
	for _, v := range vms {
		state := ""
		if v.Running {
			state, running = " (running)", true
		}
		fmt.Fprintf(w, "  %s, as %s%s\n", v.Name, vmname.FromOld(v.Name), state)
	}
	canAsk := e.ui.CanAsk()
	if running && canAsk {
		fmt.Fprintln(w, "Running ones are stopped first: sessions using them are cut.")
	}
	if canAsk && !e.ui.AskYN("Move them there now?", true) {
		fmt.Fprintf(w, "Not moved: this agent-vm does not see them until they are. They stay in %s.\n", old)
		return
	}
	failed := false
	for _, v := range vms {
		if v.Running && !canAsk {
			fmt.Fprintf(w, "%s is running and stays in %s: no terminal to ask whether to cut its sessions. Stop it, or run agent-vm in a terminal.\n", v.Name, old)
			failed = true
			continue
		}
		to := vmname.FromOld(v.Name)
		fmt.Fprintf(w, "Moving %s...\n", v.Name)
		if err := vm.MoveOld(ctx, old, now, v.Name, to); err != nil {
			fmt.Fprintf(w, "Error: could not move %s: %v. It stays in %s.\n", v.Name, err, old)
			failed = true
			continue
		}
		if err := e.state.LegacyRename(v.Name, to); err != nil {
			fmt.Fprintf(w, "Warning: %s moved, but not all that agent-vm knows of it: %v\n", to, err)
		}
	}
	if failed {
		return
	}
	if err := e.state.Write(migratedMarker, []byte(old+"\n")); err != nil {
		fmt.Fprintf(w, "Warning: could not record that they were moved: %v. They are looked for in %s again next time.\n", err, old)
	}
	fmt.Fprintln(w, "Done: they keep their shares and settings, under their new names.")
}

// sameDir reports whether a and b are one folder, links resolved where they
// exist.
func sameDir(a, b string) bool { return engine.SameDir(a, b) }

// LimaHome is agent-vm's own Lima home: what Lima keeps for every VM (its
// SSH key, its networks), so that the user's limactl, of another version,
// never runs the VMs, and nothing of the user's own Lima is touched. The VMs
// are in the state folder's vms/. AGENT_VM_LIMA_HOME overrides it, made
// absolute.
func LimaHome(st state.Dir) string {
	if h := os.Getenv("AGENT_VM_LIMA_HOME"); h != "" {
		return paths.Host(absOr(h))
	}
	return st.LimaHome()
}

func newApp(io IO) (*app, error) {
	st, err := state.Default()
	if err != nil {
		return nil, err
	}
	u := ui.New()
	u.Stderr = io.Stderr
	e := &app{io: io, ui: u, state: st}
	e.migrate = func() { e.migrateOld(context.Background(), oldLimaHome(), LimaHome(st)) }
	// Names that fit this machine's socket paths (a long home, a long user
	// name): cut in their folder part, not refused.
	vmname.MaxLen = vm.MaxName(st.VMs())
	return e, nil
}

// quiet is AGENT_VM_QUIET=1: notices that are not about a risk to the host
// are not printed.
func quiet() bool { return os.Getenv("AGENT_VM_QUIET") == "1" }
