// Package engine runs agent-vm's VMs: the sequence that makes a VM for a
// project exist and run, with its shares and the security checks, and what
// runs in it. It has no terminal: what it tells goes to Options.OnEvent, what
// it asks to Options.Asker, and it reads no AGENT_VM_* variable. The command
// line (internal/cli) is one program that drives it; the public package
// agentvm re-exports it for others.
package engine

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/sylvinus/agent-vm/internal/gitguard"
	"github.com/sylvinus/agent-vm/internal/mounts"
	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/policy"
	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

// Options configure an Engine. Every feature has agent-vm's default when
// its field is the zero value. What lowers a protection is named Unsafe....
type Options struct {
	// StateDir is the folder the engine keeps everything in: the VMs
	// (vms/<name>), Lima's own files (lima/) and the user's files (env,
	// volumes...). Required, and one per program: two programs must not
	// share one, nor Lima's home.
	StateDir string
	// LimaHome is Lima's home, for what every VM shares (its SSH key, its
	// networks); StateDir/lima when empty. Never the home of the user's own
	// Lima.
	LimaHome string
	// AppName names the program in what the user is shown (dialogs and
	// messages); "agent-vm" when empty.
	AppName string
	// Asker answers the questions of the engine; none: every answer is no.
	Asker Asker
	// OnEvent gets progress, warnings and errors, as they happen, from the
	// goroutine that runs the call. Nil drops them.
	OnEvent func(Event)
	// Assets is Lima's guest agent (gzipped, for the host's architecture,
	// lima-guestagent.Linux-<arch>.gz) and templates (templates/) at its
	// root. Nil: the ones embedded in this binary by agent-vm's own build.
	Assets fs.FS
	// Backend replaces Lima, for tests.
	Backend vm.Backend

	// Policy gives the network and guarded-files policies a VM boots with,
	// called at each boot. Nil: Network and Guarded.
	Policy func() (*policy.File, error)
	// Network is what the VMs may reach; nil: the internet only.
	Network *policy.Network
	// Guarded are the files the host runs that the VM may not write unasked;
	// nil: agent-vm's list.
	Guarded *policy.Guarded

	// VolumesFile is a file in the format of agent-vm's volumes: extra
	// folders and files to share. EnvFile holds KEY=value lines pushed into
	// every VM on each start. RuntimeScript is run on the host after each
	// start. ProjectEnvFile and ProjectRuntime give the project's own, by
	// its folder ("" for none). All optional.
	VolumesFile    string
	EnvFile        string
	RuntimeScript  string
	ProjectEnvFile func(dir string) string
	ProjectRuntime func(dir string) string

	// UnsafeWritableGit leaves .git writable for every VM, as Spec's does for
	// one start. SSHFSCache turns sshfs's attribute cache on: a change on the
	// host can show up to 20 seconds late.
	UnsafeWritableGit bool
	SSHFSCache        bool
	// HostShare is the part of the host a VM may use: 2 (half) by default, 1
	// for all of it. It caps the CPUs and the memory asked for.
	HostShare int
	// Quiet leaves out the notices that are not about a risk to the host.
	Quiet bool
	// NeverShare are more folders no share may reach, beside the user's home,
	// the state folder and Lima's home: the user's own Lima home, say.
	NeverShare []string
	// TERM is the terminal whose terminfo is installed in the VMs ("" for
	// none).
	TERM string
	// BeforeChange is called once, before the first call that changes VMs
	// uses the backend: for a program with VMs of an older version to move.
	BeforeChange func(ctx context.Context)
}

// Engine runs the VMs of one state folder.
type Engine struct {
	opts  Options
	state state.Dir
	app   string

	mu        sync.Mutex // the backend
	back      vm.Backend
	backErr   error
	backMade  bool
	changeOne sync.Once
}

// Open makes an Engine. It touches nothing yet: Lima is started on first use.
func Open(opts Options) (*Engine, error) {
	if opts.StateDir == "" {
		return nil, errors.New("agent-vm: Options.StateDir is required")
	}
	dir := opts.StateDir
	if rest, ok := strings.CutPrefix(dir, "~/"); ok {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		dir = filepath.Join(home, rest)
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return nil, err
	}
	e := &Engine{opts: opts, state: state.Dir(paths.Host(abs)), app: opts.AppName}
	if e.app == "" {
		e.app = "agent-vm"
	}
	if e.opts.Asker == nil {
		e.opts.Asker = NoAsker{}
	}
	if e.opts.LimaHome == "" {
		e.opts.LimaHome = e.state.LimaHome()
	} else {
		e.opts.LimaHome = paths.Host(absOr(e.opts.LimaHome))
	}
	// Names that fit this machine's socket paths (a long home, a long user
	// name): cut in their folder part, not refused.
	vmname.MaxLen = vm.MaxName(e.state.VMs())
	return e, nil
}

// absOr is p made absolute, as it is when that cannot be done: a relative
// folder would defeat the checks that compare locations.
func absOr(p string) string {
	if abs, err := filepath.Abs(p); err == nil {
		return abs
	}
	return p
}

// State is the state folder.
func (e *Engine) State() state.Dir { return e.state }

// LimaHome is Lima's home.
func (e *Engine) LimaHome() string { return e.opts.LimaHome }

// AppName is what the program is called to the user.
func (e *Engine) AppName() string { return e.app }

// Options are the options the engine was opened with.
func (e *Engine) Options() Options { return e.opts }

// emit gives ev to the program.
func (e *Engine) emit(ev Event) {
	if e.opts.OnEvent != nil {
		e.opts.OnEvent(ev)
	}
}

func (e *Engine) infof(format string, a ...any) {
	e.emit(Event{Level: Info, Text: fmt.Sprintf(format, a...)})
}

func (e *Engine) warnf(format string, a ...any) {
	e.emit(Event{Level: Warning, Text: fmt.Sprintf(format, a...)})
}

// UserLimaHome is the Lima home of the user's own Lima: $LIMA_HOME, or ~/.lima.
func UserLimaHome() string {
	if h := vm.UserLimaHome(); h != "" {
		return paths.Host(absOr(h))
	}
	return paths.Host(filepath.Join(paths.Home(), ".lima"))
}

// SameDir reports whether a and b are one folder, links resolved where they
// exist.
func SameDir(a, b string) bool {
	if fa, err := os.Stat(a); err == nil {
		if fb, err := os.Stat(b); err == nil {
			return os.SameFile(fa, fb)
		}
	}
	return filepath.Clean(a) == filepath.Clean(b)
}

// Backend is the backend of the calls that only look, made on first use:
// most programs never need Lima. A call that changes VMs uses Change.
func (e *Engine) Backend() (vm.Backend, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.backMade {
		e.backMade = true
		e.back, e.backErr = e.newBackend()
	}
	return e.back, e.backErr
}

func (e *Engine) newBackend() (vm.Backend, error) {
	if e.opts.Backend != nil {
		return e.opts.Backend, nil
	}
	// Every VM there is the engine's: list, rm and destroy-all take them
	// all. Never a Lima home the user's own VMs live in.
	if SameDir(e.opts.LimaHome, UserLimaHome()) {
		return nil, fmt.Errorf("%s's Lima home %s is also your own Lima's home: give it a folder of its own", e.app, e.opts.LimaHome)
	}
	l, err := vm.NewLima(e.opts.LimaHome, e.state.VMs(), string(e.state))
	if err != nil {
		return nil, err
	}
	return l.WithAssets(e.opts.Assets), nil
}

// Change is the backend for a call that changes VMs. The first use also moves
// the VMs of an older version (BeforeChange, then the move of 0.3.0's to
// their own folders), which stops running ones.
func (e *Engine) Change(ctx context.Context) (vm.Backend, error) {
	e.changeOne.Do(func() {
		if e.opts.BeforeChange != nil {
			e.opts.BeforeChange(ctx)
		}
		e.migrateLayout(ctx)
	})
	return e.Backend()
}

// get is the VM name, nil when there is none.
func (e *Engine) get(ctx context.Context, name string) (*vm.Instance, error) {
	b, err := e.Backend()
	if err != nil {
		return nil, err
	}
	inst, err := b.Get(ctx, name)
	if errors.Is(err, vm.ErrNotFound) {
		return nil, nil
	}
	return inst, err
}

// Get is the VM name, or an error that is ErrNotFound.
func (e *Engine) Get(ctx context.Context, name string) (*vm.Instance, error) {
	b, err := e.Backend()
	if err != nil {
		return nil, err
	}
	return b.Get(ctx, name)
}

// List is every VM, in name order.
func (e *Engine) List(ctx context.Context) ([]*vm.Instance, error) {
	b, err := e.Backend()
	if err != nil {
		return nil, err
	}
	return b.List(ctx)
}

// ListForChange is List for a call that goes on to change VMs.
func (e *Engine) ListForChange(ctx context.Context) ([]*vm.Instance, error) {
	b, err := e.Change(ctx)
	if err != nil {
		return nil, err
	}
	return b.List(ctx)
}

// Stop stops the VM name, and reports whether it is known to be stopped.
func (e *Engine) Stop(ctx context.Context, name string) bool {
	b, err := e.Change(ctx)
	if err != nil {
		return false
	}
	_ = b.Stop(ctx, name)
	inst, err := b.Get(ctx, name)
	return err == nil && inst.Status == vm.Stopped
}

// Delete stops and deletes the VM name, then forgets what was known of it.
// False, with an Error event, when it is still there (or cannot be asked):
// --reset would otherwise go on with the old VM and its shares.
func (e *Engine) Delete(ctx context.Context, name string) bool {
	b, err := e.Change(ctx)
	if err == nil {
		_ = b.Delete(ctx, name)
		_, err = b.Get(ctx, name)
	}
	if !errors.Is(err, vm.ErrNotFound) {
		e.warnf("Error: could not delete VM '%s'. See '%s list', then retry.", name, e.app)
		return false
	}
	// Lima's folder went with the VM; the rest of its folder goes now, and
	// with it all that is known of the VM: nothing outlives it.
	if err := e.state.Forget(name); err != nil {
		e.warnf("Warning: %v", err)
	}
	return true
}

// lockVM takes the lock of name, which serialises what changes that VM
// between runs: two runs in one folder would otherwise clean up, clone and
// configure the same VM at once. It waits, saying so, until the holder is
// done or ctx ends. The lock is a file in the state folder's locks/, kept
// for the next run: a crashed holder releases it with its process.
func (e *Engine) lockVM(ctx context.Context, name string) (unlock func(), err error) {
	dir := e.state.Path("locks")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(dir, name), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, err
	}
	told := false
	for {
		ok, err := tryLock(f)
		if err != nil {
			f.Close()
			return nil, err
		}
		if ok {
			// Closing the file releases the lock.
			return func() { f.Close() }, nil
		}
		if !told {
			e.warnf("Waiting for another %s that is working on '%s'...", e.app, name)
			told = true
		}
		select {
		case <-ctx.Done():
			f.Close()
			return nil, ctx.Err()
		case <-time.After(200 * time.Millisecond):
		}
	}
}

// Refs are the locations no share may reach (see mounts.Refs).
func (e *Engine) Refs() []mounts.Ref {
	self := ""
	if exe, err := os.Executable(); err == nil {
		if p, err := filepath.EvalSymlinks(exe); err == nil {
			self = paths.Host(filepath.Dir(p))
		}
	}
	limaHomes := append([]string{e.opts.LimaHome}, e.opts.NeverShare...)
	return mounts.Refs(paths.Home(), self, string(e.state), limaHomes...)
}

// Entries are the usable entries of the volumes file for the project dir,
// their warnings on warn.
func (e *Engine) Entries(dir string, warn io.Writer) []mounts.Entry {
	if e.opts.VolumesFile == "" {
		return nil
	}
	return mounts.Entries(e.opts.VolumesFile, dir, paths.Home(), e.Refs(), warn)
}

// Scan is the git scan of the project dir's writable shares (see
// gitguard.Scan), the volumes read quietly.
func (e *Engine) Scan(ctx context.Context, dir string) *gitguard.Result {
	shares := gitguard.Shares(dir, mounts.RWDirs(e.Entries(dir, io.Discard)))
	return gitguard.Scan(ctx, shares, paths.Home())
}
