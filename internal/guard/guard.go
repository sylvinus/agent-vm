// Package guard asks the user before the VM changes a file their machine runs
// on its own (direnv's .envrc when they enter the folder, the editor's tasks,
// git hooks' config): the shares' SFTP server calls Allow before each write
// (sshocker's Guard), in the hostagent. Files the agent edits as a matter of
// course (Makefile, package.json) are guarded only when the user lists them.
package guard

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"path"
	"strings"
	"sync"
	"time"

	"github.com/sylvinus/agent-vm/internal/desktop"
)

// FileName is the list's file in agent-vm's state folder: one path a line,
// added to Defaults; "!path" removes one.
const FileName = "guarded"

// Defaults are guarded unless the user removes them, each with what runs it.
var Defaults = map[string]string{
	".envrc":                  "direnv runs it when you enter the folder.",
	".vscode/tasks.json":      "VS Code can run its tasks when the folder opens.",
	".vscode/settings.json":   "VS Code reads commands from it (terminal profiles, tools to run).",
	".vscode/launch.json":     "VS Code runs it when you debug.",
	".pre-commit-config.yaml": "pre-commit runs its hooks on your commits.",
	"lefthook.yml":            "lefthook runs its hooks on your commits.",
	".lefthook.yml":           "lefthook runs its hooks on your commits.",
	"mise.toml":               "mise runs its hooks when you enter the folder.",
	".mise.toml":              "mise runs its hooks when you enter the folder.",
}

// deniedFor is how long a refusal holds before the user is asked again: a
// program retrying a write does not get a dialog each time.
const deniedFor = time.Minute

// answerWithin is how long a dialog waits: past it, the write is refused.
const answerWithin = 2 * time.Minute

// Guard asks about the writes to guarded paths.
type Guard struct {
	// VM is named in the question.
	VM string
	// Paths, relative, matched against the end of a written path, case
	// ignored: each with why it matters ("" for one the user added).
	Paths map[string]string
	// Ask shows the question and returns the answer (desktop.Ask). ok false
	// when no one could be asked.
	Ask func(ctx context.Context, title, msg string) (allow, ok bool)
	// Tell says something without waiting (a refusal no one was asked).
	Tell func(title, msg string)

	mu      sync.Mutex // one question at a time
	allowed map[string]bool
	denied  map[string]time.Time
}

// Load is the guard of the VM vm: Defaults and the user's list.
func Load(stateDir, vm string) (*Guard, error) {
	g := &Guard{VM: vm, Paths: map[string]string{}, Ask: desktop.Ask, Tell: desktop.Notify}
	// No one to ask (a server, CI): refused without a dialog.
	if os.Getenv("AGENT_VM_GUARDED_WRITES") == "deny" {
		g.Ask = func(context.Context, string, string) (bool, bool) { return false, true }
	}
	for p, why := range Defaults {
		g.Paths[p] = why
	}
	f, err := os.Open(stateDir + "/" + FileName)
	if errors.Is(err, os.ErrNotExist) {
		return g, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line, _, _ := strings.Cut(sc.Text(), "#")
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if p, ok := strings.CutPrefix(line, "!"); ok {
			delete(g.Paths, clean(p))
			continue
		}
		if _, ok := g.Paths[clean(line)]; !ok {
			g.Paths[clean(line)] = ""
		}
	}
	return g, sc.Err()
}

func clean(p string) string { return strings.Trim(path.Clean("/"+strings.TrimSpace(p)), "/") }

// match is the guarded path rel ends with, if any.
func (g *Guard) match(rel string) (string, bool) {
	rel = strings.ToLower(rel)
	for p := range g.Paths {
		lp := strings.ToLower(p)
		if rel == lp || strings.HasSuffix(rel, "/"+lp) {
			return p, true
		}
	}
	return "", false
}

// Allow reports whether the VM may write rel, under the share root: yes
// unless rel is guarded and the user says no, or cannot be asked.
func (g *Guard) Allow(root, rel string) bool {
	p, ok := g.match(rel)
	if !ok {
		return true
	}
	key := root + "/" + rel
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.allowed[key] {
		return true
	}
	if until, ok := g.denied[key]; ok && time.Now().Before(until) {
		return false
	}
	why := g.Paths[p]
	if why == "" {
		why = "You asked agent-vm to guard it (~/.agent-vm/" + FileName + ")."
	}
	title := "agent-vm: " + g.VM
	msg := fmt.Sprintf("The VM wants to change %s in %s.\n\n%s\n\nAllow it? (Until the VM stops.)", rel, root, why)
	ctx, cancel := context.WithTimeout(context.Background(), answerWithin)
	defer cancel()
	allow, asked := g.Ask(ctx, title, msg)
	if !asked && g.Tell != nil {
		g.Tell(title, fmt.Sprintf("Refused: the VM wanted to change %s in %s, and no dialog could ask you.", rel, root))
	}
	if allow {
		if g.allowed == nil {
			g.allowed = map[string]bool{}
		}
		g.allowed[key] = true
		return true
	}
	if g.denied == nil {
		g.denied = map[string]time.Time{}
	}
	g.denied[key] = time.Now().Add(deniedFor)
	return false
}
