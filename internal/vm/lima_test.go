package vm

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/sylvinus/agent-vm/third_party/lima/pkg/guestagent/api"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/hostagent/events"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype/dirnames"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype/filenames"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limayaml"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/portfwd"
	limaversion "github.com/sylvinus/agent-vm/third_party/lima/pkg/version"

	"github.com/sylvinus/agent-vm/internal/limaembed"
	"github.com/sylvinus/agent-vm/internal/paths"
)

// newTestLima is a Lima with its VMs in vms/<name>/lima, as agent-vm keeps
// them: in dirnames.InstancesEnv.
func newTestLima(t *testing.T) *Lima {
	t.Helper()
	return newLima(t, t.TempDir())
}

// newLegacyLima keeps its VMs in its Lima home, as 0.2 and 0.3.0 did.
func newLegacyLima(t *testing.T) *Lima {
	t.Helper()
	return newLima(t, "")
}

func newLima(t *testing.T, vms string) *Lima {
	t.Helper()
	home := t.TempDir()
	t.Setenv("LIMA_HOME", home)
	t.Setenv("LIMA_TEMPLATES_PATH", "")
	// NewLima sets the VMs' folder for Lima's packages: put it back.
	t.Setenv(dirnames.InstancesEnv, "")
	l, err := NewLima(home, vms, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := l.prepare(); errors.Is(err, limaembed.ErrNoAssets) {
		t.Skip("built without the guest agent: make assets")
	} else if err != nil {
		t.Fatal(err)
	}
	return l
}

// What agent-vm does to a VM without booting it: create, edit its shares,
// clone, delete.
func TestLimaLifecycle(t *testing.T) {
	ctx := context.Background()
	l := newTestLima(t)
	none := []Mount{}
	err := l.Create(ctx, "base", "template:debian-13", Settings{CPUs: 1, MemoryGiB: 2, DiskGiB: 10, Mounts: &none, NoContainerd: true}, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	base, err := l.Get(ctx, "base")
	if err != nil {
		t.Fatal(err)
	}
	if base.Status != Stopped || base.CPUs != 1 || base.Memory != 2<<30 || base.Disk != 10<<30 || len(base.Mounts) != 0 {
		t.Fatalf("created: %+v", base)
	}
	// Lima's containerd stays out: Docker brings its own when chosen.
	if y, _ := os.ReadFile(filepath.Join(os.Getenv(dirnames.InstancesEnv), "base", "lima", "lima.yaml")); !strings.Contains(string(y), "containerd:\n  user: false\n  system: false") {
		t.Errorf("containerd in lima.yaml:\n%s", y)
	}

	if err := l.Clone(ctx, "base", "p-12345678"); err != nil {
		t.Fatal(err)
	}
	// A name whose sockets would not fit here, or longer than Lima's 76
	// characters: said so, nothing made.
	long := "agent-vm-" + strings.Repeat("x", 50) + "-12345678"
	if err := l.Clone(ctx, "base", long); !errors.Is(err, ErrNameTooLong) {
		t.Errorf("long name: %v", err)
	}
	if _, err := l.Get(ctx, long); !errors.Is(err, ErrNotFound) {
		t.Errorf("a long name was made: %v", err)
	}
	if err := l.Clone(ctx, "base", long+strings.Repeat("y", 20)); !errors.Is(err, ErrNameTooLong) {
		t.Errorf("name over 76: %v", err)
	}
	// MaxName is exactly what fits here.
	if m := MaxName(os.Getenv(dirnames.InstancesEnv)); m < 76 {
		fits := strings.Repeat("n", m-9) + "-12345678"
		if err := l.Clone(ctx, "base", fits); err != nil {
			t.Errorf("a name of MaxName (%d): %v", m, err)
		}
		l.Delete(ctx, fits)
		if err := l.Clone(ctx, "base", "n"+fits); !errors.Is(err, ErrNameTooLong) {
			t.Errorf("a name of MaxName+1: %v", err)
		}
	} else {
		t.Errorf("MaxName = %d: the test's folder for VMs is long, it should be less than 76", m)
	}

	proj := t.TempDir()
	off := false
	mounts := []Mount{{Location: proj, MountPoint: proj, Writable: true,
		SSHFS: &SSHFS{SFTPDriver: "builtin", Cache: &off, ReadonlyNames: []string{".git", ".hg"}}}}
	rev := ReverseSSHFS
	port := 23456
	if err := l.Edit(ctx, "p-12345678", Settings{Mounts: &mounts, MountType: &rev, SSHLocalPort: &port, CPUs: 2}); err != nil {
		t.Fatal(err)
	}
	p, err := l.Get(ctx, "p-12345678")
	if err != nil {
		t.Fatal(err)
	}
	if p.MountType != ReverseSSHFS || p.SSHLocalPort != 23456 || p.CPUs != 2 || !reflect.DeepEqual(p.Mounts, mounts) {
		t.Fatalf("edited: %+v %+v", p, p.Mounts)
	}

	// A path Lima reads as written; those it would read as another (a Go
	// template, what JSON escapes) refused, nothing written.
	amp := filepath.Join(t.TempDir(), "R&D <x>")
	os.MkdirAll(amp, 0o755)
	withAmp := []Mount{{Location: amp, MountPoint: amp, Writable: true, SSHFS: &SSHFS{SFTPDriver: "builtin", ReadonlyNames: []string{".git", "a&b"}}}}
	if err := l.Edit(ctx, "p-12345678", Settings{Mounts: &withAmp}); err != nil {
		t.Fatal(err)
	}
	if p, _ := l.Get(ctx, "p-12345678"); len(p.Mounts) != 1 || p.Mounts[0].Location != amp || p.Mounts[0].SSHFS.ReadonlyNames[1] != "a&b" {
		t.Errorf("& and <>: %+v", p.Mounts)
	}
	before0, _ := os.ReadFile(filepath.Join(p.Dir, "lima.yaml"))
	for _, name := range []string{"t{{.Home}}", "q{{.Foo}}", "bad\xffbyte", "line\u2028sep"} {
		odd := []Mount{{Location: "/tmp/" + name, MountPoint: "/tmp/x", Writable: true, SSHFS: &SSHFS{SFTPDriver: "builtin", ReadonlyNames: []string{".git"}}}}
		if err := l.Edit(ctx, "p-12345678", Settings{Mounts: &odd}); !errors.Is(err, ErrUnmountable) {
			t.Errorf("%q: %v", name, err)
		}
	}
	if after, _ := os.ReadFile(filepath.Join(p.Dir, "lima.yaml")); string(after) != string(before0) {
		t.Error("a refused share was written")
	}
	if err := l.Edit(ctx, "p-12345678", Settings{Mounts: &mounts}); err != nil {
		t.Fatal(err)
	}

	// Lima refuses a name with a slash: nothing is written.
	yaml := filepath.Join(p.Dir, "lima.yaml")
	before, _ := os.ReadFile(yaml)
	bad := []Mount{{Location: proj, Writable: true, SSHFS: &SSHFS{SFTPDriver: "builtin", ReadonlyNames: []string{"a/b"}}}}
	if err := l.Edit(ctx, "p-12345678", Settings{Mounts: &bad}); err == nil {
		t.Error("a name with a slash was accepted")
	}
	if after, _ := os.ReadFile(yaml); string(after) != string(before) {
		t.Error("a refused edit changed lima.yaml")
	}

	// Lima's override.yaml, with a share lacking the builtin SFTP server the
	// read-only names need: Lima refuses the config, and says why.
	cfg := filepath.Join(os.Getenv("LIMA_HOME"), "_config")
	os.MkdirAll(cfg, 0o755)
	os.WriteFile(filepath.Join(cfg, "override.yaml"), []byte("mounts:\n- location: "+t.TempDir()+"\n  writable: true\n"), 0o644)
	if p, err := l.Get(ctx, "p-12345678"); err != nil || p.Status != Broken || p.ConfigErr == nil || !strings.Contains(p.ConfigErr.Error(), "sftpDriver") {
		t.Errorf("get, refused: %v %+v", err, p)
	}
	// No VM made or started while it is there.
	if err := l.Create(ctx, "q-12345678", "template:debian-13", Settings{Mounts: &none}, io.Discard); !errors.Is(err, ErrLimaOverrides) {
		t.Errorf("create with an override: %v", err)
	}
	if err := l.Start(ctx, "p-12345678", io.Discard); !errors.Is(err, ErrLimaOverrides) {
		t.Errorf("start with an override: %v", err)
	}
	os.Remove(filepath.Join(cfg, "override.yaml"))

	// Back to Lima's default mount type, and no shares.
	def := ""
	if err := l.Edit(ctx, "p-12345678", Settings{Mounts: &none, MountType: &def}); err != nil {
		t.Fatal(err)
	}
	if p, _ := l.Get(ctx, "p-12345678"); len(p.Mounts) != 0 || p.MountType == ReverseSSHFS {
		t.Errorf("reset: %+v", p)
	}

	// Never started with a share not confined to its folder.
	plain := []Mount{{Location: proj, Writable: true}}
	builtin := []Mount{{Location: proj, Writable: true, SSHFS: &SSHFS{SFTPDriver: "builtin"}}}
	for _, set := range []Settings{{Mounts: &plain, MountType: &rev}, {Mounts: &builtin, MountType: &def}} {
		if err := l.Edit(ctx, "p-12345678", set); err != nil {
			t.Fatal(err)
		}
		if err := l.Start(ctx, "p-12345678", io.Discard); !errors.Is(err, ErrUnconfined) {
			t.Errorf("start, %+v: %v", set, err)
		}
	}
	if err := l.Edit(ctx, "p-12345678", Settings{Mounts: &none, MountType: &def}); err != nil {
		t.Fatal(err)
	}

	// _config/base.yaml is not mixed into a new VM.
	cfgDir := filepath.Join(os.Getenv("LIMA_HOME"), "_config")
	os.MkdirAll(cfgDir, 0o755)
	os.WriteFile(filepath.Join(cfgDir, "base.yaml"), []byte("cpus: 7\n"), 0o644)
	if err := l.Create(ctx, "b-12345678", "template:debian-13", Settings{Mounts: &none}, io.Discard); err != nil {
		t.Fatal(err)
	}
	if b, _ := l.Get(ctx, "b-12345678"); b == nil || b.CPUs == 7 {
		t.Errorf("base.yaml mixed in: %+v", b)
	}
	os.Remove(filepath.Join(cfgDir, "base.yaml"))
	l.Delete(ctx, "b-12345678")

	list, err := l.List(ctx)
	if err != nil || len(list) != 2 || list[0].Name != "base" || list[1].Name != "p-12345678" {
		t.Fatalf("list: %v %v", list, err)
	}
	for _, name := range []string{"base", "p-12345678"} {
		if err := l.Delete(ctx, name); err != nil {
			t.Fatal(err)
		}
		if _, err := l.Get(ctx, name); !errors.Is(err, ErrNotFound) {
			t.Errorf("%s after delete: %v", name, err)
		}
	}
}

// Start gives a VM, made before or not, the rule leaving the guest's
// ephemeral ports unforwarded: on 127.0.0.1, 0.0.0.0, ::, TCP or UDP, as
// Lima's forwarder reads it. Other ports are forwarded still.
func TestLimaEphemeralPorts(t *testing.T) {
	ctx := context.Background()
	l := newTestLima(t)
	// Unconfined: Start edits it, then refuses to boot it.
	plain := []Mount{{Location: t.TempDir(), Writable: true}}
	rev := ReverseSSHFS
	if err := l.Create(ctx, "p-12345678", "template:debian-13", Settings{Mounts: &plain, MountType: &rev}, io.Discard); err != nil {
		t.Fatal(err)
	}
	// A forward of the VM's own, which Start keeps.
	yamlPath := filepath.Join(os.Getenv(dirnames.InstancesEnv), "p-12345678", "lima", "lima.yaml")
	orig, _ := os.ReadFile(yamlPath)
	custom := "\nportForwards:\n- guestPort: 40000\n  hostPort: 40001\n"
	if err := os.WriteFile(yamlPath, append(orig, custom...), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := l.Start(ctx, "p-12345678", io.Discard); !errors.Is(err, ErrUnconfined) {
		t.Fatalf("start: %v", err)
	}
	inst, err := l.inspect(ctx, "p-12345678")
	if err != nil || inst.Config == nil {
		t.Fatalf("inspect: %v %v", err, inst.Errors)
	}
	if n := len(inst.Config.PortForwards); n != 2 || inst.Config.PortForwards[0].GuestPort != 40000 {
		t.Errorf("port forwards: %+v", inst.Config.PortForwards)
	}
	def := limatype.PortForward{}
	limayaml.FillPortForwardDefaults(&def, inst.Dir, inst.Config.User, inst.Param)
	var got []events.PortForwardEvent
	fw := portfwd.NewPortForwarder(append(inst.Config.PortForwards, def), false, false, func(ev *events.PortForwardEvent) { got = append(got, *ev) })
	defer fw.Close()
	cctx, cancel := context.WithCancel(ctx)
	defer cancel()
	for _, p := range []*api.IPPort{
		{Protocol: "tcp", Ip: "127.0.0.1", Port: 32768},
		{Protocol: "tcp", Ip: "0.0.0.0", Port: 45000},
		{Protocol: "tcp", Ip: "::", Port: 60999},
		{Protocol: "udp", Ip: "0.0.0.0", Port: 50000},
	} {
		got = nil
		fw.OnEvent(cctx, nil, &api.Event{AddedLocalPorts: []*api.IPPort{p}})
		if len(got) != 1 || got[0].Type != events.PortForwardEventNotForwarding {
			t.Errorf("%s %s:%d: %+v", p.Protocol, p.Ip, p.Port, got)
		}
	}
	// Forwarded, or not because the host uses it: not ignored either way.
	got = nil
	fw.OnEvent(cctx, nil, &api.Event{AddedLocalPorts: []*api.IPPort{{Protocol: "tcp", Ip: "0.0.0.0", Port: 32767}}})
	if len(got) != 1 || got[0].Type == events.PortForwardEventNotForwarding {
		t.Errorf("32767: %+v", got)
	}

	// Once there, not written again.
	y := filepath.Join(inst.Dir, "lima.yaml")
	before, _ := os.ReadFile(y)
	l.Start(ctx, "p-12345678", io.Discard)
	if after, _ := os.ReadFile(y); string(after) != string(before) || strings.Count(string(after), "ignore: true") != 1 {
		t.Errorf("rewritten:\n%s", after)
	}
}

// Only the builtin SFTP server over reverse-sshfs is confined.
// Lima reads a location back through filepath.Abs, C:\p on Windows: the
// share asked as C:/p, kept.
func TestSharesKeptWindows(t *testing.T) {
	old := paths.Windows
	paths.Windows = func() bool { return true }
	t.Cleanup(func() { paths.Windows = old })
	mp := "/c/p"
	want := []Mount{{Location: "C:/p", MountPoint: mp}}
	if err := sharesKept(want, []limatype.Mount{{Location: `C:\p`, MountPoint: &mp}}); err != nil {
		t.Errorf("C:\\p: %v", err)
	}
	if err := sharesKept(want, []limatype.Mount{{Location: `C:\q`, MountPoint: &mp}}); !errors.Is(err, ErrUnmountable) {
		t.Errorf("C:\\q: %v", err)
	}
}

// A driver running without its hostagent: orphaned, and Stop kills it. A
// hostagent without its driver is not: it may be booting the VM.
func TestLimaStopOrphaned(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("no sleep to stand for the driver")
	}
	ctx := context.Background()
	l := newTestLima(t)
	none := []Mount{}
	if err := l.Create(ctx, "o", "template:debian-13", Settings{Mounts: &none}, io.Discard); err != nil {
		t.Fatal(err)
	}
	inst, err := l.Get(ctx, "o")
	if err != nil {
		t.Fatal(err)
	}
	driver := exec.Command("sleep", "60")
	if err := driver.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan struct{})
	go func() { driver.Wait(); close(exited) }()
	t.Cleanup(func() { driver.Process.Kill(); <-exited })
	pid := []byte(strconv.Itoa(driver.Process.Pid))

	ha := filepath.Join(inst.Dir, filenames.HostAgentPID)
	os.WriteFile(ha, pid, 0o644)
	if got, _ := l.Get(ctx, "o"); got.Status != Broken || got.Orphaned {
		t.Fatalf("a hostagent without its driver: %+v", got)
	}
	l.Stop(ctx, "o")
	select {
	case <-exited:
		t.Fatal("Stop killed a hostagent without its driver")
	case <-time.After(200 * time.Millisecond):
	}
	os.Remove(ha)

	os.WriteFile(filepath.Join(inst.Dir, filenames.PIDFile(inst.VMType)), pid, 0o644)
	if got, _ := l.Get(ctx, "o"); got.Status != Broken || !got.Orphaned {
		t.Fatalf("a driver without its hostagent: %+v", got)
	}
	if err := l.Stop(ctx, "o"); err != nil {
		t.Fatal(err)
	}
	select {
	case <-exited:
	case <-time.After(10 * time.Second):
		t.Fatal("the driver still runs")
	}
	if got, _ := l.Get(ctx, "o"); got.Status != Stopped || got.Orphaned {
		t.Errorf("after Stop: %+v", got)
	}
}

func TestConfined(t *testing.T) {
	b := &SSHFS{SFTPDriver: "builtin"}
	for _, c := range []struct {
		inst *Instance
		ok   bool
	}{
		{&Instance{}, true},
		{&Instance{MountType: ReverseSSHFS, Mounts: []Mount{{Location: "/p", SSHFS: b}}}, true},
		{&Instance{MountType: ReverseSSHFS, Mounts: []Mount{{Location: "/p", SSHFS: b}, {Location: "/q"}}}, false},
		{&Instance{MountType: ReverseSSHFS, Mounts: []Mount{{Location: "/p", SSHFS: &SSHFS{SFTPDriver: "openssh-sftp-server"}}}}, false},
		{&Instance{MountType: "9p", Mounts: []Mount{{Location: "/p", SSHFS: b}}}, false},
		{&Instance{Mounts: []Mount{{Location: "/p", SSHFS: b}}}, false},
	} {
		if err := Confined(c.inst); (err == nil) != c.ok || err != nil && !errors.Is(err, ErrUnconfined) {
			t.Errorf("%+v: %v", c.inst, err)
		}
	}
}

// The engine is written for Lima as patches/lima makes it: its patch level is
// named here, and a patch changes it with what the engine does of it.
func TestPatchLevel(t *testing.T) {
	if limaPatches != "lima-7" {
		t.Errorf("patch level %q", limaPatches)
	}
}

// A program not stamped with Lima's version gets the one its tree is made
// from, not "<unknown>".
func TestLimaVersionDefault(t *testing.T) {
	saved := limaversion.Version
	t.Cleanup(func() { limaversion.Version = saved })
	limaversion.Version = "<unknown>"
	if _, err := NewLima(t.TempDir(), "", t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if limaversion.Version != limaversion.AgentVMUpstream || limaversion.Version == "<unknown>" {
		t.Errorf("version %q", limaversion.Version)
	}
	limaversion.Version = "v9.9.9"
	if _, err := NewLima(t.TempDir(), "", t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if limaversion.Version != "v9.9.9" {
		t.Errorf("a stamped version replaced: %q", limaversion.Version)
	}
}

// The user's own LIMA_HOME is what NewLima found, not the one it sets.
func TestUserLimaHome(t *testing.T) {
	oldSet, oldUser := limaHomeSet, userLimaHome
	t.Cleanup(func() { limaHomeSet, userLimaHome = oldSet, oldUser })
	limaHomeSet, userLimaHome = "", ""
	user := t.TempDir()
	t.Setenv("LIMA_HOME", user)
	if got := UserLimaHome(); got != user {
		t.Errorf("before NewLima: %q", got)
	}
	ours := t.TempDir()
	if _, err := NewLima(ours, "", t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if got := UserLimaHome(); got != user {
		t.Errorf("after NewLima: %q, want %q", got, user)
	}
	// A second one, as tests and migrations make, keeps it.
	if _, err := NewLima(ours, "", t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if got := UserLimaHome(); got != user {
		t.Errorf("after two: %q, want %q", got, user)
	}

	limaHomeSet, userLimaHome = "", ""
	os.Unsetenv("LIMA_HOME")
	if _, err := NewLima(ours, "", t.TempDir()); err != nil {
		t.Fatal(err)
	}
	if got := UserLimaHome(); got != "" {
		t.Errorf("unset: %q", got)
	}
}

// Edits at once each write a whole lima.yaml, and leave nothing behind.
func TestLimaEditConcurrent(t *testing.T) {
	ctx := context.Background()
	l := newTestLima(t)
	none := []Mount{}
	if err := l.Create(ctx, "p-12345678", "template:debian-13", Settings{Mounts: &none}, io.Discard); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for i := 1; i <= 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := l.Edit(ctx, "p-12345678", Settings{CPUs: i}); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	p, err := l.Get(ctx, "p-12345678")
	if err != nil || p.Status == Broken {
		t.Fatalf("after: %v %+v", err, p)
	}
	ents, _ := os.ReadDir(p.Dir)
	for _, e := range ents {
		if strings.HasSuffix(e.Name(), ".tmp") {
			t.Errorf("left behind: %s", e.Name())
		}
	}
}
