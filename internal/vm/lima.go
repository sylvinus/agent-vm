package vm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"

	"al.essio.dev/pkg/shellescape"
	"github.com/coreos/go-semver/semver"
	"github.com/mattn/go-isatty"
	"github.com/sirupsen/logrus"

	"github.com/lima-vm/lima/v2/pkg/driver/external/server"
	"github.com/lima-vm/lima/v2/pkg/driverutil"
	"github.com/lima-vm/lima/v2/pkg/instance"
	"github.com/lima-vm/lima/v2/pkg/limatmpl"
	"github.com/lima-vm/lima/v2/pkg/limatype"
	"github.com/lima-vm/lima/v2/pkg/limatype/dirnames"
	"github.com/lima-vm/lima/v2/pkg/limatype/filenames"
	"github.com/lima-vm/lima/v2/pkg/limayaml"
	"github.com/lima-vm/lima/v2/pkg/networks/reconcile"
	"github.com/lima-vm/lima/v2/pkg/osutil"
	"github.com/lima-vm/lima/v2/pkg/sshutil"
	"github.com/lima-vm/lima/v2/pkg/store"
	"github.com/lima-vm/lima/v2/pkg/yqutil"

	"github.com/sylvinus/agent-vm/internal/limaembed"
	"github.com/sylvinus/agent-vm/internal/paths"
)

// Lima runs VMs with the Lima built into agent-vm, as limactl's commands
// do, in this process; its hostagent is this executable again (see
// limaembed.Run).
type Lima struct {
	stateDir string

	once  sync.Once
	share *limaembed.Share
	err   error
}

// MaxName is the longest VM name whose sockets fit under the Lima home
// home (UNIX_PATH_MAX: 104 bytes on macOS), and Lima's 76 at most. Lima
// resolves the home's symlinks: so does this, as far as it exists.
func MaxName(home string) int {
	real, rest := home, ""
	for {
		if p, err := filepath.EvalSymlinks(real); err == nil {
			real = filepath.Join(p, rest)
			break
		}
		parent := filepath.Dir(real)
		if parent == real {
			real = home
			break
		}
		rest = filepath.Join(filepath.Base(real), rest)
		real = parent
	}
	// <home>/<name>/<socket>, shorter than UnixPathMax (its NUL).
	n := osutil.UnixPathMax - 1 - len(real) - len("/") - len("/"+filenames.LongestSock)
	return min(n, 76)
}

// NewLima keeps its VMs in home (LIMA_HOME), and writes Lima's guest agent
// and templates under stateDir.
func NewLima(home, stateDir string) (*Lima, error) {
	if err := os.Setenv("LIMA_HOME", home); err != nil {
		return nil, err
	}
	limaHomeSet = home
	return &Lima{stateDir: stateDir}, nil
}

// limaHomeSet is the LIMA_HOME NewLima set for Lima's packages.
var limaHomeSet string

// UserLimaHome is the user's own LIMA_HOME, "" when unset: what NewLima
// set in this process is not theirs.
func UserLimaHome() string {
	if h := os.Getenv("LIMA_HOME"); h != limaHomeSet {
		return h
	}
	return ""
}

// prepare writes the embedded share once, and points Lima's template store
// at it. It refuses Lima's default.yaml and override.yaml, which Lima mixes
// into every VM's config (shares, mount type...): agent-vm's VMs get what
// agent-vm sets, nothing else.
func (l *Lima) prepare() (*limaembed.Share, error) {
	l.once.Do(func() {
		l.share, l.err = limaembed.WriteShare(l.stateDir)
		if l.err == nil {
			l.err = os.Setenv("LIMA_TEMPLATES_PATH", l.share.Templates())
		}
	})
	if l.err != nil {
		return nil, l.err
	}
	home, err := dirnames.LimaDir()
	if err != nil {
		return nil, err
	}
	if found := LimaOverrides(home); len(found) > 0 {
		return nil, fmt.Errorf("%w: %s", ErrLimaOverrides, strings.Join(found, ", "))
	}
	return l.share, nil
}

// Confined fails unless every share of inst is served by the builtin SFTP
// server, over reverse-sshfs: the one server confined to its folder. No
// other way into the host is started.
func Confined(inst *Instance) error {
	for _, m := range inst.Mounts {
		if m.SSHFS == nil || m.SSHFS.SFTPDriver != "builtin" {
			return fmt.Errorf("%w: the share of %s is not served by the builtin SFTP server", ErrUnconfined, m.Location)
		}
	}
	if len(inst.Mounts) > 0 && inst.MountType != ReverseSSHFS {
		return fmt.Errorf("%w: the mount type is %q, not %s", ErrUnconfined, inst.MountType, ReverseSSHFS)
	}
	return nil
}

// LimaOverrides are the default.yaml and override.yaml found in the Lima
// home home, which agent-vm refuses.
func LimaOverrides(home string) []string {
	var out []string
	for _, f := range []string{filenames.Default, filenames.Override} {
		p := filepath.Join(home, filenames.ConfigDir, f)
		if _, err := os.Lstat(p); err == nil {
			out = append(out, p)
		}
	}
	return out
}

func (l *Lima) List(ctx context.Context) ([]*Instance, error) {
	names, err := store.Instances()
	if err != nil {
		return nil, err
	}
	sort.Strings(names)
	var out []*Instance
	for _, name := range names {
		inst, err := l.Get(ctx, name)
		if errors.Is(err, ErrNotFound) {
			continue
		}
		if err != nil {
			return nil, err
		}
		out = append(out, inst)
	}
	return out, nil
}

func (l *Lima) Get(ctx context.Context, name string) (*Instance, error) {
	inst, err := l.inspect(ctx, name)
	if err != nil {
		return nil, err
	}
	return fromLima(inst), nil
}

func (l *Lima) inspect(ctx context.Context, name string) (*limatype.Instance, error) {
	inst, err := store.Inspect(ctx, name)
	if errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("%w: %s", ErrNotFound, name)
	}
	return inst, err
}

func fromLima(inst *limatype.Instance) *Instance {
	out := &Instance{
		Name:         inst.Name,
		Dir:          inst.Dir,
		CPUs:         inst.CPUs,
		Memory:       inst.Memory,
		Disk:         inst.Disk,
		SSHLocalPort: inst.SSHLocalPort,
		SSHAddress:   inst.SSHAddress,
		SSHConfig:    inst.SSHConfigFile,
		VMType:       inst.VMType,
		Arch:         inst.Arch,
	}
	switch inst.Status {
	case limatype.StatusRunning:
		out.Status = Running
	case limatype.StatusStopped:
		out.Status = Stopped
	default:
		out.Status = Broken
	}
	if inst.Config == nil {
		out.Status = Broken
		out.ConfigErr = errors.Join(inst.Errors...)
	}
	if c := inst.Config; c != nil {
		if c.SSH.LocalPort != nil {
			out.SSHPortConfig = *c.SSH.LocalPort
		}
		if c.MountType != nil {
			out.MountType = *c.MountType
		}
		for _, m := range c.Mounts {
			mm := Mount{Location: paths.Host(m.Location), Writable: m.Writable != nil && *m.Writable}
			if m.MountPoint != nil {
				mm.MountPoint = *m.MountPoint
			}
			if s := m.SSHFS; s.SFTPDriver != nil || s.Cache != nil || len(s.ReadonlyNames) > 0 {
				mm.SSHFS = &SSHFS{Cache: s.Cache, ReadonlyNames: s.ReadonlyNames}
				if s.SFTPDriver != nil {
					mm.SSHFS.SFTPDriver = string(*s.SFTPDriver)
				}
			}
			out.Mounts = append(out.Mounts, mm)
		}
	}
	return out
}

// exprs are the yq expressions of s, as limactl's edit flags make them.
func exprs(s Settings) ([]string, error) {
	var e []string
	if s.CPUs > 0 {
		e = append(e, fmt.Sprintf(".cpus = %d", s.CPUs))
	}
	if s.MemoryGiB > 0 {
		e = append(e, fmt.Sprintf(".memory = %q", strconv.Itoa(s.MemoryGiB)+"GiB"))
	}
	if s.DiskGiB > 0 {
		e = append(e, fmt.Sprintf(".disk = %q", strconv.Itoa(s.DiskGiB)+"GiB"))
	}
	if s.NoContainerd {
		e = append(e, ".containerd.user = false | .containerd.system = false")
	}
	if s.SSHLocalPort != nil {
		e = append(e, fmt.Sprintf(".ssh.localPort = %d", *s.SSHLocalPort))
	}
	if s.MountType != nil {
		if *s.MountType == "" {
			e = append(e, "del(.mountType)")
		} else {
			e = append(e, fmt.Sprintf(".mountType = %q", *s.MountType))
		}
	}
	if s.Mounts != nil {
		mounts := *s.Mounts
		if mounts == nil {
			mounts = []Mount{}
		}
		// yq reads the JSON's strings without its \u escapes: none for & < >
		// (what else JSON escapes, the paths cannot hold: see sharesKept).
		var j bytes.Buffer
		enc := json.NewEncoder(&j)
		enc.SetEscapeHTML(false)
		if err := enc.Encode(mounts); err != nil {
			return nil, err
		}
		e = append(e, ".mounts = "+strings.TrimSuffix(j.String(), "\n"))
	}
	return e, nil
}

func (l *Lima) Create(ctx context.Context, name, template string, s Settings, log io.Writer) error {
	if _, err := l.prepare(); err != nil {
		return err
	}
	if _, err := store.Inspect(ctx, name); err == nil {
		return fmt.Errorf("VM %s already exists", name)
	}
	return withLog(log, func() error {
		tmpl, err := limatmpl.Read(ctx, name, template)
		if err != nil {
			return err
		}
		// Without _config/base.yaml, which limactl mixes into every template.
		if err := tmpl.Embed(ctx, true, false); err != nil {
			return err
		}
		if err := tmpl.Unmarshal(); err != nil {
			return err
		}
		e, err := exprs(s)
		if err != nil {
			return err
		}
		if len(e) > 0 {
			if tmpl.Bytes, err = yqutil.EvaluateExpression(ctx, yqutil.Join(e), tmpl.Bytes); err != nil {
				return err
			}
		}
		_, err = instance.Create(ctx, name, tmpl.Bytes, false)
		return err
	})
}

func (l *Lima) Clone(ctx context.Context, from, to string) error {
	inst, err := l.inspect(ctx, from)
	if err != nil {
		return err
	}
	dir, err := dirnames.InstanceDir(to)
	switch {
	case err != nil && strings.Contains(err.Error(), "maximum length"):
		return fmt.Errorf("%w: %v", ErrNameTooLong, err)
	case err != nil:
		return err
	}
	if sock := filepath.Join(dir, filenames.LongestSock); len(sock) >= osutil.UnixPathMax {
		return fmt.Errorf("%w: its sockets in %s would need %d characters, at most %d", ErrNameTooLong, filepath.Dir(dir), len(sock), osutil.UnixPathMax-1)
	}
	_, err = instance.CloneOrRename(ctx, inst, to, false)
	return err
}

// Edit applies s as `limactl edit` does: the same checks, and nothing is
// written when one fails.
func (l *Lima) Edit(ctx context.Context, name string, s Settings) error {
	inst, err := l.inspect(ctx, name)
	if err != nil {
		return err
	}
	if inst.Status == limatype.StatusRunning {
		return fmt.Errorf("cannot edit the running VM %s", name)
	}
	e, err := exprs(s)
	if err != nil || len(e) == 0 {
		return err
	}
	path := filepath.Join(inst.Dir, filenames.LimaYAML)
	old, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	y, err := yqutil.EvaluateExpression(ctx, yqutil.Join(e), old)
	if err != nil {
		return err
	}
	if bytes.Equal(y, old) {
		return nil
	}
	cfg, err := limayaml.LoadWithWarnings(ctx, y, path)
	if err != nil {
		return err
	}
	if s.Mounts != nil {
		if err := sharesKept(*s.Mounts, cfg.Mounts); err != nil {
			return err
		}
	}
	if err := driverutil.ResolveVMType(cfg); err != nil {
		return err
	}
	if err := limayaml.Validate(cfg, false); err != nil {
		return err
	}
	inst.Config = cfg
	drv, err := driverutil.CreateConfiguredDriver(ctx, inst, 0)
	if err != nil {
		return err
	}
	defer server.Stop(inst.Dir, true)
	if err := drv.Validate(ctx); err != nil {
		return err
	}
	if err := limayaml.Validate(inst.Config, true); err != nil {
		return err
	}
	if err := limayaml.ValidateAgainstLatestConfig(ctx, y, old); err != nil {
		return err
	}
	// Whole or not at all: a crash midway would leave a truncated lima.yaml.
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, y, 0o644); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}

// sharesKept fails unless Lima reads every share as written: it expands Go
// templates in their paths ({{.Home}}), and yq keeps JSON's \u escapes as
// text, so another folder than the one asked for would be shared.
func sharesKept(want []Mount, got []limatype.Mount) error {
	if len(got) != len(want) {
		return fmt.Errorf("%w: Lima reads %d shares, not %d", ErrUnmountable, len(got), len(want))
	}
	for i, m := range want {
		mp := m.MountPoint
		if mp == "" {
			mp = m.Location
		}
		// Lima makes a location absolute with filepath.Abs: C:\x on Windows.
		if paths.Host(got[i].Location) != m.Location || got[i].MountPoint == nil || *got[i].MountPoint != mp {
			return fmt.Errorf("%w: Lima reads %q as another path", ErrUnmountable, m.Location)
		}
		if m.SSHFS != nil && !slices.Equal(got[i].SSHFS.ReadonlyNames, m.SSHFS.ReadonlyNames) {
			return fmt.Errorf("%w: Lima reads the read-only names of %q otherwise", ErrUnmountable, m.Location)
		}
	}
	return nil
}

// logMu keeps two calls from taking logrus's output from each other.
var logMu sync.Mutex

// withLog runs fn with Lima's logrus output going to log.
func withLog(log io.Writer, fn func() error) error {
	logMu.Lock()
	defer logMu.Unlock()
	saved := logrus.StandardLogger().Out
	logrus.SetOutput(log)
	defer logrus.SetOutput(saved)
	return fn()
}

func (l *Lima) Start(ctx context.Context, name string, log io.Writer) error {
	share, err := l.prepare()
	if err != nil {
		return err
	}
	inst, err := l.inspect(ctx, name)
	if err != nil {
		return err
	}
	if inst.Status == limatype.StatusRunning {
		return nil
	}
	if inst.Config == nil {
		return errors.Join(inst.Errors...)
	}
	if err := Confined(fromLima(inst)); err != nil {
		return err
	}
	return withLog(log, func() error {
		if err := reconcile.Reconcile(ctx, name); err != nil {
			return err
		}
		return instance.StartWithPaths(ctx, inst, false, false, "", share.GuestAgent)
	})
}

func (l *Lima) Stop(ctx context.Context, name string) error {
	inst, err := l.inspect(ctx, name)
	if err != nil {
		return err
	}
	if inst.Status != limatype.StatusRunning {
		return nil
	}
	return withLog(io.Discard, func() error {
		return errors.Join(instance.StopGracefully(ctx, inst, false), reconcile.Reconcile(ctx, ""))
	})
}

func (l *Lima) Delete(ctx context.Context, name string) error {
	inst, err := l.inspect(ctx, name)
	if err != nil {
		return err
	}
	return withLog(io.Discard, func() error {
		if inst.Status == limatype.StatusRunning {
			_ = instance.StopGracefully(ctx, inst, false)
		}
		return errors.Join(instance.Delete(ctx, inst, true), reconcile.Reconcile(ctx, ""))
	})
}

func isTerminal(v any) bool {
	f, ok := v.(*os.File)
	return ok && (isatty.IsTerminal(f.Fd()) || isatty.IsCygwinTerminal(f.Fd()))
}

// Shell runs o as `limactl shell` does: over ssh, by the user's login
// shell, from o.Workdir (or fails), with a terminal when stdout is one.
func (l *Lima) Shell(ctx context.Context, name string, o ShellOpts) (int, error) {
	inst, err := l.inspect(ctx, name)
	if err != nil {
		return 0, err
	}
	if inst.Status != limatype.StatusRunning || inst.Config == nil {
		return 0, fmt.Errorf("VM %s is not running", name)
	}
	// Without a workdir, the guest user's home (limactl's fallback).
	cd := "false"
	if o.Workdir != "" {
		cd = "cd " + shellescape.Quote(o.Workdir) + " || exit 1"
	}
	shell := `"$SHELL"`
	if inst.Config.User.Shell != nil {
		shell = shellescape.Quote(*inst.Config.User.Shell)
	}
	script := cd + " ; exec " + shell + " -l"
	if len(o.Args) > 0 {
		q := make([]string, len(o.Args))
		for i, a := range o.Args {
			q[i] = shellescape.Quote(a)
		}
		script += " -c " + shellescape.Quote(strings.Join(q, " "))
	}
	sshExe, err := sshutil.NewSSHExe()
	if err != nil {
		return 0, err
	}
	c := inst.Config
	opts, err := sshutil.SSHOpts(ctx, sshExe, inst.Dir, *c.User.Name, *c.SSH.LoadDotSSHPubKeys,
		*c.SSH.ForwardAgent, *c.SSH.ForwardX11, *c.SSH.ForwardX11Trusted)
	if err != nil {
		return 0, err
	}
	if runtime.GOOS == "windows" {
		// Cygwin-based ssh clients do not multiplex commands (as limactl shell).
		opts = sshutil.SSHOptsRemovingControlPath(opts)
	}
	args := append(append([]string{}, sshExe.Args...), sshutil.SSHArgsFromOpts(opts)...)
	// A terminal when stdout is one, as limactl shell does, or when asked
	// for and stdin is one.
	if isTerminal(o.Stdout) || o.Interactive && isTerminal(o.Stdin) {
		args = append(args, "-t")
	}
	if _, ok := os.LookupEnv("COLORTERM"); ok {
		args = append(args, "-o", "SendEnv=COLORTERM")
	}
	logLevel := "ERROR"
	if sshutil.DetectOpenSSHVersion(ctx, sshExe).LessThan(*semver.New("8.9.0")) {
		logLevel = "QUIET"
	}
	args = append(args, "-o", "LogLevel="+logLevel, "-p", strconv.Itoa(inst.SSHLocalPort), inst.SSHAddress, "--", script)
	cmd := exec.CommandContext(ctx, sshExe.Exe, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = o.Stdin, o.Stdout, o.Stderr
	err = cmd.Run()
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode(), nil
	}
	if err != nil {
		return 0, err
	}
	return 0, nil
}
