package engine

import (
	"context"
	"io"
	"strings"
)

// Level of an Event.
type Level int

const (
	// Info is progress: what is being done ("Starting VM 'x'...").
	Info Level = iota
	// Warning is something to know, that does not stop what is being done,
	// or what the user must know before a question.
	Warning
	// Error is why a start cannot go on. The call returns an error too.
	Error
)

// Event is something the engine tells the program that drives it: progress,
// warnings, errors. The text is for people, in English, and complete (a
// "Warning: " or "Error: " prefix included, no trailing newline). Nothing is
// ever written to a terminal by the engine itself.
type Event struct {
	Level Level
	// VM is the VM the event is about, "" for none.
	VM string
	// Title, when set, makes the event a boxed notice: Text is its body.
	Title string
	Text  string
}

// QuestionKind says what an engine asks.
type QuestionKind int

const (
	// QHooks: git runs hooks from a folder of a share whose name is not
	// protected by default; make every folder of that name in the project
	// read-only for the VM? Default yes.
	QHooks QuestionKind = iota
	// QUnsafe: a risk to the host was warned of, go on anyway? Default no.
	QUnsafe
	// QBareRepo: set git's safe.bareRepository to explicit in the user's
	// global git config? Default yes.
	QBareRepo
	// QRestart: the running VM must be stopped to apply a change; sessions
	// using it are cut. The Prompt says which.
	QRestart
	// QStopToMove: the running VMs of an older layout must be stopped to be
	// moved. Default yes.
	QStopToMove
)

// Question is something the engine cannot decide: what the user is asked.
type Question struct {
	Kind QuestionKind
	VM   string
	// Title and Detail, when set, are shown before the question (a boxed
	// notice).
	Title, Detail string
	// Prompt is the question itself, ending with "?".
	Prompt string
	// Default is the answer when the user gives none.
	Default bool
}

// Asker answers the engine's questions. An engine with no Asker, or whose
// Asker cannot ask, takes every answer as no: as for a program with no
// terminal.
type Asker interface {
	// CanAsk reports whether a question can be asked and seen now. Some
	// questions are not asked, and a safe answer taken, when it cannot.
	CanAsk() bool
	// Ask asks, and returns the answer.
	Ask(ctx context.Context, q Question) bool
}

// NoAsker answers no to everything and cannot be asked.
type NoAsker struct{}

func (NoAsker) CanAsk() bool                       { return false }
func (NoAsker) Ask(context.Context, Question) bool { return false }

// eventWriter is an io.Writer that turns each line written into an Event of
// its level, for the helpers that report to a writer.
type eventWriter struct {
	e     *Engine
	level Level
	vm    string
	rest  string
}

func (w *eventWriter) Write(p []byte) (int, error) {
	w.rest += string(p)
	for {
		i := strings.IndexByte(w.rest, '\n')
		if i < 0 {
			break
		}
		w.e.emit(Event{Level: w.level, VM: w.vm, Text: w.rest[:i]})
		w.rest = w.rest[i+1:]
	}
	return len(p), nil
}

var _ io.Writer = (*eventWriter)(nil)

// writer is an io.Writer for the events of level.
func (e *Engine) writer(level Level, vm string) io.Writer {
	return &eventWriter{e: e, level: level, vm: vm}
}
