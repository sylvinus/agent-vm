package engine

import (
	"errors"

	"github.com/sylvinus/agent-vm/internal/vm"
)

// What a call can fail on, for errors.Is. Each comes with the Event that says
// it in full.
var (
	// ErrBaseMissing: the base template does not exist; set it up first.
	ErrBaseMissing = errors.New("base VM not found")
	// ErrBaseIncomplete: the base exists but its setup did not complete.
	ErrBaseIncomplete = errors.New("base VM setup did not complete")
	// ErrBaseOld: the VM, or the base, comes from agent-vm 0.1.0, without
	// the sshfs its shares need.
	ErrBaseOld = errors.New("base built by agent-vm 0.1.0, without sshfs")
	// ErrAborted: the user said no to a security question, or no one could
	// be asked and the safe answer is no.
	ErrAborted = errors.New("aborted")
	// ErrNotApplied: a restart or a change the VM needs was not agreed.
	ErrNotApplied = errors.New("a change was not applied")
	// ErrRefused: a project or a share the engine does not give to a VM.
	// The error is a *RefusedError.
	ErrRefused = errors.New("refused")
	// ErrFailed: the VM could not be made, configured, started or reached.
	ErrFailed = errors.New("failed")

	// ErrNameTooLong, ErrLimaOverrides and ErrUnconfined are the backend's.
	ErrNameTooLong   = vm.ErrNameTooLong
	ErrLimaOverrides = vm.ErrLimaOverrides
	ErrUnconfined    = vm.ErrUnconfined
	// ErrNotFound: no such VM.
	ErrNotFound = vm.ErrNotFound
)

// Failure is the error of a call that stopped: its kind (one of the Err
// values above, for errors.Is) and the text the Error event said.
type Failure struct {
	Kind error
	Text string
}

func (f *Failure) Error() string { return f.Text }
func (f *Failure) Unwrap() error { return f.Kind }

// RefusedError is returned when the engine does not give a folder to a VM:
// the project is the user's home, holds credentials, or agent-vm itself.
type RefusedError struct {
	// Dir is what was refused, Why the reason ("is your home directory").
	Dir, Why string
	Text     string
}

func (r *RefusedError) Error() string { return r.Text }
func (r *RefusedError) Unwrap() error { return ErrRefused }
