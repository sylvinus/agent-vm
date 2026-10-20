package engine

import (
	"context"
	"strings"

	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

// migrationLock is the lock of the move of 0.3.0's VMs: a file in locks/,
// as the VMs' are.
const migrationLock = "migrate"

// LayoutPending are the VMs of 0.3.0 that have not been moved yet to a folder
// each: they are not listed until they are.
func (e *Engine) LayoutPending() []string {
	return e.state.LegacyVMs(e.opts.LimaHome)
}

// migrateLayout moves 0.3.0's VMs to a folder each, vms/<name>/ (see
// state.MigrateLayout), once, by the first call that changes VMs. A VM that
// runs cannot move: if the Asker agrees, it is stopped; else it stays for the
// next call.
func (e *Engine) migrateLayout(ctx context.Context) {
	home := e.opts.LimaHome
	if !e.state.PendingLayout(home) {
		return
	}
	unlock, err := e.lockVM(ctx, migrationLock)
	if err != nil {
		e.warnf("Error: could not lock the move of the VMs: %v", err)
		return
	}
	defer unlock()
	// Another run did it while this one waited.
	if !e.state.PendingLayout(home) {
		return
	}
	if vms := e.state.LegacyVMs(home); len(vms) > 0 {
		e.warnf("%s now keeps each VM in a folder of its own, %s. Moving %s...", e.app, e.state.VMs(), strings.Join(vms, ", "))
	}
	ops := state.LayoutOps{
		Home:     home,
		Template: vmname.Template,
		Log:      e.writer(Warning, ""),
		Running:  func(name string) bool { return vm.LegacyRunning(ctx, home, name) },
		Stop:     func(name string) error { return vm.StopLegacy(ctx, home, name) },
	}
	if e.opts.Asker.CanAsk() {
		ops.Ask = func(running []string) bool {
			e.warnf("Running, they cannot move: %s.", strings.Join(running, ", "))
			return e.opts.Asker.Ask(ctx, Question{Kind: QStopToMove, Prompt: "Stop them now to move them? Sessions using them are cut.", Default: true})
		}
	}
	if err := e.state.MigrateLayout(ops); err != nil {
		e.warnf("Error: %v", err)
	}
}
