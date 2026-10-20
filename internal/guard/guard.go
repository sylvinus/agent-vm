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
	"io"
	"io/fs"
	"os"
	"path"
	"runtime"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/sylvinus/agent-vm/internal/desktop"
	"github.com/sylvinus/agent-vm/third_party/sshocker/pkg/reversesshfs"
)

// FileName is the list's file in agent-vm's state folder: one path a line,
// added to Defaults; "!path" removes one.
const FileName = "guarded"

// Defaults are guarded unless the user removes them, each with what runs it.
// A path naming a folder guards everything in it.
var Defaults = map[string]string{
	".envrc": "direnv runs it when you enter the folder.",

	".vscode/tasks.json":    "VS Code can run its tasks when the folder opens.",
	".vscode/settings.json": "VS Code reads commands from it (terminal profiles, tools to run).",
	".vscode/launch.json":   "VS Code runs it when you debug.",
	".vscode/mcp.json":      "VS Code starts the MCP servers it lists.",

	".devcontainer/devcontainer.json": "VS Code runs its initializeCommand on your machine when you reopen the folder in a container.",
	".devcontainer.json":              "VS Code runs its initializeCommand on your machine when you reopen the folder in a container.",

	".idea/runConfigurations": "JetBrains IDEs run these configurations on your machine.",
	".idea/watchers.xml":      "JetBrains IDEs run its file watchers on your machine each time you save.",
	".zed/settings.json":      "Zed starts the language servers it names.",
	".zed/tasks.json":         "Zed runs its tasks.",
	".dir-locals.el":          "Emacs applies its settings, which can evaluate code, when you open a file.",

	".claude/settings.json":       "Claude Code runs the hooks it lists on your machine.",
	".claude/settings.local.json": "Claude Code runs the hooks it lists on your machine.",
	".mcp.json":                   "Claude Code starts the MCP servers it lists.",
	".cursor/mcp.json":            "Cursor starts the MCP servers it lists.",
	".cursor/hooks.json":          "Cursor runs the hooks it lists on your machine.",
	".codex/config.toml":          "Codex starts the MCP servers and programs it lists.",
	".gemini/settings.json":       "Gemini CLI starts the MCP servers and hooks it lists.",

	".pre-commit-config.yaml": "pre-commit runs its hooks on your commits.",
	"lefthook.yml":            "lefthook runs its hooks on your commits.",
	".lefthook.yml":           "lefthook runs its hooks on your commits.",
	"lefthook.yaml":           "lefthook runs its hooks on your commits.",
	".lefthook.yaml":          "lefthook runs its hooks on your commits.",
	"lefthook-local.yml":      "lefthook runs its hooks on your commits.",
	".lefthook-local.yml":     "lefthook runs its hooks on your commits.",
	".husky":                  "Git runs these hooks on your commits.",
	".githooks":               "Git runs these hooks on your commits when core.hooksPath points here.",

	"mise.toml":          "mise runs its hooks and tasks when you enter the folder.",
	".mise.toml":         "mise runs its hooks and tasks when you enter the folder.",
	"mise.local.toml":    "mise runs its hooks and tasks when you enter the folder.",
	".mise.local.toml":   "mise runs its hooks and tasks when you enter the folder.",
	".mise":              "mise runs its config and tasks when you enter the folder.",
	".config/mise.toml":  "mise runs its hooks and tasks when you enter the folder.",
	".config/mise":       "mise runs its config and tasks when you enter the folder.",
	".yarnrc.yml":        "yarn runs the program its yarnPath and plugins name.",
	".yarn/releases":     "yarn runs these files.",
	".yarn/plugins":      "yarn runs these files.",
	".pnpmfile.cjs":      "pnpm runs it when you install.",
	".npmrc":             "npm can run the program its script-shell or git settings name.",
	".cargo/config.toml": "cargo can run the program its runner and wrapper settings name.",
	".cargo/config":      "cargo can run the program its runner and wrapper settings name.",
	".lfsconfig":         "git-lfs sends your files and credentials to the server it names.",
}

// WindowsDefaults are guarded as well on a Windows host, where Explorer
// contacts the server a file names when it shows the file, and sends your
// NTLM hash (CVE-2025-24054 for .library-ms, CVE-2025-50154 and
// CVE-2025-59214 for .lnk, CVE-2024-43451 for .url). "*.ext" is any file
// with that extension.
var WindowsDefaults = map[string]string{
	"*.library-ms":         "Explorer contacts the server it names when it shows it, and sends your NTLM hash.",
	"*.searchConnector-ms": "Explorer contacts the server it names when it shows it, and sends your NTLM hash.",
	"*.lnk":                "Explorer can contact the server its icon names when it shows it, and send your NTLM hash.",
	"*.url":                "Explorer can contact the server its icon names when it shows it, and send your NTLM hash.",
	"*.scf":                "Explorer contacts the server its icon names when it shows it, and sends your NTLM hash.",
	"desktop.ini":          "Explorer contacts the server it names when it shows the folder, and sends your NTLM hash.",
}

// deniedFor is how long a refusal holds before the user is asked again: a
// program retrying a write does not get a dialog each time.
const deniedFor = time.Minute

// answerWithin is how long a dialog waits: past it, the write is refused.
const answerWithin = 2 * time.Minute

// A VM that gets maxRefusals questions refused or unanswered within refusalWindow
// is not asked again for coolDown: it is refused at once.
const (
	maxRefusals   = 3
	refusalWindow = 5 * time.Minute
	coolDown      = 5 * time.Minute
)

// maxShown caps the part of a path the VM chose that a question shows.
const maxShown = 100

// maxScan caps the entries looked at in a folder that is moved or removed.
// A folder with more is asked about, as one that may hold a guarded path.
var maxScan = 20000

// Guard asks about the writes to guarded paths.
type Guard struct {
	// App names the program in the question; "agent-vm" when empty.
	App string
	// VM is named in the question.
	VM string
	// Paths, relative, matched anywhere in a written path as whole names,
	// compared as sshocker folds read-only names (case, normalization, ignorable
	// characters): each with why it matters ("" for one the user added).
	Paths map[string]string
	// Ask shows the question and returns the answer (desktop.Ask). ok false
	// when no one could be asked.
	Ask func(ctx context.Context, title, msg string) (allow, ok bool)
	// Tell says something without waiting (a refusal no one was asked).
	Tell func(title, msg string)

	rulesOnce sync.Once
	rules     []rule

	askMu     sync.Mutex // one question at a time
	mu        sync.Mutex // protects what follows
	allowed   map[string]bool
	denied    map[string]time.Time
	refusals  []time.Time
	coolUntil time.Time
	now       func() time.Time // time.Now when nil
}

// rule is a guarded path, as its folded components, or with ext, a guarded
// extension ("*.lnk": any file whose name ends so).
type rule struct {
	path  string
	comps []string
	ext   string
}

// Config is what a Guard is made of: the policy file of a VM holds it.
type Config struct {
	// Paths are the guarded paths, see Guard.Paths.
	Paths map[string]string `json:"paths"`
	// Deny refuses what is guarded without a dialog: no one to ask (a
	// server, CI).
	Deny bool `json:"deny,omitempty"`
}

// DefaultConfig guards Defaults, and WindowsDefaults on a Windows host.
func DefaultConfig() Config {
	c := Config{Paths: map[string]string{}}
	for p, why := range Defaults {
		c.Paths[p] = why
	}
	if windowsHost {
		for p, why := range WindowsDefaults {
			c.Paths[p] = why
		}
	}
	return c
}

// LoadConfig is Defaults with the user's list on top, and
// AGENT_VM_GUARDED_WRITES.
func LoadConfig(stateDir string) (Config, error) {
	c := DefaultConfig()
	c.Deny = os.Getenv("AGENT_VM_GUARDED_WRITES") == "deny"
	f, err := os.Open(stateDir + "/" + FileName)
	if errors.Is(err, os.ErrNotExist) {
		return c, nil
	}
	if err != nil {
		return Config{}, err
	}
	defer f.Close()
	return c, c.ParseList(f)
}

// ParseList adds the lines of a guarded file to c: one path a line, "!path"
// removes one of the paths already there.
func (c *Config) ParseList(r io.Reader) error {
	if c.Paths == nil {
		c.Paths = map[string]string{}
	}
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line, _, _ := strings.Cut(sc.Text(), "#")
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if p, ok := strings.CutPrefix(line, "!"); ok {
			for k := range c.Paths {
				if strings.EqualFold(k, clean(p)) {
					delete(c.Paths, k)
				}
			}
			continue
		}
		if _, ok := c.Paths[clean(line)]; !ok {
			c.Paths[clean(line)] = ""
		}
	}
	return sc.Err()
}

// New is the guard of the VM vm for c.
func New(c Config, vm string) *Guard {
	g := &Guard{VM: vm, Paths: c.Paths, Ask: desktop.Ask, Tell: desktop.Notify}
	if g.Paths == nil {
		g.Paths = map[string]string{}
	}
	if c.Deny {
		g.Ask = func(context.Context, string, string) (bool, bool) { return false, true }
	}
	return g
}

// Load is the guard of the VM vm: Defaults and the user's list.
func Load(stateDir, vm string) (*Guard, error) {
	c, err := LoadConfig(stateDir)
	if err != nil {
		return nil, err
	}
	return New(c, vm), nil
}

func clean(p string) string { return strings.Trim(path.Clean("/"+strings.TrimSpace(p)), "/") }

// windowsHost is whether the host is Windows, where a name stands for the file
// it is made into: "a.lnk." and "a.lnk " are "a.lnk", and "a.lnk:s" makes it.
var windowsHost = runtime.GOOS == "windows"

func foldAll(p string) []string {
	comps := strings.Split(p, "/")
	for i, c := range comps {
		if windowsHost {
			c, _, _ = strings.Cut(c, ":")
			c = strings.TrimRight(c, ". ")
		}
		comps[i] = reversesshfs.FoldName(c)
	}
	return comps
}

func (g *Guard) loadRules() []rule {
	g.rulesOnce.Do(func() {
		for p := range g.Paths {
			if ext, ok := strings.CutPrefix(p, "*."); ok && !strings.Contains(ext, "/") {
				g.rules = append(g.rules, rule{path: p, ext: foldAll("." + ext)[0]})
				continue
			}
			g.rules = append(g.rules, rule{path: p, comps: foldAll(p)})
		}
	})
	return g.rules
}

// hit is what makes a path guarded.
type hit struct {
	rule string // the guarded path
	kind kind
	key  string // what an answer holds for: the same key is not asked twice
}

type kind int

const (
	// The path is the guarded path, or is in the folder that is.
	kindPath kind = iota
	// The path is a folder that holds the guarded path: creating, moving or removing it matters.
	kindParent
	// The path is a folder that holds a guarded file, found by looking inside.
	kindInside
	// The path is a folder with too many entries to look for a guarded file in.
	kindTooBig
)

// match is the guarded path that rel is or is in, or with entry, that rel is a folder
// for (a name of the path's leading folders), or holds. Names are compared as a file
// system might: folded the way sshocker compares read-only names.
func (g *Guard) match(rel string, entry bool) (hit, bool) {
	comps := foldAll(rel)
	for _, r := range g.loadRules() {
		if r.ext != "" {
			if strings.HasSuffix(comps[len(comps)-1], r.ext) {
				return hit{r.path, kindPath, "p:" + strings.Join(comps, "/")}, true
			}
			continue
		}
		n := len(r.comps)
		for i := 0; i+n <= len(comps); i++ {
			if equal(comps[i:i+n], r.comps) {
				return hit{r.path, kindPath, "p:" + strings.Join(comps[:i+n], "/")}, true
			}
		}
	}
	if !entry {
		return hit{}, false
	}
	for _, r := range g.loadRules() {
		if r.ext != "" {
			continue
		}
		for k := min(len(r.comps)-1, len(comps)); k >= 1; k-- {
			if equal(comps[len(comps)-k:], r.comps[:k]) {
				return hit{r.path, kindParent, "d:" + strings.Join(comps, "/")}, true
			}
		}
	}
	return hit{}, false
}

func equal(a, b []string) bool {
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return len(a) == len(b)
}

// holds is a guarded path inside the folder rel of root, if rel is one and
// has one within maxScan entries; a folder with more is a hit of its own, as
// it may hold one. Nothing outside root is looked at.
func (g *Guard) holds(root, rel string) (hit, bool) {
	r, err := os.OpenRoot(root)
	if err != nil {
		return hit{}, false
	}
	defer r.Close()
	if fi, err := r.Lstat(rel); err != nil || !fi.IsDir() {
		return hit{}, false
	}
	var found hit
	seen := 0
	_ = fs.WalkDir(r.FS(), rel, func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == rel {
			return nil
		}
		if seen++; seen > maxScan {
			found = hit{fmt.Sprintf("a folder with more than %d entries", maxScan), kindTooBig, "b:" + strings.Join(foldAll(rel), "/")}
			return fs.SkipAll
		}
		if m, ok := g.match(p, false); ok {
			found = hit{m.rule, kindInside, "i:" + strings.Join(foldAll(rel), "/")}
			return fs.SkipAll
		}
		return nil
	})
	return found, found.rule != ""
}

// Allow reports whether the VM may write rel, under the share root: yes
// unless rel is guarded and the user says no, or cannot be asked. entry is
// sshocker's: rel is a name that is created, removed or moved, not a file
// whose content changes.
func (g *Guard) Allow(root, rel string, entry bool) bool {
	h, ok := g.match(rel, entry)
	if !ok && entry {
		h, ok = g.holds(root, rel)
	}
	if !ok {
		return true
	}
	key := root + "/" + h.key
	if allow, decided := g.decided(key); decided {
		return allow
	}
	g.askMu.Lock()
	defer g.askMu.Unlock()
	// Another share may have asked meanwhile.
	if allow, decided := g.decided(key); decided {
		return allow
	}

	app := g.App
	if app == "" {
		app = "agent-vm"
	}
	why := g.Paths[h.rule]
	if h.kind == kindTooBig {
		why = "It may hold a file " + app + " guards."
	} else if why == "" {
		why = "You asked " + app + " to guard it."
		if app == "agent-vm" {
			why = "You asked agent-vm to guard it (~/.agent-vm/" + FileName + ")."
		}
	}
	title := app + ": " + g.VM
	msg := question(root, rel, h, why)
	ctx, cancel := context.WithTimeout(context.Background(), answerWithin)
	defer cancel()
	allow, asked := g.Ask(ctx, title, msg)
	if !asked && g.Tell != nil {
		g.Tell(title, fmt.Sprintf("Refused: the VM wanted to change %s in %s, and no dialog could ask you.", h.rule, root))
	}

	g.mu.Lock()
	defer g.mu.Unlock()
	if allow {
		if g.allowed == nil {
			g.allowed = map[string]bool{}
		}
		g.allowed[key] = true
		return true
	}
	now := g.time()
	if g.denied == nil {
		g.denied = map[string]time.Time{}
	}
	g.denied[key] = now.Add(deniedFor)
	for len(g.refusals) > 0 && now.Sub(g.refusals[0]) > refusalWindow {
		g.refusals = g.refusals[1:]
	}
	g.refusals = append(g.refusals, now)
	if len(g.refusals) >= maxRefusals {
		g.coolUntil = now.Add(coolDown)
		g.refusals = nil
		if g.Tell != nil {
			g.Tell(title, fmt.Sprintf("The VM asked to change guarded files %d times and was refused: it is refused without asking for %d minutes.", maxRefusals, int(coolDown/time.Minute)))
		}
	}
	return false
}

func (g *Guard) time() time.Time {
	if g.now != nil {
		return g.now()
	}
	return time.Now()
}

// decided is the standing answer for key: allowed, refused for a while, or
// refused while the VM is cooling down.
func (g *Guard) decided(key string) (allow, ok bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := g.time()
	if g.allowed[key] {
		return true, true
	}
	if until, ok := g.denied[key]; ok && now.Before(until) {
		return false, true
	}
	if now.Before(g.coolUntil) {
		return false, true
	}
	return false, false
}

// question is the dialog's text. The path is the VM's choice: only the guarded path (ours)
// and a cleaned tail of it are shown.
func question(root, rel string, h hit, why string) string {
	var what string
	switch h.kind {
	case kindPath:
		what = "change " + h.rule
	case kindParent:
		what = "create, move or remove a folder that holds " + h.rule
	case kindInside:
		what = "move or remove a folder that holds " + h.rule
	case kindTooBig:
		what = "move or remove " + h.rule + " (too many to check for guarded files)"
	}
	return fmt.Sprintf("The VM wants to %s in %s.\n\nPath: %s\n\n%s\n\nAllow it? (Until the VM stops.)", what, root, shown(rel), why)
}

// shown is rel without what could fake or hide text in a dialog: control, format and
// direction characters, markup, and all but its last maxShown characters.
func shown(rel string) string {
	var b []rune
	for _, r := range rel {
		switch {
		case r == '<' || r == '>' || r == '&':
			b = append(b, '?')
		case unicode.IsControl(r) || unicode.In(r, unicode.Cf, unicode.Zl, unicode.Zp, unicode.Variation_Selector, unicode.Other_Default_Ignorable_Code_Point):
			// dropped
		default:
			b = append(b, r)
		}
	}
	if len(b) > maxShown {
		return "..." + string(b[len(b)-maxShown:])
	}
	return string(b)
}
