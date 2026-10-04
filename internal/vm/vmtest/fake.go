// Package vmtest is a vm.Backend for tests: VMs in memory, every call
// recorded.
package vmtest

import (
	"context"
	"fmt"
	"io"
	"sort"
	"strings"
	"sync"

	"github.com/sylvinus/agent-vm/internal/vm"
)

// Fake keeps its VMs in memory.
type Fake struct {
	mu    sync.Mutex
	VMs   map[string]*vm.Instance
	Calls []string
	// Err, when set, is what every call returns.
	Err error
	// FailOn is what the calls of an operation return ("clone", "edit"...).
	FailOn map[string]error
	// Sticky VMs survive Delete, and stay running after Stop.
	Sticky map[string]bool
	// Shell answers Shell calls; exit status 0 when nil.
	ShellFunc func(name string, o vm.ShellOpts) int
}

// get is a copy of the VM name.
func (f *Fake) get(name string) (*vm.Instance, error) {
	v, ok := f.VMs[name]
	if !ok {
		return nil, fmt.Errorf("%w: %s", vm.ErrNotFound, name)
	}
	c := *v
	c.Mounts = append([]vm.Mount(nil), v.Mounts...)
	return &c, nil
}

// New is a Fake holding vms.
func New(vms ...*vm.Instance) *Fake {
	f := &Fake{VMs: map[string]*vm.Instance{}, Sticky: map[string]bool{}}
	for _, v := range vms {
		f.VMs[v.Name] = v
	}
	return f
}

func (f *Fake) call(format string, a ...any) error {
	c := fmt.Sprintf(format, a...)
	f.Calls = append(f.Calls, c)
	op, _, _ := strings.Cut(c, " ")
	if err := f.FailOn[op]; err != nil {
		return err
	}
	return f.Err
}

// CallLog is the calls, one per line.
func (f *Fake) CallLog() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return strings.Join(f.Calls, "\n")
}

func (f *Fake) List(context.Context) ([]*vm.Instance, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.Err != nil {
		return nil, f.Err
	}
	var out []*vm.Instance
	for name := range f.VMs {
		c, _ := f.get(name)
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

func (f *Fake) Get(_ context.Context, name string) (*vm.Instance, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.Err != nil {
		return nil, f.Err
	}
	return f.get(name)
}

func (f *Fake) Create(_ context.Context, name, template string, s vm.Settings, _ io.Writer) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.call("create %s %s", name, template); err != nil {
		return err
	}
	f.VMs[name] = &vm.Instance{Name: name, Status: vm.Stopped}
	apply(f.VMs[name], s)
	return nil
}

func (f *Fake) Clone(_ context.Context, from, to string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.call("clone %s %s", from, to); err != nil {
		return err
	}
	src, ok := f.VMs[from]
	if !ok {
		return fmt.Errorf("%w: %s", vm.ErrNotFound, from)
	}
	c := *src
	c.Name, c.Status = to, vm.Stopped
	f.VMs[to] = &c
	return nil
}

func (f *Fake) Edit(_ context.Context, name string, s vm.Settings) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.call("edit %s", name); err != nil {
		return err
	}
	v, ok := f.VMs[name]
	if !ok {
		return fmt.Errorf("%w: %s", vm.ErrNotFound, name)
	}
	if v.Status == vm.Running {
		return fmt.Errorf("cannot edit the running VM %s", name)
	}
	apply(v, s)
	return nil
}

func apply(v *vm.Instance, s vm.Settings) {
	if s.CPUs > 0 {
		v.CPUs = s.CPUs
	}
	if s.MemoryGiB > 0 {
		v.Memory = int64(s.MemoryGiB) << 30
	}
	if s.DiskGiB > 0 {
		v.Disk = int64(s.DiskGiB) << 30
	}
	if s.SSHLocalPort != nil {
		v.SSHLocalPort = *s.SSHLocalPort
		v.SSHPortConfig = *s.SSHLocalPort
	}
	if s.MountType != nil {
		v.MountType = *s.MountType
	}
	if s.Mounts != nil {
		v.Mounts = append([]vm.Mount(nil), (*s.Mounts)...)
	}
}

func (f *Fake) Start(_ context.Context, name string, _ io.Writer) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.call("start %s", name); err != nil {
		return err
	}
	if v, ok := f.VMs[name]; ok {
		// What Lima's Start refuses, likewise.
		if c, _ := f.get(name); vm.Confined(c) != nil {
			return vm.Confined(c)
		}
		v.Status = vm.Running
	}
	return nil
}

func (f *Fake) Stop(_ context.Context, name string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.call("stop %s", name); err != nil {
		return err
	}
	if v, ok := f.VMs[name]; ok && !f.Sticky[name] {
		v.Status = vm.Stopped
	}
	return nil
}

func (f *Fake) Delete(_ context.Context, name string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.call("delete %s", name); err != nil {
		return err
	}
	if !f.Sticky[name] {
		delete(f.VMs, name)
	}
	return nil
}

func (f *Fake) Shell(_ context.Context, name string, o vm.ShellOpts) (int, error) {
	f.mu.Lock()
	if err := f.call("shell %s %s", name, strings.Join(o.Args, " ")); err != nil {
		f.mu.Unlock()
		return 0, err
	}
	fn := f.ShellFunc
	f.mu.Unlock()
	if fn == nil {
		return 0, nil
	}
	return fn(name, o), nil
}
