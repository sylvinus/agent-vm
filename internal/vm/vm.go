// Package vm is what agent-vm asks of what runs its VMs. Lima does it
// (lima.go); the interface keeps the rest of agent-vm apart from it, so tests
// use a fake, and another backend could take Lima's place.
package vm

import (
	"context"
	"errors"
	"io"
)

// ErrNotFound is returned for a VM that does not exist.
var ErrNotFound = errors.New("no such VM")

// ErrNameTooLong is returned for a VM name the backend cannot have here:
// the paths of its sockets would be too long.
var ErrNameTooLong = errors.New("VM name too long")

// ErrUnmountable is returned by Edit for a share the backend would read as
// another path than the one given.
var ErrUnmountable = errors.New("a share the backend cannot take as written")

// ErrLimaOverrides is returned while the backend's own config would add to
// what agent-vm sets for every VM (Lima's _config/default.yaml and
// override.yaml).
var ErrLimaOverrides = errors.New("agent-vm does not use Lima's default.yaml or override.yaml; move it out of the way")

// ErrUnconfined is returned by Start for a VM with a share the VM could
// reach the rest of the host through (see Confined).
var ErrUnconfined = errors.New("agent-vm starts no VM with a share not confined to its folder")

// Status of a VM.
type Status string

const (
	Running Status = "Running"
	Stopped Status = "Stopped"
	// Broken: the backend cannot tell, or the VM is half there.
	Broken Status = "Broken"
)

// Instance is a VM as the backend has it.
type Instance struct {
	Name         string
	Status       Status
	Dir          string // the backend's folder for it
	CPUs         int
	Memory, Disk int64 // bytes
	SSHLocalPort int   // the port in use
	// SSHPortConfig is the port the config fixes, 0 when the backend
	// picks one on each start.
	SSHPortConfig int
	SSHAddress    string
	// SSHConfig is the ssh_config file the backend rewrites on each start,
	// for tools that connect to the VM.
	SSHConfig    string
	VMType, Arch string
	// MountType is the backend's name for how the shares reach the guest,
	// empty for its default.
	MountType string
	Mounts    []Mount
	// ConfigErr is why the backend cannot read the VM's config (Broken).
	ConfigErr error
}

// Mount is a host folder shared with the guest.
type Mount struct {
	Location   string `json:"location"`             // on the host
	MountPoint string `json:"mountPoint,omitempty"` // in the guest; Location's spelling when empty
	Writable   bool   `json:"writable"`
	SSHFS      *SSHFS `json:"sshfs,omitempty"`
}

// SSHFS options of a reverse-sshfs share.
type SSHFS struct {
	SFTPDriver string `json:"sftpDriver,omitempty"`
	// Cache is sshfs's own; nil for the backend's default.
	Cache *bool `json:"cache,omitempty"`
	// ReadonlyNames are read-only at any depth under the share, whatever
	// the guest does: .git and the like.
	ReadonlyNames []string `json:"readonlyNames,omitempty"`
}

// ReverseSSHFS is the mount type whose shares the host serves over SFTP,
// which is where readonlyNames are enforced.
const ReverseSSHFS = "reverse-sshfs"

// Settings change a VM. A zero field is left as it is.
type Settings struct {
	CPUs         int
	MemoryGiB    int
	DiskGiB      int
	SSHLocalPort *int // 0 gives the port back to the backend
	Mounts       *[]Mount
	MountType    *string // "" goes back to the backend's default
	// NoContainerd leaves out the backend's own containerd: Docker, when
	// installed, ships its own.
	NoContainerd bool
}

// ShellOpts is a command run in a running VM.
type ShellOpts struct {
	// Workdir is where the command runs; it fails when it cannot cd there.
	Workdir string
	// Args is the command, run by the user's login shell; empty for the
	// shell itself.
	Args           []string
	Stdin          io.Reader
	Stdout, Stderr io.Writer
	// Interactive asks for a terminal in the guest, as a full-screen
	// program needs, when stdin is one. Stdout on a terminal gets one
	// anyway.
	Interactive bool
}

// Backend runs VMs.
type Backend interface {
	// List is every VM, in name order.
	List(ctx context.Context) ([]*Instance, error)
	// Get is one VM, or ErrNotFound.
	Get(ctx context.Context, name string) (*Instance, error)
	// Create makes a VM from a template, with settings, and does not start it.
	// log gets the backend's progress.
	Create(ctx context.Context, name, template string, s Settings, log io.Writer) error
	// Clone copies the stopped VM from as to, stopped.
	Clone(ctx context.Context, from, to string) error
	// Edit changes the stopped VM name.
	Edit(ctx context.Context, name string, s Settings) error
	// Start boots the stopped VM name, and returns once it is ready. log
	// gets the backend's progress. It refuses a VM whose shares are not
	// confined to their folders (see Confined).
	Start(ctx context.Context, name string, log io.Writer) error
	// Stop shuts down the running VM name.
	Stop(ctx context.Context, name string) error
	// Delete removes the VM name, running or not.
	Delete(ctx context.Context, name string) error
	// Shell runs a command in the running VM name, and returns its exit
	// status.
	Shell(ctx context.Context, name string, o ShellOpts) (int, error)
}
