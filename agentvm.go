// Package agentvm runs AI coding agents, or any program, in a disposable Linux
// VM per project: the project's folder is shared with the VM, nothing else of
// the host is, and the VM reaches the internet but not the host's network.
// It is the engine of the agent-vm command (cmd/agent-vm), as a library.
//
// A program that embeds it:
//
//	func main() {
//		agentvm.RunHelper() // Lima's hostagent starts this executable again
//		e, err := agentvm.Open(agentvm.Options{StateDir: "~/.mytool", AppName: "mytool", Assets: assets})
//		...
//		e.Setup(ctx, myTemplate, nil)         // once: builds the base VM
//		vm, _ := e.ProjectVM(dir)             // the VM of a project folder
//		vm.Ensure(ctx, agentvm.Spec{})        // exists, runs, shares the folder
//		vm.Exec(ctx, agentvm.Exec{Args: []string{"mytool-agent"}})
//	}
//
// What it needs of the build: on macOS, cgo, and the binary signed with the
// entitlements in third_party/lima/vz.entitlements; and the guest agent and
// Lima's templates, made by `go run github.com/sylvinus/agent-vm/cmd/agent-vm-assets
// -o assets/` and embedded by the program, given as Options.Assets.
//
// The one-engine-per-process rule: Lima's home is an environment variable
// and its logging is global, so a process opens one Engine. The library
// installs no signal handler and writes nothing to standard output: what it
// tells goes to Options.OnEvent.
//
// This package is experimental until a program other than agent-vm has used
// it: v0.x, and its API may change.
package agentvm

import (
	"errors"
	"os"

	"github.com/sylvinus/agent-vm/internal/engine"
	"github.com/sylvinus/agent-vm/internal/limaembed"
)

// The engine, its handles and what they take and tell.
type (
	// Engine runs the VMs of one state folder.
	Engine = engine.Engine
	// Options configure an Engine; StateDir is the only one required.
	Options = engine.Options
	// VM is the VM of a project folder.
	VM = engine.VM
	// Spec says how a VM is wanted.
	Spec = engine.Spec
	// Exec is a command to run in a VM.
	Exec = engine.Exec
	// Details are what is known of a VM.
	Details = engine.Details

	// Event is what the engine tells; Level its kind.
	Event = engine.Event
	Level = engine.Level
	// Asker answers the questions of the engine, Question one of them.
	Asker        = engine.Asker
	Question     = engine.Question
	QuestionKind = engine.QuestionKind
	// NoAsker answers no to everything.
	NoAsker = engine.NoAsker

	// Output shows what the steps of Setup print; SetupError is why Setup
	// stopped.
	Output     = engine.Output
	SetupError = engine.SetupError

	// Failure and RefusedError are the errors of a start that stopped.
	Failure      = engine.Failure
	RefusedError = engine.RefusedError
)

// Event levels.
const (
	Info    = engine.Info
	Warning = engine.Warning
	Error   = engine.Error
)

// Questions the engine asks.
const (
	QHooks      = engine.QHooks
	QUnsafe     = engine.QUnsafe
	QBareRepo   = engine.QBareRepo
	QRestart    = engine.QRestart
	QStopToMove = engine.QStopToMove
)

// DefaultBase is the name of the template Setup makes and VMs are cloned
// from, unless another is named.
const DefaultBase = engine.DefaultBase

// What a call fails on, for errors.Is.
var (
	ErrBaseMissing    = engine.ErrBaseMissing
	ErrBaseIncomplete = engine.ErrBaseIncomplete
	ErrBaseOld        = engine.ErrBaseOld
	ErrAborted        = engine.ErrAborted
	ErrNotApplied     = engine.ErrNotApplied
	ErrRefused        = engine.ErrRefused
	ErrFailed         = engine.ErrFailed
	ErrNameTooLong    = engine.ErrNameTooLong
	ErrLimaOverrides  = engine.ErrLimaOverrides
	ErrUnconfined     = engine.ErrUnconfined
	ErrNotFound       = engine.ErrNotFound
	// ErrNoAssets: no guest agent was given (Options.Assets).
	ErrNoAssets = limaembed.ErrNoAssets
)

// RunHelper must run first in main, before anything else is done. Lima starts
// the current executable again as the host agent of each VM, with arguments of
// its own: RunHelper recognises them, runs the host agent and exits. In any
// other run it returns at once.
//
// On macOS, the host agent needs the main goroutine on the process's first
// thread: put runtime.LockOSThread() in an init function of the main package
// (see cmd/agent-vm/main_darwin_gui.go).
func RunHelper() {
	limaembed.Run(os.Args[1:])
}

// Open makes an Engine. It fails, saying why, when RunHelper was not called
// (and Options.Backend, for tests, is not set): the first VM would otherwise
// start a second copy of the program as its host agent that runs the
// program's own main.
func Open(opts Options) (*Engine, error) {
	if opts.Backend == nil && !limaembed.Called() {
		return nil, errors.New("agentvm: call agentvm.RunHelper() first in main: Lima starts this executable again as each VM's host agent")
	}
	return engine.Open(opts)
}
