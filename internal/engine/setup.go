package engine

import (
	"context"
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"time"

	"github.com/sylvinus/agent-vm/internal/host"
	"github.com/sylvinus/agent-vm/internal/policy"
	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/version"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/provision"
)

// Output shows what the steps of Setup print, as the program likes: a window
// of the last lines, a log. Step runs fn with the writer the step's output
// goes to, and returns fn's error.
type Output interface {
	// The steps are "create", "start" and "script:<name>" for each script.
	Step(name string, fn func(stdout, stderr io.Writer) error) error
}

// plainOutput drops what the steps print.
type plainOutput struct{}

func (plainOutput) Step(_ string, fn func(stdout, stderr io.Writer) error) error {
	return fn(io.Discard, io.Discard)
}

// SetupError is why Setup stopped.
type SetupError struct {
	// Step is "create", "start", "script" (see Script), "stop" or "swap"; or
	// "prepare" for what had to hold before the build.
	Step   string
	Script string
	Err    error
	// Told: the engine told why in an Error event already.
	Told bool
	// LimaLog is Lima's own log of the build VM, for a start that failed.
	LimaLog string
}

func (e *SetupError) Error() string {
	if e.Script != "" {
		return fmt.Sprintf("setup: %s %s: %v", e.Step, e.Script, e.Err)
	}
	return fmt.Sprintf("setup: %s: %v", e.Step, e.Err)
}
func (e *SetupError) Unwrap() error { return e.Err }

// Setup builds the base template: made as t.Name+"-building" (created,
// booted, provisioned by t's scripts, stopped), then swapped in for the
// template and marked as ready. A setup that fails before the swap leaves
// the template it found.
func (e *Engine) Setup(ctx context.Context, t provision.Template, out Output) error {
	if out == nil {
		out = plainOutput{}
	}
	if t.Name == "" {
		t.Name = DefaultBase
	}
	building := Building(t.Name)
	told := func(step string, err error) error { return &SetupError{Step: step, Err: err, Told: true} }
	b, err := e.Change(ctx)
	if err != nil {
		e.warnf("Error: %v", err)
		return told("prepare", err)
	}
	// One setup at a time: two would build in the same VM.
	unlockSetup, err := e.lockVM(ctx, t.Name+"-setup")
	if err != nil {
		e.warnf("Error: could not lock the base template's setup: %v", err)
		return told("prepare", err)
	}
	defer unlockSetup()
	if !e.LimaOverridesOK() {
		return told("prepare", ErrLimaOverrides)
	}
	pf, err := e.policyNow()
	if err != nil {
		e.warnf("Error: %v", err)
		return told("prepare", err)
	}
	(&session{Engine: e, ctx: ctx}).warnDomains()
	// A build an earlier setup left, finished or not, is not this one's.
	if !e.cleanPartial(ctx, building) {
		return told("prepare", ErrFailed)
	}
	if !e.Delete(ctx, building) {
		return told("prepare", ErrFailed)
	}
	// The build boots with the policies of now, as every VM does.
	if err := policy.Write(e.state.Policy(building), pf); err != nil {
		e.warnf("Error: %v", err)
		return told("prepare", err)
	}

	cpus := e.capHost("cpus", t.CPUs)
	memory := e.capHost("memory", t.MemoryGiB)
	host.WarnDiskSpace(e.state.VMs(), t.DiskGiB, e.writer(Warning, ""))
	stopBase := func() { _ = b.Stop(ctx, building) }

	e.infof("Creating base VM...")
	none := []vm.Mount{}
	if err := out.Step("create", func(w, _ io.Writer) error {
		return b.Create(ctx, building, "template:debian-13", vm.Settings{CPUs: cpus, MemoryGiB: memory, DiskGiB: t.DiskGiB, Mounts: &none, NoContainerd: true}, w)
	}); err != nil {
		return &SetupError{Step: "create", Err: err}
	}
	if inst, err := e.get(ctx, building); err == nil && inst != nil {
		e.infof("  Resources: CPUs: %d, Memory: %d GiB, Disk: %d GiB", inst.CPUs, inst.Memory>>30, inst.Disk>>30)
	}

	e.infof("Starting base VM (the first run downloads a Debian image)...")
	if err := out.Step("start", func(w, _ io.Writer) error { return b.Start(ctx, building, w) }); err != nil {
		return &SetupError{Step: "start", Err: err, LimaLog: filepath.Join(e.state.Lima(building), "ha.stderr.log")}
	}

	for _, s := range t.Scripts {
		if s.Message != "" {
			e.infof("%s", s.Message)
		}
		shell := s.Shell
		if len(shell) == 0 {
			shell = []string{"bash", "-l"}
		}
		if err := out.Step("script:"+s.Name, func(stdout, stderr io.Writer) error {
			code, err := b.Shell(ctx, building, vm.ShellOpts{Args: shell,
				Stdin: strings.NewReader(provision.Exports(t.Env, s.Env) + s.Content), Stdout: stdout, Stderr: stderr})
			if err == nil && code != 0 {
				err = fmt.Errorf("exit status %d", code)
			}
			return err
		}); err != nil {
			stopBase()
			return &SetupError{Step: "script", Script: s.Name, Err: err}
		}
	}

	// Ready only once stopped: Lima clones only a stopped instance.
	if !e.Stop(ctx, building) {
		e.warnf("Error: the new base VM is set up but did not stop: '%s stop %s', then '%s setup' again. The base from before is untouched.", e.app, building, e.app)
		return told("stop", ErrFailed)
	}
	if !e.swapBase(ctx, b, t.Name) {
		return told("swap", ErrFailed)
	}
	return nil
}

// swapBase puts the finished build in the base's place: the old base and its
// folder go, the build is cloned to the base's name and marked ready, last
// the build goes. Under the base's lock, so that no start clones the base
// meanwhile. Lima has no rename, so the disk is copied once more; the build
// is kept if the copy cannot be made, and said.
func (e *Engine) swapBase(ctx context.Context, b vm.Backend, template string) bool {
	building := Building(template)
	unlock, err := e.lockVM(ctx, template)
	if err != nil {
		e.warnf("Error: could not lock the base template: %v. The new base is VM '%s'; '%s setup' again builds another.", err, building, e.app)
		return false
	}
	defer unlock()
	if !e.cleanPartial(ctx, template) {
		return false
	}
	// Forgets the old base's folder with it, its metadata included: from here
	// on, nothing says a base is ready.
	if !e.Delete(ctx, template) {
		e.warnf("Error: could not replace the base VM. The new one is VM '%s'; '%s setup' again builds another.", building, e.app)
		return false
	}
	if err := b.Clone(ctx, building, template); err != nil {
		e.warnf("Error: could not copy the new base VM to '%s': %v\nThere is no base now. The new one is VM '%s'; '%s setup' again builds another.", template, err, building, e.app)
		return false
	}
	// The record last: it says the base can be cloned.
	base := &state.Base{Name: template, Built: time.Now().Unix(), BuiltBy: version.Version}
	if err := e.state.UpdateMeta(template, func(m *state.Metadata) { m.Base = base }); err != nil {
		e.warnf("Error: could not record when and by which agent-vm the base was built: %v\nThe base VM is not marked ready: '%s setup' again.", err, e.app)
		return false
	}
	if !e.Delete(ctx, building) {
		e.warnf("Warning: the base is ready, but VM '%s' stays: '%s rm %s' frees its disk.", building, e.app, building)
	}
	return true
}
