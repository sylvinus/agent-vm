package cli

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/sylvinus/agent-vm/internal/paths"
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

	once      sync.Once
	migrate   func() // before the backend is made, when set
	noMigrate bool   // see readOnlyBackend
	newBack   func() (vm.Backend, error)
	back      vm.Backend
	backErr   error
}

// backend is made on first use: most commands never need Lima. The first
// use moves 0.2's VMs (migrateOld), but for readOnlyBackend.
func (e *app) backend() (vm.Backend, error) {
	e.once.Do(func() {
		if e.migrate != nil && !e.noMigrate {
			e.migrate()
		}
		e.back, e.backErr = e.newBack()
	})
	return e.back, e.backErr
}

// readOnlyBackend is backend without the move of 0.2's VMs, which stops
// running ones: for commands that only look (doctor, info).
func (e *app) readOnlyBackend() (vm.Backend, error) {
	e.noMigrate = true
	return e.backend()
}

// migratedMarker says the VMs of 0.2 were moved into agent-vm's Lima home.
const migratedMarker = ".agent-vm-lima-migrated"

// oldLimaHome is where 0.2 kept its VMs: Lima's home, $LIMA_HOME or ~/.lima.
func oldLimaHome() string {
	if h := vm.UserLimaHome(); h != "" {
		return paths.Host(h)
	}
	return paths.Host(filepath.Join(paths.Home(), ".lima"))
}

// migrated reports whether 0.2's VMs were moved already.
func (e *app) migrated() bool {
	_, err := os.Stat(e.state.Path(migratedMarker))
	return err == nil
}

// migrateOld moves, once, the VMs agent-vm 0.2 made in the user's Lima home
// into its own (see LimaHome). Asked on a terminal, yes by default; done
// without one. A VM that could not be moved stays, and is offered again.
func (e *app) migrateOld(ctx context.Context, old, now string) {
	if e.migrated() || sameDir(old, now) {
		return
	}
	marker := e.state.Path(migratedMarker)
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
	if running {
		fmt.Fprintln(w, "Running ones are stopped first: sessions using them are cut.")
	}
	if e.ui.CanAsk() && !e.ui.AskYN("Move them there now?", true) {
		fmt.Fprintf(w, "Not moved: this agent-vm does not see them until they are. They stay in %s.\n", old)
		return
	}
	failed := false
	for _, v := range vms {
		to := vmname.FromOld(v.Name)
		fmt.Fprintf(w, "Moving %s...\n", v.Name)
		if err := vm.MoveOld(ctx, old, now, v.Name, to); err != nil {
			fmt.Fprintf(w, "Error: could not move %s: %v. It stays in %s.\n", v.Name, err, old)
			failed = true
			continue
		}
		if err := e.state.Rename(v.Name, to); err != nil {
			fmt.Fprintf(w, "Warning: %s moved, but not all that agent-vm knows of it: %v\n", to, err)
		}
	}
	if failed {
		return
	}
	if err := os.MkdirAll(string(e.state), 0o755); err == nil {
		_ = os.WriteFile(marker, []byte(old+"\n"), 0o644)
	}
	fmt.Fprintln(w, "Done: they keep their shares and settings, under their new names.")
}

// sameDir reports whether a and b are one folder, links resolved where they
// exist.
func sameDir(a, b string) bool {
	if fa, err := os.Stat(a); err == nil {
		if fb, err := os.Stat(b); err == nil {
			return os.SameFile(fa, fb)
		}
	}
	return filepath.Clean(a) == filepath.Clean(b)
}

// LimaHome is where agent-vm's Lima keeps its VMs: its own, so that the
// user's limactl, of another version, never runs them, and nothing of the
// user's own Lima is touched. AGENT_VM_LIMA_HOME overrides it.
func LimaHome(st state.Dir) string {
	if h := os.Getenv("AGENT_VM_LIMA_HOME"); h != "" {
		return paths.Host(h)
	}
	return st.Path("lima")
}

func newApp(io IO) (*app, error) {
	st, err := state.Default()
	if err != nil {
		return nil, err
	}
	u := ui.New()
	u.Stderr = io.Stderr
	e := &app{io: io, ui: u, state: st}
	// Names that fit this machine's socket paths (a long home, a long user
	// name): cut in their folder part, not refused.
	vmname.MaxLen = vm.MaxName(LimaHome(st))
	e.migrate = func() { e.migrateOld(context.Background(), oldLimaHome(), LimaHome(st)) }
	e.newBack = func() (vm.Backend, error) {
		// Every VM there is agent-vm's: list, rm and destroy-all take them
		// all. Never a Lima home the user's own VMs live in.
		if h := LimaHome(st); sameDir(h, oldLimaHome()) {
			return nil, fmt.Errorf("agent-vm's Lima home %s is also your own Lima's home: set AGENT_VM_LIMA_HOME to a folder for agent-vm alone", h)
		}
		return vm.NewLima(LimaHome(st), string(st))
	}
	return e, nil
}
