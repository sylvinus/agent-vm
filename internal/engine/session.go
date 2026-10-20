package engine

import (
	"bytes"
	"context"
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
	"github.com/sylvinus/agent-vm/internal/host"
	"github.com/sylvinus/agent-vm/internal/mounts"
	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/policy"
	"github.com/sylvinus/agent-vm/internal/runscript"
	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/vm"
)

// session is one start of a VM: Ensure.
type session struct {
	*Engine
	ctx  context.Context
	spec Spec
	base string // the template
	name string // the VM
	dir  string // the project, as the shell spells it

	scratch  bool // a scratch VM: a name of its own, no lock
	named    bool // a named VM: bound to a folder, or to none
	noShares bool // shares nothing: asked, scratch, or bound to none

	created bool     // this run made the VM, and it is still there
	vmUp    bool     // running when the start began, and not reset
	protect bool     // every .git read-only
	names   []string // the read-only names, when protect
	notes   string   // hooks notes, printed once the names apply

	built      []vm.Mount // see shares
	builtFiles []mounts.FileMount
	builtKey   string

	lastErr string // the text of the last Error event
}

// warnf tells a warning, or an error when the text says so, which the call
// then returns (see fail).
func (s *session) warnf(format string, a ...any) {
	text := fmt.Sprintf(format, a...)
	lvl := Warning
	if strings.HasPrefix(text, "Error:") {
		lvl = Error
		s.lastErr = text
	}
	s.emit(Event{Level: lvl, VM: s.name, Text: text})
}

func (s *session) infof(format string, a ...any) {
	s.emit(Event{Level: Info, VM: s.name, Text: fmt.Sprintf(format, a...)})
}

// info tells text, if there is any, as it is: it may be several lines.
func (s *session) info(text string) {
	if text = strings.TrimSuffix(text, "\n"); text != "" {
		s.emit(Event{Level: Info, VM: s.name, Text: text})
	}
}

// fail is the error of a call that stopped after telling why (the last
// Error event).
func (s *session) fail(kind error) error {
	return &Failure{Kind: kind, Text: strings.TrimPrefix(s.lastErr, "Error: ")}
}

// ask puts q to the Asker.
func (s *session) ask(q Question) bool {
	q.VM = s.name
	return s.opts.Asker.Ask(s.ctx, q)
}

func (s *session) canAsk() bool { return s.opts.Asker.CanAsk() }

func (s *session) warnWriter() io.Writer { return s.writer(Warning, s.name) }

// get is the VM name, nil when there is none.
func (s *session) get(name string) (*vm.Instance, error) {
	return s.Engine.get(s.ctx, name)
}

func (s *session) running() bool {
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
func (s *session) shares(writable bool) ([]vm.Mount, []mounts.FileMount) {
	if s.noShares {
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
		Dir: s.dir, Writable: writable, Names: n, Cache: s.opts.SSHFSCache,
		Entries: s.Entries(s.dir, s.warnWriter()), FileMounts: s.state.FileMounts(s.name), Warn: s.warnWriter(),
	})
	s.builtKey = key
	return s.built, s.builtFiles
}

// applyShares gives the stopped VM its shares, and records the single files
// of the volumes for the bind once it runs.
func (s *session) applyShares(writable bool) error {
	b, err := s.Change(s.ctx)
	if err != nil {
		return err
	}
	ms, files := s.shares(writable)
	mt := vm.ReverseSSHFS
	if err := b.Edit(s.ctx, s.name, vm.Settings{Mounts: &ms, MountType: &mt}); err != nil {
		s.warnf("Error: could not set the shares of VM '%s':\n%v", s.name, err)
		return s.fail(ErrFailed)
	}
	var lines []string
	for _, f := range files {
		lines = append(lines, f.Line())
	}
	if err := s.state.UpdateMeta(s.name, func(m *state.Metadata) { m.FileMounts = lines }); err != nil {
		s.warnf("Error: could not record the single files of ~/.agent-vm/volumes for VM '%s':\n%v", s.name, err)
		return s.fail(ErrFailed)
	}
	return nil
}

// applyResources gives the stopped VM the memory, CPUs and SSH port asked
// for. The disk apart, with a warning only: it can grow, not shrink.
func (s *session) applyResources() error {
	b, err := s.Change(s.ctx)
	if err != nil {
		return err
	}
	set := vm.Settings{CPUs: s.spec.CPUs, MemoryGiB: s.spec.MemoryGiB}
	if s.spec.SSHPort != nil {
		p := *s.spec.SSHPort
		set.SSHLocalPort = &p
	}
	if err := b.Edit(s.ctx, s.name, set); err != nil {
		s.warnf("Error: could not set the memory, CPUs or SSH port of VM '%s':\n%v", s.name, err)
		return s.fail(ErrFailed)
	}
	if s.spec.DiskGiB > 0 {
		if err := b.Edit(s.ctx, s.name, vm.Settings{DiskGiB: s.spec.DiskGiB}); err != nil {
			s.warnf("Warning: cannot set the disk of VM '%s' to %d GiB: it can grow, not shrink ('%s setup --disk %d' for a smaller base).\n%v", s.name, s.spec.DiskGiB, s.app, s.spec.DiskGiB, err)
		}
	}
	return nil
}

// resourcesDiffer: would the resources asked change anything? Compared in
// bytes; the disk one way, since it can only grow. True when the VM cannot
// be read: never "no change" from missing information.
func (s *session) resourcesDiffer(inst *vm.Instance) bool {
	o := s.spec
	switch {
	case inst == nil:
		return true
	case o.CPUs > 0 && o.CPUs != inst.CPUs:
		return true
	case o.MemoryGiB > 0 && int64(o.MemoryGiB)<<30 != inst.Memory:
		return true
	case o.DiskGiB > 0 && int64(o.DiskGiB)<<30 > inst.Disk:
		return true
	}
	return false
}

// stopToChange stops the VM to change it, then asks what its start did not,
// a running VM having been asked nothing.
func (s *session) stopToChange() error {
	if !s.Stop(s.ctx, s.name) {
		s.warnf("Error: could not stop VM '%s': nothing was changed.", s.name)
		return s.fail(ErrFailed)
	}
	if s.vmUp {
		s.vmUp = false
		if !s.checks() {
			s.warnf("VM '%s' is stopped.", s.name)
			return s.fail(ErrAborted)
		}
	}
	return nil
}

// policyNow is the policies a VM boots with now.
func (e *Engine) policyNow() (*policy.File, error) {
	if e.opts.Policy != nil {
		return e.opts.Policy()
	}
	g := policy.DefaultGuarded()
	if e.opts.Guarded != nil {
		g = *e.opts.Guarded
	}
	return policy.New(e.app, e.opts.Network, g), nil
}

// beforeBoot fails unless what Lima would boot the stopped VM with is what
// the engine set: every share with the read-only names when protected, no
// share for a scratch VM.
func (s *session) beforeBoot() error {
	inst, err := s.get(s.name)
	if err != nil || inst == nil {
		s.warnf("Error: could not read Lima's config for VM '%s', so what it would boot with is not known.", s.name)
		return s.fail(ErrFailed)
	}
	// Each that applies, none in place of another: --readonly with .git
	// protected must hold both.
	var whys []string
	if s.noShares && len(inst.Mounts) > 0 {
		if s.scratch {
			whys = append(whys, "a share, though a scratch VM gets none")
		} else {
			whys = append(whys, "a share, though this VM is to share nothing")
		}
	}
	if err := vm.Confined(inst); err != nil {
		whys = append(whys, err.Error())
	}
	if s.protect && !s.noShares {
		whys = append(whys, unprotected(inst, s.names))
	}
	if s.spec.ReadOnly {
		whys = append(whys, notReadOnly(inst))
	}
	for _, why := range whys {
		if why != "" {
			s.warnf("Error: VM '%s' would not boot as asked: %s.", s.name, why)
			return s.fail(ErrUnconfined)
		}
	}
	// The policies in force now are what the hostagent boots with: written
	// to the VM's folder, which it reads. An unreadable file stops the start
	// here, where the user sees it, not in Lima's log.
	pf, err := s.policyNow()
	if err == nil {
		err = policy.Write(s.state.Policy(s.name), pf)
	}
	if err != nil {
		s.warnf("Error: %v", err)
		return s.fail(ErrFailed)
	}
	return nil
}

// PolicyErr is what a start would stop on in the policies, for doctor.
func (e *Engine) PolicyErr() error {
	_, err := e.policyNow()
	return err
}

// configErr says so when Lima cannot read inst's config.
func (s *session) configErr(inst *vm.Instance) bool {
	if inst == nil || inst.ConfigErr == nil {
		return false
	}
	s.warnf("Error: Lima cannot read the config of VM '%s':\n  %v\n'%s --reset <command>' re-clones it.", inst.Name, inst.ConfigErr, s.app)
	return true
}

// LimaOverridesOK says so when Lima's default.yaml or override.yaml would
// add to what the engine sets for every VM.
func (e *Engine) LimaOverridesOK() bool {
	found := vm.LimaOverrides(e.opts.LimaHome)
	for _, f := range found {
		e.warnf("Error: %s adds to every VM's config (shares, mount type...): %s makes and starts no VM while it is there. Move it out of the way.", f, e.app)
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

// Unprotected is unprotected for the callers outside the engine (doctor).
func Unprotected(inst *vm.Instance, names []string) string { return unprotected(inst, names) }

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

// AllReadOnly reports whether every share of inst is read-only (and there is
// one).
func AllReadOnly(inst *vm.Instance) bool { return allReadOnly(inst) }

// ensureRunning makes the project's VM exist and run, with its shares as
// asked: cloned from the base, changed while stopped, the security checks
// done first. Under the VM's lock: another run in the same folder waits for
// this one to be done with the VM, and cleans up nothing of it meanwhile.
func (s *session) ensureRunning() error {
	// A scratch VM has a name of its own, which no other run uses.
	if !s.scratch {
		unlock, err := s.lockVM(s.ctx, s.name)
		if err != nil {
			s.warnf("Error: could not lock VM '%s': %v", s.name, err)
			return s.fail(ErrFailed)
		}
		defer unlock()
	}
	return s.ensureRunningLocked()
}

func (s *session) ensureRunningLocked() error {
	o := &s.spec
	s.noShares = o.NoShares || s.scratch
	if s.scratch && (o.Reset || o.ReadOnly) {
		s.warnf("Error: --scratch makes a new VM that shares nothing: --reset and --readonly do not go with it.")
		return s.fail(ErrRefused)
	}
	if s.noShares && o.ReadOnly {
		s.warnf("Error: --no-shares makes a VM that shares nothing: --readonly does not go with it.")
		return s.fail(ErrRefused)
	}
	wantWritable := !o.ReadOnly
	o.CPUs = s.capHost("cpus", o.CPUs)
	o.MemoryGiB = s.capHost("memory", o.MemoryGiB)
	host.WarnDiskSpace(s.state.VMs(), o.DiskGiB, s.warnWriter())
	b, err := s.Change(s.ctx)
	if err != nil {
		s.warnf("Error: %v", err)
		return s.fail(ErrFailed)
	}
	if !s.LimaOverridesOK() {
		return s.fail(ErrLimaOverrides)
	}
	if s.named {
		if err := s.checkBinding(); err != nil {
			return err
		}
	}
	s.warnDomains()
	// Two VMs set to one port: the second would fail to start.
	if o.SSHPort != nil && *o.SSHPort > 0 {
		if all, err := b.List(s.ctx); err == nil {
			for _, v := range all {
				if v.Name != s.name && v.SSHPortConfig == *o.SSHPort {
					s.warnf("Error: SSH port %d is already set for VM '%s'.", *o.SSHPort, v.Name)
					return s.fail(ErrRefused)
				}
			}
		}
	}
	// `cd ~ && agent-vm shell` would hand the VM your dotfiles and SSH
	// keys, read-write; a share holding agent-vm's own files lets the VM
	// change what the host runs next. agent-vm's own clone may be shared
	// once the security prompts are off: working on agent-vm in its VM.
	if !s.noShares {
		refs := s.Refs()
		if _, off := s.promptsDisabledBy(); off {
			var others []mounts.Ref
			for _, r := range refs {
				if r.What != mounts.SelfRef {
					others = append(others, r)
				}
			}
			if _, bad := mounts.UnsafeProject(s.dir, others); !bad {
				if why, self := mounts.UnsafeLocation(s.dir, refs); self {
					s.warnf("Warning: sharing %s with the VM: it %s. The VM can change the %s this machine runs next.", s.dir, why, s.app)
					s.confirmUnsafe("running-self")
				}
				refs = others
			}
		}
		if why, bad := mounts.UnsafeProject(s.dir, refs); bad {
			s.warnf("Error: refusing to share %s with a VM: it %s.\nRun %s from a project directory.", s.dir, why, s.app)
			return &RefusedError{Dir: s.dir, Why: why, Text: strings.TrimPrefix(s.lastErr, "Error: ")}
		}
		if why, bad := mounts.Unmountable(s.dir); bad {
			s.warnf("Error: project path %s:\n  %s\nRename the directory, then retry.", why, s.dir)
			return &RefusedError{Dir: s.dir, Why: why, Text: strings.TrimPrefix(s.lastErr, "Error: ")}
		}
	}
	// A run interrupted while Lima made it leaves a folder without lima.yaml.
	// Under the VM's lock: no other run is making it now.
	if !s.cleanPartial(s.ctx, s.name) {
		return s.fail(ErrFailed)
	}
	base, err := s.get(s.base)
	if err != nil {
		s.warnf("Error: could not query Lima: %v", err)
		return s.fail(ErrFailed)
	}
	if s.configErr(base) {
		return s.fail(ErrFailed)
	}
	if base == nil || !s.state.BaseReady(s.base) {
		if base != nil {
			s.warnf("Error: Base VM setup did not complete. Run '%s setup' again.", s.app)
			return s.fail(ErrBaseIncomplete)
		}
		s.warnf("Error: Base VM not found. Run '%s setup' first.", s.app)
		return s.fail(ErrBaseMissing)
	}

	s.vmUp = !o.Reset && s.running()
	if !s.checks() {
		return s.fail(ErrAborted)
	}
	inst, err := s.get(s.name)
	if err != nil {
		s.warnf("Error: could not query Lima: %v", err)
		return s.fail(ErrFailed)
	}
	if !o.Reset && s.configErr(inst) {
		return s.fail(ErrFailed)
	}
	// Lima's hostagent died under it: the VM is cut off, and blocks its next
	// start.
	if inst != nil && inst.Orphaned {
		s.warnf("Warning: VM '%s' was left running without Lima's host agent, cut off: stopping it.", s.name)
		if !s.Stop(s.ctx, s.name) {
			s.warnf("Error: could not stop VM '%s'. See '%s list'.", s.name, s.app)
			return s.fail(ErrFailed)
		}
		if inst, err = s.get(s.name); err != nil {
			s.warnf("Error: could not query Lima: %v", err)
			return s.fail(ErrFailed)
		}
	}
	if o.Reset && inst != nil {
		s.infof("Resetting VM '%s'...", s.name)
		if !s.Delete(s.ctx, s.name) {
			return s.fail(ErrFailed)
		}
		inst = nil
	}

	// 0.1.0 recorded no version for its bases, and their VMs have no sshfs,
	// which the shares need; 0.2 migrated them in place.
	if inst != nil && !s.noShares && !builtWithSSHFS(s.state.Known(s.name).Base) {
		s.warnf("Error: VM '%s' comes from a base built by agent-vm 0.1.0, without the sshfs its shares need. Run '%s setup', then '%s --reset <command>' here.", s.name, s.app, s.app)
		return s.fail(ErrBaseOld)
	}

	isNew := inst == nil
	applyResize := false
	if isNew {
		s.infof("Creating VM '%s'...", s.name)
		cloned, err := s.cloneBase()
		if err != nil {
			s.warnf("Error: could not clone the base template into '%s':\n%v", s.name, err)
			if errors.Is(err, vm.ErrNameTooLong) {
				if s.named {
					s.warnf("  Give the VM a shorter name.")
				} else {
					s.warnf("  The VM's name comes from the project folder's: give the folder a shorter name.")
				}
			}
			// Nothing was made: what the clone left of it goes.
			_ = s.state.Forget(s.name)
			return &Failure{Kind: errors.Join(ErrFailed, err), Text: strings.TrimPrefix(s.lastErr, "Error: ")}
		}
		s.created = true
		if !builtWithSSHFS(cloned) && s.protect {
			// 0.1.0's bases have no sshfs for the protected shares.
			s.warnf("Error: the base VM was built by agent-vm 0.1.0, without what the shares that keep .git read-only need. Run '%s setup' to build a new one.", s.app)
			s.dropNew()
			return s.fail(ErrBaseOld)
		}
		bound := ""
		if s.named {
			bound = s.dir
			if s.noShares {
				bound = noFolder
			}
		}
		if err := s.state.UpdateMeta(s.name, func(m *state.Metadata) {
			m.Base = cloned
			m.Bound = bound
		}); err != nil {
			s.warnf("Error: could not record which base VM '%s' was cloned from: %v", s.name, err)
			s.dropNew()
			return s.fail(ErrFailed)
		}
		// Configured before its first start. A clone that could not be holds
		// nothing yet: it goes, and the next run starts over.
		if err := s.applyShares(wantWritable); err != nil {
			s.dropNew()
			return err
		}
		if err := s.applyResources(); err != nil {
			s.dropNew()
			return err
		}
		s.info(s.notes)
	} else if ((o.DiskGiB > 0 || o.MemoryGiB > 0 || o.CPUs > 0) && s.resourcesDiffer(inst)) || (o.SSHPort != nil && *o.SSHPort != inst.SSHPortConfig) {
		// Only when the request differs: a caller passing its defaults every
		// time would otherwise be asked every time. Declined, the VM keeps
		// its settings and everything below still applies.
		applyResize = true
		if s.running() {
			s.infof("VM '%s' is currently running. It must be stopped to apply new settings.", s.name)
			if s.canAsk() && s.ask(Question{Kind: QRestart, Prompt: "Stop the VM and apply changes?"}) {
				s.infof("Stopping VM...")
				if err := s.stopToChange(); err != nil {
					return err
				}
			} else {
				s.infof("Not applied: the VM keeps its current settings.")
				applyResize = false
			}
		}
	}
	if applyResize {
		s.infof("Updating VM settings...")
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
		return s.fail(ErrFailed)
	}
	want, _ := s.shares(wantWritable)
	wasProtected := len(inst.Mounts) > 0 && unprotected(inst, nil) == ""
	gitStale := !s.noShares && wasProtected != s.protect
	namesStale := s.protect && wasProtected && unprotected(inst, s.names) != ""
	stale := sharesDiffer(inst, want)
	if !o.ReadOnly && wasRunning && s.protect && (gitStale || namesStale) {
		if gitStale {
			s.warnf("Warning: VM '%s' is running with .git writable, so the agent can still write .git.", s.name)
		} else {
			s.warnf("Warning: VM '%s' runs with an older list of read-only names (it needs %s), so the agent can still write the new ones.", s.name, strings.Join(s.names, ", "))
		}
		if _, off := s.promptsDisabledBy(); !off && s.canAsk() && s.ask(Question{Kind: QRestart, Prompt: "Restart it now to apply them? Sessions using it are cut.", Default: true}) {
			if err := s.stopToChange(); err != nil {
				return err
			}
			wasRunning = false
		} else if !s.confirmUnsafe("running-writable") {
			s.warnf("Aborted. '%s stop', then run again.", s.app)
			return s.fail(ErrAborted)
		}
	}
	switch {
	case gitStale && wasRunning && !s.protect:
		s.warnf("Note: VM '%s' keeps .git read-only until it stops.", s.name)
	case !wasRunning && stale:
		switch {
		case gitStale && s.protect:
			s.infof("Making every .git read-only for VM '%s'...", s.name)
		case gitStale:
			s.warnf("Making .git writable for VM '%s' (%s)...", s.name, map[bool]string{true: "--unsafe-writable-git", false: "AGENT_VM_UNSAFE_WRITABLE_GIT=1"}[o.UnsafeWritableGit])
		case namesStale:
			s.infof("Making %s read-only for VM '%s'...", strings.Join(s.names, ", "), s.name)
		}
		if gitStale || namesStale {
			s.info(s.notes)
		}
		if !isNew {
			switch {
			case !wantWritable && !allReadOnly(inst):
				s.infof("Making every share of VM '%s' read-only...", s.name)
			case wantWritable && allReadOnly(inst):
				s.infof("VM '%s' was left read-only by --readonly; making it writable again...", s.name)
			}
		}
		if err := s.applyShares(wantWritable); err != nil {
			return err
		}
	}

	if wasRunning {
		s.notePolicyChange()
	} else if err := s.boot(); err != nil {
		return err
	}
	return s.afterBoot(isNew, wasRunning, wantWritable)
}

// noFolder is what a named VM that shares nothing is bound to: not a folder.
const noFolder = "-"

// checkBinding holds a named VM to the folder it was made for. One that
// shares nothing is used from any folder, and never gets shares; one that
// shares a folder is used from that folder only, or the project of another
// would get the VM that has seen this one. One with no record of what it
// belongs to is not touched. --reset makes the VM again, bound anew: the only
// way to change it.
func (s *session) checkBinding() error {
	inst, err := s.get(s.name)
	if err != nil {
		s.warnf("Error: could not query Lima: %v", err)
		return s.fail(ErrFailed)
	}
	if inst == nil || s.spec.Reset {
		return nil
	}
	bound := s.state.Known(s.name).Bound
	switch {
	case bound == "":
		s.warnf("Error: VM '%s' has no record of the folder it belongs to. '%s rm %s' deletes it.", s.name, s.app, s.name)
		return s.fail(ErrRefused)
	case bound == noFolder:
		s.noShares = true
		if s.spec.ReadOnly {
			s.warnf("Error: VM '%s' shares nothing: --readonly does not go with it.", s.name)
			return s.fail(ErrRefused)
		}
	case s.spec.NoShares:
		s.warnf("Error: VM '%s' shares %s, and keeps doing so. '--reset' makes it again, with no shares.", s.name, bound)
		return s.fail(ErrRefused)
	case bound != s.dir:
		s.warnf("Error: VM '%s' belongs to %s. Run it from there, or '%s rm %s'.", s.name, bound, s.app, s.name)
		return &RefusedError{Dir: s.dir, Why: "belongs to " + bound, Text: strings.TrimPrefix(s.lastErr, "Error: ")}
	}
	return nil
}

// capHost is val capped to the share of the host a VM may use.
func (e *Engine) capHost(kind string, val int) int {
	return host.CapShare(e.opts.HostShare, kind, val, e.writer(Warning, ""))
}

// cloneBase clones the base template into the VM, under the base's lock: a
// setup swapping the base in is not cloned from half way. It returns the
// base as it is described, read under the lock too, so that it is the one
// cloned: nil when it describes nothing.
func (s *session) cloneBase() (*state.Base, error) {
	b, err := s.Change(s.ctx)
	if err != nil {
		return nil, err
	}
	unlock, err := s.lockVM(s.ctx, s.base)
	if err != nil {
		return nil, err
	}
	defer unlock()
	if err := b.Clone(s.ctx, s.base, s.name); err != nil {
		return nil, err
	}
	return s.state.Known(s.base).Base, nil
}

// builtWithSSHFS reports whether the base a VM comes from has the sshfs its
// shares need: 0.1.0 recorded no version for its bases, which have none.
func builtWithSSHFS(b *state.Base) bool { return b != nil && b.BuiltBy != "" }

// BuiltWithSSHFS is builtWithSSHFS for the callers outside the engine
// (doctor).
func BuiltWithSSHFS(b *state.Base) bool { return builtWithSSHFS(b) }

// dropNew deletes the VM this run just made and could not set up.
func (s *session) dropNew() {
	if s.Delete(context.WithoutCancel(s.ctx), s.name) {
		s.created = false
	}
}

// cleanPartial removes the folder of a VM that Lima did not finish making
// (a folder, and no VM in it), unless the --scratch run it belongs to is
// alive. False when it could not.
func (e *Engine) cleanPartial(ctx context.Context, name string) bool {
	d := e.state.VM(name)
	if fi, err := os.Stat(d); err != nil || !fi.IsDir() {
		return true
	}
	b, err := e.Change(ctx)
	if err != nil {
		return true
	}
	if _, err := b.Get(ctx, name); !errors.Is(err, vm.ErrNotFound) {
		return true
	}
	if pid := e.state.Known(name).ScratchPID; pid > 0 && alive(pid) {
		return true
	}
	e.warnf("Detected partial VM state at %s (no lima.yaml): cleaning up.", d)
	if err := os.RemoveAll(d); err != nil {
		e.warnf("Error: could not remove %s:\n%v", d, err)
		return false
	}
	return true
}

// boot starts the stopped VM, its config checked first.
func (s *session) boot() error {
	if err := s.beforeBoot(); err != nil {
		return err
	}
	// Windows: QEMU's folder on PATH (winget does not put it there), for the
	// hostagent this starts.
	if !host.WindowsPrereqs(s.writer(Info, s.name), s.warnWriter()) {
		return s.fail(ErrFailed)
	}
	s.infof("Starting VM '%s'...", s.name)
	b, _ := s.Change(s.ctx)
	var log bytes.Buffer
	if err := b.Start(s.ctx, s.name, &log); err != nil {
		ha := paths.Host(filepath.Join(s.state.Lima(s.name), "ha.stderr.log"))
		s.warnf("Error: Failed to start VM '%s'.\n--- Lima's output ---\n%s%v\nFull log: %s", s.name, log.String(), err, ha)
		host.WindowsStartHint(s.warnWriter(), ha)
		return s.fail(ErrFailed)
	}
	return nil
}

// afterBoot brings the running VM's shares in line with the mode asked, by
// a write probe on the project (which pushes the env too), then installs
// the terminal's terminfo, runs the runtime scripts and binds single files.
func (s *session) afterBoot(isNew, wasRunning, wantWritable bool) error {
	o := s.spec
	guest := paths.Guest(s.dir)
	var guestEnv, guestRuntime, projectRuntime, payload string
	if s.noShares {
		if code, err := s.shellRun(nil, "", "sh", "-c", `sudo install -d -o "$(id -u)" -g "$(id -g)" "$1"`, "sh", guest); err != nil || code != 0 {
			s.warnf("Error: could not make %s in VM '%s'.", s.dir, s.name)
			return s.fail(ErrFailed)
		}
		// Only the shared file: the project's stays out. Read as the other
		// path does, a regular file only (a FIFO would block the start).
		if b, ok := readRegular(s.opts.EnvFile); ok {
			payload = strings.TrimRight(env.StripCR(b), "\n")
		}
	} else {
		pe := s.projectEnvFile()
		projectRuntime = s.projectRuntime()
		// By their path in the project, the one the VM has.
		if rel, ok := env.ProjectRel(s.dir, pe); ok && pe != "" {
			guestEnv = guest + "/" + rel
		}
		if rel, ok := env.ProjectRel(s.dir, projectRuntime); ok && projectRuntime != "" {
			guestRuntime = guest + "/" + rel
		}
		payload = strings.TrimRight(env.PayloadFor(s.opts.EnvFile, s.dir, pe), "\n")
	}
	probe := s.probe(payload, guestEnv, guestRuntime)
	if s.noShares && probe.writable != "true" {
		s.warnf("Error: %s is not writable in VM '%s'.", s.dir, s.name)
		return s.fail(ErrFailed)
	}
	inst, _ := s.get(s.name)
	want := fmt.Sprint(wantWritable)
	if !s.noShares && (probe.writable != want || !wantWritable && inst != nil && !allReadOnly(inst)) {
		switch {
		case probe.writable == "lost":
			s.warnf("Warning: the project share is not mounted in VM '%s': what was written in %s in the VM since then is on the VM's own disk, and hidden once the share is back.", s.name, s.dir)
			s.warnf("Project share is not mounted; repairing...")
		case wantWritable && wasRunning && inst != nil && allReadOnly(inst):
			s.infof("VM '%s' runs read-only (--readonly). It must be restarted to make its shares writable.", s.name)
			if !s.canAsk() || !s.ask(Question{Kind: QRestart, Prompt: "Stop the VM and make it writable? Sessions using it are cut."}) {
				s.warnf("Error: not restarted. Pass --readonly to use it as it is, or '%s stop' it first.", s.app)
				return s.fail(ErrNotApplied)
			}
		case !wantWritable && wasRunning:
			s.infof("VM '%s' was already running. It must be restarted to make its shares read-only.", s.name)
			if !s.canAsk() || !s.ask(Question{Kind: QRestart, Prompt: "Stop the VM and apply --readonly?"}) {
				// Carrying on writable after --readonly was asked for is the
				// one outcome that must not be silent.
				s.warnf("Error: --readonly was requested but not applied. Aborting.")
				return s.fail(ErrNotApplied)
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
		b, _ := s.Change(s.ctx)
		if err := b.Start(s.ctx, s.name, io.Discard); err != nil {
			s.warnf("Error: VM '%s' did not come back up after changing the project mount.", s.name)
			return s.fail(ErrFailed)
		}
		if probe = s.probe(payload, guestEnv, guestRuntime); probe.writable != want {
			switch {
			case probe.writable == "lost":
				s.warnf("Error: the project share did not mount in VM '%s':\n  %s\nLima's log: %s", s.name, s.dir, filepath.Join(s.state.Lima(s.name), "ha.stderr.log"))
			case wantWritable:
				s.warnf("Error: project directory is still not writable inside the VM:\n  %s\nThe host mount failed to attach. Try '%s --reset <command>'\nto re-clone the VM from the base template.", s.dir, s.app)
			default:
				s.warnf("Error: failed to mount the project directory read-only:\n  %s", s.dir)
			}
			return s.fail(ErrFailed)
		}
	}
	// --readonly is claimed once every share Lima has is read-only: the
	// builtin SFTP server enforces it on the host.
	if o.ReadOnly {
		inst, _ := s.get(s.name)
		if inst == nil {
			s.warnf("Error: --readonly cannot hold: could not read Lima's config for VM '%s'.", s.name)
			return s.fail(ErrFailed)
		}
		why := notReadOnly(inst)
		if why == "" && !allReadOnly(inst) {
			why = "no share"
		}
		if why != "" {
			s.warnf("Error: --readonly cannot hold: VM '%s' runs with %s.", s.name, why)
			return s.fail(ErrUnconfined)
		}
		s.infof("Read-only: the project and every other share (enforced on the host).")
	}

	s.terminfo()
	if s.opts.RuntimeScript != "" {
		if _, err := os.Stat(s.opts.RuntimeScript); err == nil {
			s.infof("Running user runtime setup...")
			s.runHostScript(s.opts.RuntimeScript)
		}
	}
	switch {
	case guestRuntime != "":
		if probe.runtimeFound {
			s.infof("Running project runtime setup...")
			s.shellRun(nil, guest, "zsh", "-lc", `[ -f "$3" ] || exit 0; i="$(awk "$1" "$3")" && awk "$2" "$3" | "$i" -s`,
				"agent-vm", runscript.ShebangAWK, runscript.StripCRAWK, guestRuntime)
		}
	case projectRuntime != "" && isFile(projectRuntime):
		s.infof("Running project runtime setup...")
		s.runHostScript(projectRuntime)
	}
	s.bindFiles(isNew)
	return nil
}

func isFile(p string) bool { fi, err := os.Stat(p); return err == nil && fi.Mode().IsRegular() }

// readRegular is the content of p when it is a regular file once links are
// followed. Another kind (a FIFO, a device) is not read: it could block.
func readRegular(p string) (string, bool) {
	if p == "" || !isFile(p) {
		return "", false
	}
	b, err := os.ReadFile(p)
	return string(b), err == nil
}

// runHostScript runs a runtime script the host reads in the VM, piped in,
// CRs dropped, under the shell it declares, from a login zsh: the VM's PATH
// and ~/.agent-vm.env apply.
func (s *session) runHostScript(path string) {
	b, ok := readRegular(path)
	if !ok {
		s.warnf("Warning: could not read %s (not a regular file, or unreadable): not run.", path)
		return
	}
	interp := runscript.Interpreter(b)
	s.shellRun(strings.NewReader(env.StripCR(b)), paths.Guest(s.dir), "zsh", "-lc", "exec "+interp+" -s")
}

// shellRun runs args in the VM, its output reported as events, and returns
// the exit status.
func (s *session) shellRun(stdin io.Reader, workdir string, args ...string) (int, error) {
	b, err := s.Change(s.ctx)
	if err != nil {
		return 0, err
	}
	if stdin == nil {
		stdin = strings.NewReader("")
	}
	return b.Shell(s.ctx, s.name, vm.ShellOpts{Workdir: workdir, Args: args, Stdin: stdin, Stdout: s.writer(Info, s.name), Stderr: s.warnWriter()})
}

// terminfo puts the host's terminfo entry in the VM, for terminals Debian
// does not know (xterm-ghostty, xterm-kitty), once per VM and $TERM.
func (s *session) terminfo() {
	t := s.opts.TERM
	if t == "" || s.state.Known(s.name).Term == t {
		return
	}
	entry, err := exec.CommandContext(s.ctx, "infocmp", "-x", t).Output()
	if err != nil {
		return
	}
	b, _ := s.Change(s.ctx)
	code, err := b.Shell(s.ctx, s.name, vm.ShellOpts{Args: []string{"sudo", "tic", "-x", "-"}, Stdin: bytes.NewReader(entry), Stdout: io.Discard, Stderr: io.Discard})
	if err != nil || code != 0 {
		s.warnf("Warning: failed to install '%s' terminfo inside VM.", t)
		return
	}
	if err := s.state.UpdateMeta(s.name, func(m *state.Metadata) { m.Term = t }); err != nil {
		s.warnf("Warning: could not record that VM '%s' has the terminfo of '%s': %v", s.name, t, err)
	}
}

// bindFiles binds the single files of the volumes in place in the VM, an
// existing VM's staged copy refreshed first, so an edit saved by rename on
// the host shows. A bind does not survive a restart, and is skipped when
// there.
func (s *session) bindFiles(isNew bool) {
	var entries []string
	for _, line := range s.state.Known(s.name).FileMounts {
		f := strings.SplitN(line, "|", 4)
		if len(f) != 4 || f[1] == "" {
			continue
		}
		switch {
		case isNew:
		case !exists(f[0]):
			s.warnf("Warning: Mount source '%s' no longer exists; VM will see the last-staged copy.", f[0])
		case !mounts.Stage(f[0], f[1], s.warnWriter()):
			s.warnf("Warning: Failed to refresh staged '%s'; VM may see stale content.", f[0])
		}
		if f[2] != "" && f[3] != "" {
			entries = append(entries, f[2]+"|"+f[3])
		}
	}
	if len(entries) == 0 {
		return
	}
	s.infof("Mounting individual files...")
	// The paths as arguments, never in the script.
	code, err := s.shellRun(nil, "", append([]string{"sudo", "bash", "-c", `
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
	if err != nil {
		s.warnf("Warning: could not bind the single files of ~/.agent-vm/volumes in VM '%s': %v", s.name, err)
	} else if code != 0 {
		s.warnf("Warning: binding the single files of ~/.agent-vm/volumes in VM '%s' failed (status %d).", s.name, code)
	}
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

// staleState says whether vm was cloned from an older base than the
// current one: 1, 0, or unknown with nothing to compare against. A VM with
// no record but a known base predates the record, which makes it stale.
func (e *Engine) staleStateOf(name, template string) string {
	base := e.state.Known(template).Base
	if base == nil || base.Built <= 0 {
		return "unknown"
	}
	if mine := e.state.Known(name).Base; mine == nil || mine.Built != base.Built {
		return "1"
	}
	return "0"
}

func (s *session) staleState(name string) string { return s.staleStateOf(name, s.base) }

// StaleState says whether the VM name was cloned from an older template than
// the current one: "1", "0", or "unknown" with nothing to compare against.
func (e *Engine) StaleState(name, template string) string { return e.staleStateOf(name, template) }
