package engine

// Spec says how a VM is wanted. Zero values leave things as they are.
type Spec struct {
	// Base is the template the VM is cloned from; "base" when empty. Made
	// by Setup.
	Base string
	// CPUs, MemoryGiB and DiskGiB are the resources asked for, 0 for none.
	// CPUs and memory are capped to the host's share (Options.HostShare);
	// the disk can only grow.
	CPUs, MemoryGiB, DiskGiB int
	// SSHPort, when set, fixes the VM's SSH port; 0 gives it back to Lima.
	SSHPort *int
	// Reset deletes the VM first, and makes it again from the base.
	Reset bool
	// ReadOnly shares nothing writable with the VM: the project and every
	// other share are read-only on the host.
	ReadOnly bool
	// NoShares makes a VM that shares nothing: no project, no volumes. Only
	// the shared env goes in, and the project's folder is made in the VM as
	// an empty working folder, at the same path. For a named VM (NamedVM) it
	// is said when the VM is made, and implied after: the VM never gets
	// shares. A scratch VM (NewScratchVM) shares nothing whatever this says.
	NoShares bool
	// UnsafeWritableGit leaves every .git writable for the VM, which lets it
	// run commands on the host through git's config and hooks.
	UnsafeWritableGit bool
	// UnsafeNoPrompts, when it holds text, turns the security questions
	// off: each is answered yes, with a notice naming this text (what asked
	// for it).
	UnsafeNoPrompts string
}

// templateName is the base the spec names.
func (s Spec) templateName() string {
	if s.Base == "" {
		return DefaultBase
	}
	return s.Base
}

// DefaultBase is the name of the template Setup makes and VMs are cloned
// from, unless another is named.
const DefaultBase = "base"

// Building is the name of the VM Setup builds a template in before swapping
// it in for the template.
func Building(template string) string { return template + "-building" }
