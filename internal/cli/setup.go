package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	agentvm "github.com/sylvinus/agent-vm"
	"github.com/sylvinus/agent-vm/internal/env"
	"github.com/sylvinus/agent-vm/internal/host"
	"github.com/sylvinus/agent-vm/internal/ui"
	"github.com/sylvinus/agent-vm/internal/vmname"
	"github.com/sylvinus/agent-vm/provision"
)

const setupUsage = "Usage: agent-vm setup [--disk GB] [--memory GB] [--cpus N] [--preinstall=LIST]"

const setupHelp = `Usage: agent-vm setup [options]

Create a base VM template with dev tools and agents pre-installed. Runs an
interactive wizard by default; the first prompt offers a "default install"
(everything except the opt-in Ruby, Rust, Go, Pi, Playwright MCP, code-server
and its extensions). Answer 'n' for per-component prompts. Pass
--preinstall=... to skip the wizard and pick a specific subset
non-interactively. When no terminal can be asked on (no controlling
terminal, or stderr redirected, as in CI), the wizard is skipped
automatically and the default set is installed.

Options:
  --disk GB           VM disk size (default: 10)
  --memory GB         VM memory (default: 3, 4 with code-server in the wizard)
  --cpus N            Number of CPUs (default: 1)
  --preinstall=LIST   Comma-separated list of tools to preinstall in the base
                      VM image (skips the wizard). Anything not listed is
                      skipped. Use:
                        'default' for the default set
                                  (everything except Ruby, Rust, Go, Pi,
                                  mcp-playwright, code-server, code-*),
                        'all' for everything,
                        'none' for nothing.
                      Available names:
                        python, node, ruby, rust, golang, docker, chromium,
                        gh, claude, opencode, codex, vibe, pi, mcp-chrome,
                        mcp-playwright, code-server, code-claude,
                        code-codex, code-vibe
                      'code-server' is VS Code in the browser, for
                      'agent-vm code', with GitHub Copilot turned off.
                      'code-claude', 'code-codex' and 'code-vibe' add that
                      agent's extension, and code-server with it. Each
                      extension brings its own copy of the agent: 'claude',
                      'codex' and 'vibe' are the command-line ones, for
                      'agent-vm claude' and the others.
                      Selecting codex or pi also installs node (npm). So does
                      mcp-chrome when chromium and an agent are selected
                      (npx). mcp-playwright does not: list node yourself.
                      The mcp-* names wire an MCP server into each installed
                      agent's config. Both 'mcp-chrome' (Chrome DevTools) and
                      'mcp-playwright' drive the preinstalled Chromium, so
                      both need node and chromium and are skipped, with a
                      notice, without them. Pi has no MCP support, so they
                      are not wired into it. 'mcp-playwright' is opt-in and not
                      part of 'default': a second browser-driving server is
                      redundant for most users. Omit them to leave the agents'
                      MCP config untouched, for when MCP servers are
                      managed per project rather than baked into the image.
                      Examples:
                        --preinstall=default,rust       # default set plus Rust
                        --preinstall=python,docker,claude
                        --preinstall=node,chromium,opencode   # no chrome MCP
                        --preinstall=default,code-claude      # plus the editor
  --help              Show this help
`

// The software of the base, as agent-vm.setup.sh names it
// (AGENT_VM_INSTALL_<NAME>), and the default set.
var (
	software        = provision.Software
	defaultSoftware = provision.DefaultSoftware
)

// skipPrereqs is for tests, on hosts without KVM.
var skipPrereqs = false

type install map[string]bool

func (in install) set(names ...string) {
	for _, n := range names {
		in[n] = true
	}
}

// nodeNeededBy says why the choices need Node.js, if they do.
func (in install) nodeNeededBy() string { return provision.NodeNeededBy(in) }

// setupCmd: `setup [options]`, the options given before it included. Of the
// VM options, it takes the resources.
func (e *app) setupCmd(ctx context.Context, args []string) int {
	disk, memory, cpus := 10, 3, 1
	memorySeen := false
	in := install{}
	in.set(defaultSoftware...)
	preinstall, preinstallSeen := "", false
	for len(args) > 0 {
		o := newVMOpts()
		n, err := o.take(args)
		if err != nil {
			fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
			return exitUsage
		}
		if n > 0 {
			switch {
			case o.Disk > 0:
				disk = o.Disk
			case o.Memory > 0:
				memory, memorySeen = o.Memory, true
			case o.CPUs > 0:
				cpus = o.CPUs
			default:
				name, _, _ := strings.Cut(args[0], "=")
				fmt.Fprintf(e.io.Stderr, "Unknown option: %s\n%s\n", name, setupUsage)
				return exitUsage
			}
			args = args[n:]
			continue
		}
		switch a := args[0]; {
		case a == "--help" || a == "-h":
			fmt.Fprint(e.io.Stdout, setupHelp)
			return 0
		case a == "--preinstall":
			// Only a value that is not an option: a bare --preinstall is the
			// default set, without swallowing a following --disk.
			preinstallSeen = true
			if len(args) > 1 && args[1] != "" && !strings.HasPrefix(args[1], "-") {
				preinstall, args = args[1], args[2:]
			} else {
				args = args[1:]
			}
		case strings.HasPrefix(a, "--preinstall="):
			preinstall, preinstallSeen, args = strings.TrimPrefix(a, "--preinstall="), true, args[1:]
		default:
			fmt.Fprintf(e.io.Stderr, "Unknown option: %s\n%s\n", a, setupUsage)
			return exitUsage
		}
	}
	if preinstallSeen {
		in = install{}
		if preinstall == "" {
			preinstall = "default"
		}
		for _, f := range strings.Split(preinstall, ",") {
			f = strings.TrimPrefix(strings.TrimSuffix(f, " "), " ")
			switch {
			case f == "":
			case f == "all":
				in.set(software...)
			case f == "default":
				in.set(defaultSoftware...)
			case f == "none":
			case f == "code-claude" || f == "code-codex" || f == "code-vibe":
				// An extension needs the editor.
				in.set(f, "code-server")
			case contains(software, f):
				in.set(f)
			default:
				fmt.Fprintf(e.io.Stderr, "Unknown preinstall name: %s (names are lowercase)\n", f)
				fmt.Fprintf(e.io.Stderr, "Valid: %s, default, all, none\n", strings.Join(software, ", "))
				return exitUsage
			}
		}
	}

	fmt.Fprintln(e.io.Stdout, "Starting agent-vm setup...")
	if !skipPrereqs && (!host.LinuxPrereqs(e.io.Stderr) || !host.WindowsPrereqs(e.io.Stdout, e.io.Stderr)) {
		return 1
	}
	if !preinstallSeen && e.ui.CanAsk() {
		disk, memory, cpus = e.wizard(in, disk, memory, cpus, memorySeen)
	}
	if r := in.nodeNeededBy(); r != "" && !in["node"] {
		fmt.Fprintf(e.io.Stderr, "Enabling Node.js because %s.\n", r)
		in["node"] = true
	}
	return e.buildBase(ctx, in, disk, memory, cpus)
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// wizard asks for the software and the resources, on the terminal.
func (e *app) wizard(in install, disk, memory, cpus int, memorySeen bool) (int, int, int) {
	w := e.io.Stderr
	u := e.ui
	yn := func(q string, def bool) bool { return u.AskYN(q, def) }
	fmt.Fprint(w, "\nagent-vm setup wizard\n─────────────────────\n\n"+
		"These settings apply to the base VM image. Every per-project VM is\n"+
		"cloned from it, so anything preinstalled here is available in all\n"+
		"future agent VMs. You can still install extra tools inside any\n"+
		"individual VM later (e.g. via `agent-vm shell`).\n\n"+
		"For more: https://www.agent-vm.org/\n\n"+
		"Software\n────────\n"+
		"  Agents:   Claude Code, OpenCode, Codex CLI, Mistral Vibe\n"+
		"  Tools:    Python, Node.js, Docker, Chromium, gh,\n"+
		"            Chrome DevTools MCP\n"+
		"  Skip:     Pi, Ruby, Rust, Go, Playwright MCP, code-server\n\n")
	if !yn("Use this default", true) {
		fmt.Fprint(w, "\nAI coding agents\n────────────────\n")
		in["claude"] = yn("Claude Code", true)
		in["opencode"] = yn("OpenCode", true)
		in["codex"] = yn("Codex CLI", true)
		in["vibe"] = yn("Mistral Vibe", true)
		in["pi"] = yn("Pi", false)
		fmt.Fprint(w, "\nEditor\n──────\n")
		in["code-server"] = yn("code-server (VS Code in the browser, for 'agent-vm code')", false)
		e.askCodeExtensions(in)
		fmt.Fprint(w, "\nSystem tools\n────────────\n")
		in["docker"] = yn("Docker", true)
		in["chromium"] = yn("Chromium (headless browser)", true)
		in["gh"] = yn("GitHub CLI (gh)", true)
		in["mcp-chrome"], in["mcp-playwright"] = false, false
		if in["chromium"] {
			in["mcp-chrome"] = yn("Chrome DevTools MCP (wired into each agent's config)", true)
			in["mcp-playwright"] = yn("Playwright MCP (also drives that Chromium)", false)
		}
		reason := in.nodeNeededBy()
		fmt.Fprint(w, "\nLanguages\n─────────\n")
		in["python"] = yn("Python 3", true)
		if reason != "" {
			in["node"] = true
			fmt.Fprintf(w, "Node.js 24: yes (%s)\n", reason)
		} else {
			in["node"] = yn("Node.js 24", true)
		}
		in["ruby"] = yn("Ruby", false)
		in["rust"] = yn("Rust", false)
		in["golang"] = yn("Go", false)
	}
	// The editor needs more memory than the agents alone. --memory wins.
	if in["code-server"] && !memorySeen {
		memory = 4
	}
	fmt.Fprint(w, "\nDefault resources\n─────────────────\n(per-VM override with --disk / --memory / --cpus on any agent-vm command)\n\n")
	fmt.Fprintf(w, "  Disk     %d GB\n  Memory   %d GB\n  CPUs     %d\n\n", disk, memory, cpus)
	if !yn("Use these defaults", true) {
		disk = u.AskInt("Disk size in GB", disk, 0)
		memory = u.AskInt("Memory in GB", memory, 0)
		cpus = u.AskInt("Number of CPUs", cpus, 0)
	}
	fmt.Fprintln(w)
	return disk, memory, cpus
}

// askCodeExtensions asks, after code-server, how the agents picked that
// have an extension are installed. Only when there is one.
func (e *app) askCodeExtensions(in install) {
	if !in["code-server"] {
		return
	}
	var names []string
	for _, a := range []struct{ key, name string }{{"claude", "Claude Code"}, {"codex", "Codex"}, {"vibe", "Mistral Vibe"}} {
		if in[a.key] {
			names = append(names, a.name)
		}
	}
	if len(names) == 0 {
		return
	}
	fmt.Fprintf(e.io.Stderr, "  %s in the editor:\n", strings.Join(names, ", "))
	choice := e.ui.AskChoice("Pick one", 1, "Extension and command line (agent-vm claude...)", "Extension only", "Command line only")
	if choice == 3 {
		return
	}
	in["code-claude"], in["code-codex"], in["code-vibe"] = in["claude"], in["codex"], in["vibe"]
	if choice == 2 {
		in["claude"], in["codex"], in["vibe"] = false, false, false
	}
}

// building is the VM the new base is built as. The base that is there keeps
// serving the starts, with its record, until the new one is complete.
const building = vmname.Template + "-building"

// customSetup is the name of the user's setup.sh among the scripts of the
// build.
const customSetup = "custom setup"

// setupOutput shows what the steps of the build print: the last lines in a
// window, all of it in a log.
type setupOutput struct {
	e       *app
	logPath string
	log     *os.File
	err     error
}

// open makes the log, on first use.
func (o *setupOutput) open() error {
	if o.log != nil || o.err != nil {
		return o.err
	}
	if o.err = os.MkdirAll(string(o.e.state), 0o755); o.err != nil {
		return o.err
	}
	o.logPath = o.e.state.Path("setup.log")
	o.log, o.err = os.Create(o.logPath)
	return o.err
}

func (o *setupOutput) Step(name string, fn func(stdout, stderr io.Writer) error) error {
	e := o.e
	// The user's own script runs on the terminal, as it always did.
	if name == "script:"+customSetup {
		return fn(e.io.Stdout, e.io.Stderr)
	}
	if err := o.open(); err != nil {
		return errSetupLog{err}
	}
	// Every step from here shows its output in a 10-line window, all of it
	// kept in one log for when something fails.
	win := e.ui.NewWindow(e.io.Stdout, o.log)
	err := fn(win, win)
	win.Close()
	if err != nil {
		fmt.Fprintf(o.log, "%v\n", err)
		if f, ok := e.io.Stdout.(*os.File); ok && ui.IsTerminal(f) {
			fmt.Fprint(e.io.Stderr, ui.Tail(o.logPath, 20))
		}
	}
	return err
}

// errSetupLog is why the log of the build could not be made.
type errSetupLog struct{ error }

// buildBase makes the base template: built as `building` (created, booted,
// provisioned by the setup script and the user's, stopped), then swapped in
// for the base and marked as ready. A setup that fails before the swap
// leaves the base it found.
func (e *app) buildBase(ctx context.Context, in install, disk, memory, cpus int) int {
	eng, err := e.engine()
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	t := provision.AgentVMChoices(in)
	t.Name = vmname.Template
	t.CPUs, t.MemoryGiB, t.DiskGiB = cpus, memory, disk
	if user, ok := readRegular(e.state.Path("setup.sh")); ok {
		t.Scripts = append(t.Scripts, provision.Script{
			Name:    customSetup,
			Message: fmt.Sprintf("Running custom setup from %s...", e.state.Path("setup.sh")),
			Shell:   []string{"zsh", "-l"},
			Content: env.StripCR(user),
		})
	}
	out := &setupOutput{e: e}
	defer func() {
		if out.log != nil {
			out.log.Close()
		}
	}()
	err = eng.Setup(ctx, t, out)
	var se *agentvm.SetupError
	switch {
	case err == nil:
	case errors.As(err, &se) && se.Told:
		return 1
	case errors.As(err, &se):
		var logErr errSetupLog
		if errors.As(se.Err, &logErr) {
			fmt.Fprintf(e.io.Stderr, "Error: %v\n", logErr.error)
			return 1
		}
		switch {
		case se.Step == "create":
			fmt.Fprintf(e.io.Stderr, "Error: Failed to create base VM. Full log: %s\n", out.logPath)
		case se.Step == "start":
			fmt.Fprintf(e.io.Stderr, "Error: Failed to start base VM. Full log: %s\nLima's own log: %s\n", out.logPath, se.LimaLog)
			host.WindowsStartHint(e.io.Stderr, out.logPath, se.LimaLog)
		case se.Script == customSetup:
			fmt.Fprintln(e.io.Stderr, "Error: Custom setup script failed.")
		default:
			fmt.Fprintf(e.io.Stderr, "Error: Setup script failed. Full log: %s\n", out.logPath)
		}
		return 1
	default:
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}

	fmt.Fprint(e.io.Stdout, "\nBase VM ready. Try one of these in any project directory:\n  agent-vm shell\n")
	for _, a := range []string{"claude", "opencode", "codex", "vibe", "pi"} {
		if in[a] {
			fmt.Fprintf(e.io.Stdout, "  agent-vm %s\n", a)
		}
	}
	if in["code-server"] {
		fmt.Fprintln(e.io.Stdout, "  agent-vm code")
	}
	// Only worth saying to someone with a VM to re-clone.
	if vms, err := e.agentVMs(ctx); err == nil && len(vms) > 1 {
		fmt.Fprint(e.io.Stdout, "\nNote: Existing VMs were not updated. Use --reset to re-clone them from the new base.\n")
	}
	return 0
}

// isFile and readRegular: a regular file, once links are followed; another
// kind (a FIFO, a device) is not read, it could block.
func isFile(p string) bool { fi, err := os.Stat(p); return err == nil && fi.Mode().IsRegular() }

func readRegular(p string) (string, bool) {
	if !isFile(p) {
		return "", false
	}
	b, err := os.ReadFile(p)
	return string(b), err == nil
}
