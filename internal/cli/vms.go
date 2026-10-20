package cli

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"text/tabwriter"

	"github.com/docker/go-units"

	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

// target is the VM `stop` and `rm` act on: the current directory's, or one
// named as `list` prints it. Agent-vm's Lima home holds its VMs alone (see
// newApp), so any name there is one of them. A VM no folder names any more
// (renamed, deleted) is reached by its name. The status is 0 when the VM is
// found, else the exit status of the command.
func (e *app) target(ctx context.Context, verb string, args []string) (name string, status int) {
	switch len(args) {
	case 0:
		wd, err := vmname.AbsDir("")
		if err != nil {
			fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
			return "", 1
		}
		name = vmname.Name(wd)
	case 1:
		name = args[0]
	default:
		fmt.Fprintf(e.io.Stderr, "Usage: agent-vm %s [vm-name]\n", verb)
		return "", exitUsage
	}
	b, err := e.backend(ctx)
	if err == nil {
		_, err = b.Get(ctx, name)
	}
	switch {
	case err == nil:
		return name, 0
	case errors.Is(err, vm.ErrNotFound) && len(args) == 0:
		fmt.Fprintln(e.io.Stderr, "No VM found for this directory.")
		fmt.Fprintf(e.io.Stderr, "Run 'agent-vm list' to see existing VMs, then 'agent-vm %s <vm-name>'.\n", verb)
	case errors.Is(err, vm.ErrNotFound):
		fmt.Fprintf(e.io.Stderr, "Error: no such VM: %s\n", name)
		fmt.Fprintln(e.io.Stderr, "Run 'agent-vm list' to see existing VMs.")
	default:
		fmt.Fprintf(e.io.Stderr, "Error: could not query Lima: %v\n", err)
	}
	return "", 1
}

func (e *app) stopCmd(ctx context.Context, args []string) int {
	name, status := e.target(ctx, "stop", args)
	if status != 0 {
		return status
	}
	fmt.Fprintf(e.io.Stdout, "Stopping VM '%s'...\n", name)
	if !e.stopVM(ctx, name) {
		fmt.Fprintf(e.io.Stderr, "Error: VM '%s' is still running, or Lima cannot say. See 'agent-vm list'.\n", name)
		return 1
	}
	fmt.Fprintln(e.io.Stdout, "VM stopped.")
	return 0
}

// stopVM stops name, and reports whether it is known to be stopped.
func (e *app) stopVM(ctx context.Context, name string) bool {
	eng, err := e.engine()
	return err == nil && eng.Stop(ctx, name)
}

func (e *app) rmCmd(ctx context.Context, args []string) int {
	name, status := e.target(ctx, "rm", args)
	if status != 0 {
		return status
	}
	if !e.removeVM(ctx, name) {
		return 1
	}
	return 0
}

// deleteVM stops and deletes name, then forgets what agent-vm knew of it.
// Fails, saying so, when it is still there (or cannot be asked): --reset
// would otherwise go on with the old VM and its shares.
func (e *app) deleteVM(ctx context.Context, name string) bool {
	eng, err := e.engine()
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: could not delete VM '%s'. See 'agent-vm list', then retry.\n", name)
		return false
	}
	return eng.Delete(ctx, name)
}

// `destroy-all`: every agent-vm VM, the base template included: the command
// that gives the disk space back. `agent-vm setup` rebuilds the template.
func (e *app) destroyAllCmd(ctx context.Context, args []string) int {
	if len(args) > 0 {
		fmt.Fprintln(e.io.Stderr, "Usage: agent-vm destroy-all")
		return exitUsage
	}
	vms, err := e.agentVMs(ctx)
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: could not query Lima: %v\n", err)
		return 1
	}
	if len(vms) == 0 {
		fmt.Fprintln(e.io.Stdout, "No agent-vm VMs found.")
		return 0
	}
	fmt.Fprintln(e.io.Stdout, "This will destroy the following VMs:")
	base := false
	for _, v := range vms {
		fmt.Fprintln(e.io.Stdout, v.Name)
		base = base || v.Name == vmname.Template
	}
	if base {
		fmt.Fprintf(e.io.Stdout, "(%s is the base template: 'agent-vm setup' rebuilds it.)\n", vmname.Template)
	}
	if !e.ui.CanAsk() {
		fmt.Fprintln(e.io.Stderr, "Error: destroy-all asks before it deletes, and there is no terminal to ask on. Nothing was destroyed.")
		return 1
	}
	if !e.ui.AskYN("Continue?", false) {
		fmt.Fprintln(e.io.Stdout, "Aborted.")
		return 0
	}
	st := 0
	for _, v := range vms {
		fmt.Fprintf(e.io.Stdout, "Destroying %s...\n", v.Name)
		if !e.deleteVM(ctx, v.Name) {
			st = 1
		}
	}
	if st != 0 {
		return st
	}
	fmt.Fprintln(e.io.Stdout, "All VMs destroyed.")
	return 0
}

// agentVMs lists the VMs, after moving 0.2's: for the commands that change
// them.
func (e *app) agentVMs(ctx context.Context) ([]*vm.Instance, error) {
	b, err := e.backend(ctx)
	if err != nil {
		return nil, err
	}
	return b.List(ctx)
}

// lookVMs lists the VMs without moving 0.2's: for the commands that only look.
func (e *app) lookVMs(ctx context.Context) ([]*vm.Instance, error) {
	b, err := e.readOnlyBackend()
	if err != nil {
		return nil, err
	}
	return b.List(ctx)
}

// `list`, `status`: the agent-vm VMs as Lima's table shows them, the
// current directory's marked with > (its own, and the named ones that share
// it), and the base each was cloned from in a last column. Read-only: 0.2's
// VMs are said to wait, not moved.
func (e *app) listCmd(ctx context.Context, args []string) int {
	if len(args) > 0 {
		fmt.Fprintln(e.io.Stderr, "Usage: agent-vm list")
		return exitUsage
	}
	current, wd := "", ""
	if d, err := vmname.AbsDir(""); err == nil {
		current, wd = vmname.Name(d), d
	}
	vms, err := e.lookVMs(ctx)
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: could not query Lima: %v\n", err)
		return 1
	}
	if old, from := e.unmovedOld(); len(old) > 0 {
		fmt.Fprintf(e.io.Stderr, "%d VM(s) of agent-vm 0.2 in %s are not listed: the next command that starts a VM offers to move them.\n", len(old), from)
	}
	if left := e.layoutPending(); len(left) > 0 {
		fmt.Fprintf(e.io.Stderr, "%d VM(s) of agent-vm 0.3.0 in %s are not listed: the next command that starts a VM moves them.\n", len(left), LimaHome(e.state))
	}
	if len(vms) == 0 {
		fmt.Fprintln(e.io.Stdout, "  (no VMs)")
		return 0
	}
	lines := strings.Split(strings.TrimSuffix(table(vms), "\n"), "\n")
	w := 0
	for _, l := range lines {
		w = max(w, len(l))
	}
	fmt.Fprintf(e.io.Stdout, "  %-*s   %s\n", w, lines[0], "BASE")
	for i, l := range lines[1:] {
		mark := " "
		if vms[i].Name == current || wd != "" && e.state.Known(vms[i].Name).Bound == wd {
			mark = ">"
		}
		fmt.Fprintf(e.io.Stdout, "%s %-*s   %s\n", mark, w, l, e.state.BaseLabel(vms[i].Name))
	}
	return 0
}

// table is Lima's `limactl list` table, every column shown.
func table(vms []*vm.Instance) string {
	var b strings.Builder
	w := tabwriter.NewWriter(&b, 4, 8, 4, ' ', 0)
	fmt.Fprintln(w, "NAME\tSTATUS\tSSH\tVMTYPE\tARCH\tCPUS\tMEMORY\tDISK\tDIR")
	home := paths.Home()
	for _, v := range vms {
		dir := paths.Host(v.Dir)
		if rel, ok := paths.In(dir, home); ok {
			dir = strings.TrimSuffix("~/"+rel, "/.")
		}
		fmt.Fprintf(w, "%s\t%s\t%s:%d\t%s\t%s\t%d\t%s\t%s\t%s\n", v.Name, v.Status, v.SSHAddress, v.SSHLocalPort,
			v.VMType, v.Arch, v.CPUs, units.BytesSize(float64(v.Memory)), units.BytesSize(float64(v.Disk)), dir)
	}
	w.Flush()
	return b.String()
}
