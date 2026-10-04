package cli

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strings"

	"github.com/sylvinus/agent-vm/internal/env"
	"github.com/sylvinus/agent-vm/internal/guard"
	"github.com/sylvinus/agent-vm/internal/host"
	"github.com/sylvinus/agent-vm/internal/mounts"
	"github.com/sylvinus/agent-vm/internal/netguard"
	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/runscript"
	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

var errStop = errors.New("stop")

// get is the VM name, nil when there is none.
func (s *start) get(name string) (*vm.Instance, error) {
	b, err := s.backend()
	if err != nil {
		return nil, err
	}
	inst, err := b.Get(s.ctx, name)
	if errors.Is(err, vm.ErrNotFound) {
		return nil, nil
	}
	return inst, err
}

func (s *start) running() bool {
	inst, err := s.get(s.name)
	return err == nil && inst != nil && inst.Status == vm.Running
}

// shares is what the VM gets now: the project and the volumes, writable or
// not, with the read-only names when .git is protected; nothing for a
// scratch VM. The mount type that goes with them is reverse-sshfs: with the
// read-only names, it is what enforces them; without, the builtin SFTP
// server still serves the shares alone.
//
// Built once per mode and names, so its warnings show once.
func (s *start) shares(writable bool) ([]vm.Mount, []mounts.FileMount) {
	if s.opts.Scratch {
		return []vm.Mount{}, nil
	}
	n := s.names
	if !s.protect {
		n = []string{}
	}
	key := fmt.Sprint(writable, n)
	if s.built != nil && s.builtKey == key {
		return s.built, s.builtFiles
	}
	s.built, s.builtFiles = mounts.Build(mounts.Shares{
		VM: s.name, Dir: s.dir, Writable: writable, Names: n,
		Entries: s.entries(s.dir, s.io.Stderr), StateDir: string(s.state), Warn: s.io.Stderr,
	})
	s.builtKey = key
	return s.built, s.builtFiles
}

// applyShares gives the stopped VM its shares, and records the single files
// of the volumes for the bind once it runs.
func (s *start) applyShares(writable bool) error {
	b, err := s.backend()
	if err != nil {
		return err
	}
	ms, files := s.shares(writable)
	mt := vm.ReverseSSHFS
	if err := b.Edit(s.ctx, s.name, vm.Settings{Mounts: &ms, MountType: &mt}); err != nil {
		s.warnf("Error: could not set the shares of VM '%s':\n%v", s.name, err)
		return errStop
	}
	cache := s.state.Marker(state.FileMountsOf, s.name)
	os.Remove(cache)
	if len(files) > 0 {
		var lines []string
		for _, f := range files {
			lines = append(lines, f.Line())
		}
		if err := os.WriteFile(cache, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
			return err
		}
	}
	return nil
}

// applyResources gives the stopped VM the memory, CPUs and SSH port asked
// for. The disk apart, with a warning only: it can grow, not shrink.
func (s *start) applyResources() error {
	b, err := s.backend()
	if err != nil {
		return err
	}
	set := vm.Settings{CPUs: s.opts.CPUs, MemoryGiB: s.opts.Memory}
	if s.opts.SSHPort >= 0 {
		p := s.opts.SSHPort
		set.SSHLocalPort = &p
	}
	if err := b.Edit(s.ctx, s.name, set); err != nil {
		s.warnf("Error: could not set the memory, CPUs or SSH port of VM '%s':\n%v", s.name, err)
		return errStop
	}
	if s.opts.Disk > 0 {
		if err := b.Edit(s.ctx, s.name, vm.Settings{DiskGiB: s.opts.Disk}); err != nil {
			s.warnf("Warning: cannot set the disk of VM '%s' to %d GiB: it can grow, not shrink ('agent-vm setup --disk %d' for a smaller base).\n%v", s.name, s.opts.Disk, s.opts.Disk, err)
		}
	}
	return nil
}

// resourcesDiffer: would the resources asked change anything? Compared in
// bytes; the disk one way, since it can only grow. True when the VM cannot
// be read: never "no change" from missing information.
func (s *start) resourcesDiffer(inst *vm.Instance) bool {
	o := s.opts
	switch {
	case inst == nil:
		return true
	case o.CPUs > 0 && o.CPUs != inst.CPUs:
		return true
	case o.Memory > 0 && int64(o.Memory)<<30 != inst.Memory:
		return true
	case o.Disk > 0 && int64(o.Disk)<<30 > inst.Disk:
		return true
	}
	return false
}

// stopVM stops the VM to change it, then asks what its start did not, a
// running VM having been asked nothing.
func (s *start) stopToChange() error {
	if !s.stopVM(s.ctx, s.name) {
		s.warnf("Error: could not stop VM '%s': nothing was changed.", s.name)
		return errStop
	}
	if s.vmUp {
		s.vmUp = false
		if !s.checks() {
			s.warnf("VM '%s' is stopped.", s.name)
			return errStop
		}
	}
	return nil
}

// beforeBoot fails unless what Lima would boot the stopped VM with is what
// agent-vm set: every share with the read-only names when protected, no
// share for a scratch VM.
func (s *start) beforeBoot() error {
	inst, err := s.get(s.name)
	if err != nil || inst == nil {
		s.warnf("Error: could not read Lima's config for VM '%s', so what it would boot with is not known.", s.name)
		return errStop
	}
	// Each that applies, none in place of another: --readonly with .git
	// protected must hold both.
	var whys []string
	if s.opts.Scratch && len(inst.Mounts) > 0 {
		whys = append(whys, "a share, though a scratch VM gets none")
	}
	if err := vm.Confined(inst); err != nil {
		whys = append(whys, err.Error())
	}
	if s.protect && !s.opts.Scratch {
		whys = append(whys, unprotected(inst, s.names))
	}
	if s.opts.ReadOnly {
		whys = append(whys, notReadOnly(inst))
	}
	for _, why := range whys {
		if why != "" {
			s.warnf("Error: VM '%s' would not boot as asked: %s.", s.name, why)
			return errStop
		}
	}
	if err := policiesErr(s.state); err != nil {
		s.warnf("Error: %v", err)
		return errStop
	}
	return nil
}

// policiesErr is what the hostagent would stop on in the network and
// guarded files: said here, where the user sees it, not in Lima's log.
func policiesErr(st state.Dir) error {
	if _, err := netguard.Load(string(st)); err != nil {
		return err
	}
	_, err := guard.Load(string(st), "")
	return err
}

// configErr says so when Lima cannot read inst's config.
func (s *start) configErr(inst *vm.Instance) bool {
	if inst == nil || inst.ConfigErr == nil {
		return false
	}
	s.warnf("Error: Lima cannot read the config of VM '%s':\n  %v\n'agent-vm --reset <command>' re-clones it.", inst.Name, inst.ConfigErr)
	return true
}

// limaOverridesOK says so when Lima's default.yaml or override.yaml would
// add to what agent-vm sets for every VM.
func (s *start) limaOverridesOK() bool {
	found := vm.LimaOverrides(LimaHome(s.state))
	for _, f := range found {
		s.warnf("Error: %s adds to every VM's config (shares, mount type...): agent-vm makes and starts no VM while it is there. Move it out of the way.", f)
	}
	return len(found) == 0
}

// The verdicts on a VM's shares, "" when they hold. Each starts from
// vm.Confined: only the builtin SFTP server over reverse-sshfs enforces
// anything on the host.

// unprotected says why inst's shares leave .git writable: not confined, or
// a share without one of names (mounts.BaseNames when nil; more is no less
// safe).
func unprotected(inst *vm.Instance, names []string) string {
	if err := vm.Confined(inst); err != nil {
		return err.Error()
	}
	if names == nil {
		names = mounts.BaseNames
	}
	for _, m := range inst.Mounts {
		if slices.ContainsFunc(names, func(n string) bool { return !slices.Contains(m.SSHFS.ReadonlyNames, n) }) {
			return "the share of " + m.Location + " lacks the read-only names"
		}
	}
	return ""
}

// notReadOnly says why inst's shares are not all read-only on the host.
func notReadOnly(inst *vm.Instance) string {
	if err := vm.Confined(inst); err != nil {
		return err.Error()
	}
	for _, m := range inst.Mounts {
		if m.Writable {
			return "a writable share of " + m.Location
		}
	}
	return ""
}

// sharesDiffer reports whether inst's shares differ from want, Lima's
// defaults (sshfs's cache on, no SFTP driver named) filled in on both.
func sharesDiffer(inst *vm.Instance, want []vm.Mount) bool {
	if len(inst.Mounts) == 0 && len(want) == 0 {
		return false
	}
	norm := func(ms []vm.Mount) []vm.Mount {
		out := make([]vm.Mount, len(ms))
		for i, m := range ms {
			o := vm.SSHFS{}
			if m.SSHFS != nil {
				o = *m.SSHFS
			}
			if o.Cache == nil {
				on := true
				o.Cache = &on
			}
			if len(o.ReadonlyNames) == 0 {
				o.ReadonlyNames = nil
			}
			m.SSHFS = &o
			out[i] = m
		}
		return out
	}
	return !reflect.DeepEqual(norm(inst.Mounts), norm(want)) || inst.MountType != vm.ReverseSSHFS
}

// allReadOnly reports whether every share of inst is read-only.
func allReadOnly(inst *vm.Instance) bool {
	for _, m := range inst.Mounts {
		if m.Writable {
			return false
		}
	}
	return len(inst.Mounts) > 0
}

// ensureRunning makes the project's VM exist and run, with its shares as
// asked: cloned from the base, changed while stopped, the security checks
// done first.
func (s *start) ensureRunning() error {
	o := &s.opts
	if o.Scratch && (o.Reset || o.ReadOnly) {
		s.warnf("Error: --scratch makes a new VM that shares nothing: --reset and --readonly do not go with it.")
		return errStop
	}
	wantWritable := !o.ReadOnly
	o.CPUs = host.Cap("cpus", o.CPUs, s.io.Stderr)
	o.Memory = host.Cap("memory", o.Memory, s.io.Stderr)
	host.WarnDiskSpace(LimaHome(s.state), o.Disk, s.io.Stderr)
	b, err := s.backend()
	if err != nil {
		s.warnf("Error: %v", err)
		return errStop
	}
	if !s.limaOverridesOK() {
		return errStop
	}
	// Two VMs set to one port: the second would fail to start.
	if o.SSHPort > 0 {
		if all, err := b.List(s.ctx); err == nil {
			for _, v := range all {
				if v.Name != s.name && v.SSHPortConfig == o.SSHPort {
					s.warnf("Error: SSH port %d is already set for VM '%s'.", o.SSHPort, v.Name)
					return errStop
				}
			}
		}
	}
	// `cd ~ && agent-vm shell` would hand the VM your dotfiles and SSH
	// keys, read-write; a share holding agent-vm's own files lets the VM
	// change what the host runs next.
	if !o.Scratch {
		if why, bad := mounts.UnsafeProject(s.dir, s.refs()); bad {
			s.warnf("Error: refusing to share %s with a VM: it %s.\nRun agent-vm from a project directory.", s.dir, why)
			return errStop
		}
		if why, bad := mounts.Unmountable(s.dir); bad {
			s.warnf("Error: project path %s:\n  %s\nRename the directory, then retry.", why, s.dir)
			return errStop
		}
	}
	// A run interrupted while Lima made it leaves a folder without lima.yaml.
	if d := filepath.Join(LimaHome(s.state), s.name); isDirNoYAML(d) {
		s.warnf("Detected partial VM state at %s (no lima.yaml): cleaning up.", d)
		os.RemoveAll(d)
	}
	base, err := s.get(vmname.Template)
	if err != nil {
		s.warnf("Error: could not query Lima: %v", err)
		return errStop
	}
	if s.configErr(base) {
		return errStop
	}
	if _, merr := os.Stat(s.state.Path(state.BaseVersion)); base == nil || merr != nil {
		if base != nil {
			s.warnf("Error: Base VM setup did not complete. Run 'agent-vm setup' again.")
		} else {
			s.warnf("Error: Base VM not found. Run 'agent-vm setup' first.")
		}
		return errStop
	}

	s.vmUp = !o.Reset && s.running()
	if !s.checks() {
		return errStop
	}
	inst, err := s.get(s.name)
	if err != nil {
		s.warnf("Error: could not query Lima: %v", err)
		return errStop
	}
	if !o.Reset && s.configErr(inst) {
		return errStop
	}
	if o.Reset && inst != nil {
		fmt.Fprintf(s.io.Stdout, "Resetting VM '%s'...\n", s.name)
		if !s.deleteVM(s.ctx, s.name) {
			return errStop
		}
		inst = nil
	}

	// 0.1.0 recorded no version for its bases, and their VMs have no sshfs,
	// which the shares need; 0.2 migrated them in place.
	if inst != nil && !o.Scratch && !exists(s.state.Marker(state.BuiltByOf, s.name)) && !exists(s.state.Marker(state.SSHFSOf, s.name)) {
		s.warnf("Error: VM '%s' comes from a base built by agent-vm 0.1.0, without the sshfs its shares need. Run 'agent-vm setup', then 'agent-vm --reset <command>' here.", s.name)
		return errStop
	}

	isNew := inst == nil
	applyResize := false
	if isNew {
		fmt.Fprintf(s.io.Stdout, "Creating VM '%s'...\n", s.name)
		if err := b.Clone(s.ctx, vmname.Template, s.name); err != nil {
			s.warnf("Error: could not clone the base template into '%s':\n%v", s.name, err)
			if errors.Is(err, vm.ErrNameTooLong) {
				s.warnf("  The VM's name comes from the project folder's: give the folder a shorter name.")
			}
			return errStop
		}
		for _, k := range []string{state.BuiltByOf, state.SSHFSOf} {
			os.Remove(s.state.Marker(k, s.name))
		}
		builtBy, err := os.ReadFile(s.state.Path(state.BaseBuiltBy))
		if err == nil {
			os.WriteFile(s.state.Marker(state.BuiltByOf, s.name), builtBy, 0o644)
		} else if s.protect {
			// 0.1.0's bases have no sshfs for the protected shares.
			s.warnf("Error: the base VM was built by agent-vm 0.1.0, without what the shares that keep .git read-only need. Run 'agent-vm setup' to build a new one.")
			s.deleteVM(s.ctx, s.name)
			return errStop
		}
		// Configured before its first start. A clone that could not be holds
		// nothing yet: it goes, and the next run starts over.
		if s.applyShares(wantWritable) != nil || s.applyResources() != nil {
			s.deleteVM(s.ctx, s.name)
			return errStop
		}
		fmt.Fprint(s.io.Stdout, s.notes)
		if v, err := os.ReadFile(s.state.Path(state.BaseVersion)); err == nil {
			os.WriteFile(s.state.Marker(state.VersionOf, s.name), v, 0o644)
		}
	} else if ((o.Disk > 0 || o.Memory > 0 || o.CPUs > 0) && s.resourcesDiffer(inst)) || (o.SSHPort >= 0 && o.SSHPort != inst.SSHPortConfig) {
		// Only when the request differs: a caller passing its defaults every
		// time would otherwise be asked every time. Declined, the VM keeps
		// its settings and everything below still applies.
		applyResize = true
		if s.running() {
			fmt.Fprintf(s.io.Stdout, "VM '%s' is currently running. It must be stopped to apply new settings.\n", s.name)
			if s.ui.CanAsk() && s.ui.AskYN("Stop the VM and apply changes?", false) {
				fmt.Fprintln(s.io.Stdout, "Stopping VM...")
				if err := s.stopToChange(); err != nil {
					return err
				}
			} else {
				fmt.Fprintln(s.io.Stdout, "Not applied: the VM keeps its current settings.")
				applyResize = false
			}
		}
	}
	if applyResize {
		fmt.Fprintln(s.io.Stdout, "Updating VM settings...")
		if err := s.applyResources(); err != nil {
			return err
		}
	}
	if s.staleState(s.name) == "1" {
		s.warnf("Warning: Base VM has been updated since this VM was cloned. Use --reset to re-clone from the new base.")
	}

	// The shares Lima has, against those asked: a stopped VM is changed
	// before it boots, so nothing starting with it gets a writable window; a
	// running one keeps its shares until stopped, or is offered a restart.
	wasRunning := s.running()
	if inst, err = s.get(s.name); err != nil || inst == nil {
		s.warnf("Error: could not query Lima: %v", err)
		return errStop
	}
	want, _ := s.shares(wantWritable)
	wasProtected := len(inst.Mounts) > 0 && unprotected(inst, nil) == ""
	gitStale := !o.Scratch && wasProtected != s.protect
	namesStale := s.protect && wasProtected && unprotected(inst, s.names) != ""
	stale := sharesDiffer(inst, want)
	if !o.ReadOnly && wasRunning && s.protect && (gitStale || namesStale) {
		if gitStale {
			s.warnf("Warning: VM '%s' is running with .git writable, so the agent can still write .git.", s.name)
		} else {
			s.warnf("Warning: VM '%s' runs with an older list of read-only names (it needs %s), so the agent can still write the new ones.", s.name, strings.Join(s.names, ", "))
		}
		if _, off := s.promptsDisabledBy(); !off && s.ui.CanAsk() && s.ui.AskYN("Restart it now to apply them? Sessions using it are cut.", true) {
			if err := s.stopToChange(); err != nil {
				return err
			}
			wasRunning = false
		} else if !s.confirmUnsafe() {
			s.warnf("Aborted. 'agent-vm stop', then run again.")
			return errStop
		}
	}
	switch {
	case gitStale && wasRunning && !s.protect:
		s.warnf("Note: VM '%s' keeps .git read-only until it stops.", s.name)
	case !wasRunning && stale:
		switch {
		case gitStale && s.protect:
			fmt.Fprintf(s.io.Stdout, "Making every .git read-only for VM '%s'...\n", s.name)
		case gitStale:
			s.warnf("Making .git writable for VM '%s' (%s)...", s.name, map[bool]string{true: "--unsafe-writable-git", false: "AGENT_VM_UNSAFE_WRITABLE_GIT=1"}[o.UnsafeWritableGit])
		case namesStale:
			fmt.Fprintf(s.io.Stdout, "Making %s read-only for VM '%s'...\n", strings.Join(s.names, ", "), s.name)
		}
		if gitStale || namesStale {
			fmt.Fprint(s.io.Stdout, s.notes)
		}
		if !isNew {
			switch {
			case !wantWritable && !allReadOnly(inst):
				fmt.Fprintf(s.io.Stdout, "Making every share of VM '%s' read-only...\n", s.name)
			case wantWritable && allReadOnly(inst):
				fmt.Fprintf(s.io.Stdout, "VM '%s' was left read-only by --readonly; making it writable again...\n", s.name)
			}
		}
		if err := s.applyShares(wantWritable); err != nil {
			return err
		}
	}

	if !wasRunning {
		if err := s.boot(); err != nil {
			return err
		}
	}
	return s.afterBoot(isNew, wasRunning, wantWritable)
}

func isDirNoYAML(d string) bool {
	if fi, err := os.Stat(d); err != nil || !fi.IsDir() {
		return false
	}
	_, err := os.Stat(filepath.Join(d, "lima.yaml"))
	return err != nil
}

// boot starts the stopped VM, its config checked first.
func (s *start) boot() error {
	if err := s.beforeBoot(); err != nil {
		return err
	}
	// Windows: QEMU's folder on PATH (winget does not put it there), for the
	// hostagent this starts.
	if !host.WindowsPrereqs(s.io.Stdout, s.io.Stderr) {
		return errStop
	}
	fmt.Fprintf(s.io.Stdout, "Starting VM '%s'...\n", s.name)
	b, _ := s.backend()
	var log bytes.Buffer
	if err := b.Start(s.ctx, s.name, &log); err != nil {
		ha := paths.Host(filepath.Join(LimaHome(s.state), s.name, "ha.stderr.log"))
		s.warnf("Error: Failed to start VM '%s'.\n--- Lima's output ---\n%s%v\nFull log: %s", s.name, log.String(), err, ha)
		host.WindowsStartHint(s.io.Stderr, ha)
		return errStop
	}
	return nil
}

// afterBoot brings the running VM's shares in line with the mode asked, by
// a write probe on the project (which pushes the env too), then installs
// the terminal's terminfo, runs the runtime scripts and binds single files.
func (s *start) afterBoot(isNew, wasRunning, wantWritable bool) error {
	o := s.opts
	guest := paths.Guest(s.dir)
	var guestEnv, guestRuntime, projectRuntime, payload string
	if o.Scratch {
		if code, err := s.shellRun(nil, "", "sh", "-c", `sudo install -d -o "$(id -u)" -g "$(id -g)" "$1"`, "sh", guest); err != nil || code != 0 {
			s.warnf("Error: could not make %s in VM '%s'.", s.dir, s.name)
			return errStop
		}
		if b, err := os.ReadFile(s.state.Path("env")); err == nil {
			payload = strings.TrimRight(env.StripCR(string(b)), "\n")
		}
	} else {
		pe := env.ProjectEnvFile(s.dir)
		projectRuntime = runscript.ProjectPath(s.dir)
		// By their path in the project, the one the VM has.
		if rel, ok := env.ProjectRel(s.dir, pe); ok {
			guestEnv = guest + "/" + rel
		}
		if rel, ok := env.ProjectRel(s.dir, projectRuntime); ok {
			guestRuntime = guest + "/" + rel
		}
		payload = strings.TrimRight(env.Payload(s.state.Path("env"), s.dir), "\n")
	}
	probe := s.probe(payload, guestEnv, guestRuntime)
	if o.Scratch && probe.writable != "true" {
		s.warnf("Error: %s is not writable in VM '%s'.", s.dir, s.name)
		return errStop
	}
	inst, _ := s.get(s.name)
	want := fmt.Sprint(wantWritable)
	if !o.Scratch && (probe.writable != want || !wantWritable && inst != nil && !allReadOnly(inst)) {
		switch {
		case probe.writable == "lost":
			s.warnf("Warning: the project share is not mounted in VM '%s': what was written in %s in the VM since then is on the VM's own disk, and hidden once the share is back.", s.name, s.dir)
			s.warnf("Project share is not mounted; repairing...")
		case wantWritable && wasRunning && inst != nil && allReadOnly(inst):
			fmt.Fprintf(s.io.Stdout, "VM '%s' runs read-only (--readonly). It must be restarted to make its shares writable.\n", s.name)
			if !s.ui.CanAsk() || !s.ui.AskYN("Stop the VM and make it writable? Sessions using it are cut.", false) {
				s.warnf("Error: not restarted. Pass --readonly to use it as it is, or 'agent-vm stop' it first.")
				return errStop
			}
		case !wantWritable && wasRunning:
			fmt.Fprintf(s.io.Stdout, "VM '%s' was already running. It must be restarted to make its shares read-only.\n", s.name)
			if !s.ui.CanAsk() || !s.ui.AskYN("Stop the VM and apply --readonly?", false) {
				// Carrying on writable after --readonly was asked for is the
				// one outcome that must not be silent.
				s.warnf("Error: --readonly was requested but not applied. Aborting.")
				return errStop
			}
		case wantWritable:
			s.warnf("Project mount is not writable; repairing...")
		}
		// Stopped for sure first: applying read-only shares while it still
		// runs writable would claim what is not true.
		if err := s.stopToChange(); err != nil {
			return err
		}
		if err := s.applyShares(wantWritable); err != nil {
			return err
		}
		if err := s.beforeBoot(); err != nil {
			return err
		}
		b, _ := s.backend()
		if err := b.Start(s.ctx, s.name, io.Discard); err != nil {
			s.warnf("Error: VM '%s' did not come back up after changing the project mount.", s.name)
			return errStop
		}
		if probe = s.probe(payload, guestEnv, guestRuntime); probe.writable != want {
			switch {
			case probe.writable == "lost":
				s.warnf("Error: the project share did not mount in VM '%s':\n  %s\nLima's log: %s", s.name, s.dir, filepath.Join(LimaHome(s.state), s.name, "ha.stderr.log"))
			case wantWritable:
				s.warnf("Error: project directory is still not writable inside the VM:\n  %s\nThe host mount failed to attach. Try 'agent-vm --reset <command>'\nto re-clone the VM from the base template.", s.dir)
			default:
				s.warnf("Error: failed to mount the project directory read-only:\n  %s", s.dir)
			}
			return errStop
		}
	}
	// --readonly is claimed once every share Lima has is read-only: the
	// builtin SFTP server enforces it on the host.
	if o.ReadOnly {
		inst, _ := s.get(s.name)
		if inst == nil {
			s.warnf("Error: --readonly cannot hold: could not read Lima's config for VM '%s'.", s.name)
			return errStop
		}
		why := notReadOnly(inst)
		if why == "" && !allReadOnly(inst) {
			why = "no share"
		}
		if why != "" {
			s.warnf("Error: --readonly cannot hold: VM '%s' runs with %s.", s.name, why)
			return errStop
		}
		fmt.Fprintln(s.io.Stdout, "Read-only: the project and every other share (enforced on the host).")
	}

	s.terminfo()
	if _, err := os.Stat(s.state.Path("runtime.sh")); err == nil {
		fmt.Fprintln(s.io.Stdout, "Running user runtime setup...")
		s.runHostScript(s.state.Path("runtime.sh"))
	}
	switch {
	case guestRuntime != "":
		if probe.runtimeFound {
			fmt.Fprintln(s.io.Stdout, "Running project runtime setup...")
			s.shellRun(nil, guest, "zsh", "-lc", `[ -f "$3" ] || exit 0; i="$(awk "$1" "$3")" && awk "$2" "$3" | "$i" -s`,
				"agent-vm", runscript.ShebangAWK, runscript.StripCRAWK, guestRuntime)
		}
	case projectRuntime != "" && isFile(projectRuntime):
		fmt.Fprintln(s.io.Stdout, "Running project runtime setup...")
		s.runHostScript(projectRuntime)
	}
	s.bindFiles(isNew)
	return nil
}

func isFile(p string) bool { fi, err := os.Stat(p); return err == nil && fi.Mode().IsRegular() }

// runHostScript runs a runtime script the host reads in the VM, piped in,
// CRs dropped, under the shell it declares, from a login zsh: the VM's PATH
// and ~/.agent-vm.env apply.
func (s *start) runHostScript(path string) {
	b, err := os.ReadFile(path)
	if err != nil {
		return
	}
	interp := runscript.Interpreter(string(b))
	s.shellRun(strings.NewReader(env.StripCR(string(b))), paths.Guest(s.dir), "zsh", "-lc", "exec "+interp+" -s")
}

// shellRun runs args in the VM, its output on the command's, and returns
// the exit status.
func (s *start) shellRun(stdin io.Reader, workdir string, args ...string) (int, error) {
	b, err := s.backend()
	if err != nil {
		return 0, err
	}
	if stdin == nil {
		stdin = strings.NewReader("")
	}
	return b.Shell(s.ctx, s.name, vm.ShellOpts{Workdir: workdir, Args: args, Stdin: stdin, Stdout: s.io.Stdout, Stderr: s.io.Stderr})
}

// terminfo puts the host's terminfo entry in the VM, for terminals Debian
// does not know (xterm-ghostty, xterm-kitty), once per VM and $TERM.
func (s *start) terminfo() {
	t := os.Getenv("TERM")
	marker := s.state.Marker(state.TermOf, s.name)
	if t == "" || s.state.Read(marker) == t {
		return
	}
	entry, err := exec.CommandContext(s.ctx, "infocmp", "-x", t).Output()
	if err != nil {
		return
	}
	b, _ := s.backend()
	code, err := b.Shell(s.ctx, s.name, vm.ShellOpts{Args: []string{"sudo", "tic", "-x", "-"}, Stdin: bytes.NewReader(entry), Stdout: io.Discard, Stderr: io.Discard})
	if err != nil || code != 0 {
		s.warnf("Warning: failed to install '%s' terminfo inside VM.", t)
		return
	}
	os.WriteFile(marker, []byte(t+"\n"), 0o644)
}

// bindFiles binds the single files of ~/.agent-vm/volumes in place in the
// VM, an existing VM's staged copy refreshed first, so an edit saved by
// rename on the host shows. A bind does not survive a restart, and is
// skipped when there.
func (s *start) bindFiles(isNew bool) {
	b, err := os.ReadFile(s.state.Marker(state.FileMountsOf, s.name))
	if err != nil {
		return
	}
	var entries []string
	for _, line := range strings.Split(strings.TrimSuffix(string(b), "\n"), "\n") {
		f := strings.SplitN(line, "|", 4)
		if len(f) != 4 || f[1] == "" {
			continue
		}
		switch {
		case isNew:
		case !exists(f[0]):
			s.warnf("Warning: Mount source '%s' no longer exists; VM will see the last-staged copy.", f[0])
		case !mounts.Stage(f[0], f[1], s.io.Stderr):
			s.warnf("Warning: Failed to refresh staged '%s'; VM may see stale content.", f[0])
		}
		if f[2] != "" && f[3] != "" {
			entries = append(entries, f[2]+"|"+f[3])
		}
	}
	if len(entries) == 0 {
		return
	}
	fmt.Fprintln(s.io.Stdout, "Mounting individual files...")
	// The paths as arguments, never in the script.
	s.shellRun(nil, "", append([]string{"sudo", "bash", "-c", `
        set -e
        for entry in "$@"; do
          bind_src="${entry%%|*}"
          bind_dst="${entry#*|}"
          if ! findmnt -no TARGET "$bind_dst" >/dev/null 2>&1; then
            mkdir -p "$(dirname "$bind_dst")" && touch "$bind_dst"
            mount --bind "$bind_src" "$bind_dst"
            mount -o remount,ro,bind "$bind_dst"
          fi
        done
      `, "--"}, entries...)...)
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }
