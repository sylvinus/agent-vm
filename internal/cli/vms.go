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
// (renamed, deleted) is reached by its name.
func (e *app) target(ctx context.Context, verb string, args []string) (string, bool) {
	var name string
	switch len(args) {
	case 0:
		wd, err := vmname.AbsDir("")
		if err != nil {
			fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
			return "", false
		}
		name = vmname.Name(wd)
	case 1:
		name = args[0]
	default:
		fmt.Fprintf(e.io.Stderr, "Usage: agent-vm %s [vm-name]\n", verb)
		return "", false
	}
	b, err := e.backend()
	if err == nil {
		_, err = b.Get(ctx, name)
	}
	switch {
	case err == nil:
		return name, true
	case errors.Is(err, vm.ErrNotFound) && len(args) == 0:
		fmt.Fprintln(e.io.Stderr, "No VM found for this directory.")
		fmt.Fprintf(e.io.Stderr, "Run 'agent-vm list' to see existing VMs, then 'agent-vm %s <vm-name>'.\n", verb)
	case errors.Is(err, vm.ErrNotFound):
		fmt.Fprintf(e.io.Stderr, "Error: no such VM: %s\n", name)
		fmt.Fprintln(e.io.Stderr, "Run 'agent-vm list' to see existing VMs.")
	default:
		fmt.Fprintf(e.io.Stderr, "Error: could not query Lima: %v\n", err)
	}
	return "", false
}

func (e *app) stopCmd(ctx context.Context, args []string) int {
	name, ok := e.target(ctx, "stop", args)
	if !ok {
		return 1
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
	b, err := e.backend()
	if err != nil {
		return false
	}
	_ = b.Stop(ctx, name)
	inst, err := b.Get(ctx, name)
	return err == nil && inst.Status != vm.Running
}

func (e *app) rmCmd(ctx context.Context, args []string) int {
	name, ok := e.target(ctx, "rm", args)
	if !ok {
		return 1
	}
	fmt.Fprintf(e.io.Stdout, "Stopping and deleting VM '%s'...\n", name)
	if !e.deleteVM(ctx, name) {
		return 1
	}
	fmt.Fprintln(e.io.Stdout, "VM destroyed.")
	return 0
}

// deleteVM stops and deletes name, then forgets what agent-vm knew of it.
// Fails, saying so, when it is still there (or cannot be asked): --reset
// would otherwise go on with the old VM and its shares.
func (e *app) deleteVM(ctx context.Context, name string) bool {
	b, err := e.backend()
	if err == nil {
		_ = b.Delete(ctx, name)
		_, err = b.Get(ctx, name)
	}
	if !errors.Is(err, vm.ErrNotFound) {
		fmt.Fprintf(e.io.Stderr, "Error: could not delete VM '%s'. See 'agent-vm list', then retry.\n", name)
		return false
	}
	if err := e.state.Forget(name, vmname.Template); err != nil {
		fmt.Fprintf(e.io.Stderr, "Warning: %v\n", err)
	}
	return true
}

// `destroy-all`: every agent-vm VM, the base template included: the command
// that gives the disk space back. `agent-vm setup` rebuilds the template.
func (e *app) destroyAllCmd(ctx context.Context, _ []string) int {
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
	if !e.ui.CanAsk() || !e.ui.AskYN("Continue?", false) {
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

func (e *app) agentVMs(ctx context.Context) ([]*vm.Instance, error) {
	b, err := e.backend()
	if err != nil {
		return nil, err
	}
	return b.List(ctx)
}

// `list`, `status`: the agent-vm VMs as Lima's table shows them, the
// current directory's marked with >, and the base each was cloned from in a
// last column.
func (e *app) listCmd(ctx context.Context, _ []string) int {
	current := ""
	if wd, err := vmname.AbsDir(""); err == nil {
		current = vmname.Name(wd)
	}
	vms, err := e.agentVMs(ctx)
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: could not query Lima: %v\n", err)
		return 1
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
		if vms[i].Name == current {
			mark = ">"
		}
		fmt.Fprintf(e.io.Stdout, "%s %-*s   %s\n", mark, w, l, e.state.BaseLabel(vms[i].Name, vmname.Template))
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
		if home != "" && strings.HasPrefix(dir, home) {
			dir = "~" + strings.TrimPrefix(dir, home)
		}
		fmt.Fprintf(w, "%s\t%s\t%s:%d\t%s\t%s\t%d\t%s\t%s\t%s\n", v.Name, v.Status, v.SSHAddress, v.SSHLocalPort,
			v.VMType, v.Arch, v.CPUs, units.BytesSize(float64(v.Memory)), units.BytesSize(float64(v.Disk)), dir)
	}
	w.Flush()
	return b.String()
}
