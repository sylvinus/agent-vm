package cli

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	agentvm "github.com/sylvinus/agent-vm"
	"github.com/sylvinus/agent-vm/internal/env"
	"github.com/sylvinus/agent-vm/internal/host"
	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/ui"
	"github.com/sylvinus/agent-vm/internal/version"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vmname"
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
                        code-opencode, code-codex, code-vibe
                      'code-server' is VS Code in the browser, for
                      'agent-vm code', with GitHub Copilot turned off.
                      'code-claude', 'code-opencode', 'code-codex' and 'code-vibe' add that
                      agent's extension, and code-server with it. Each
                      extension brings its own copy of the agent: 'claude',
                      'codex' and 'vibe' are the command-line ones, for
                      'agent-vm claude' and the others (OpenCode's extension
                      requires its command-line tool, which is installed with it).
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
// (AGENT_VM_INSTALL_<NAME>).
var software = []string{"python", "node", "ruby", "rust", "golang", "docker", "chromium", "gh", "claude", "opencode", "codex", "vibe", "pi",
	"code-server", "code-claude", "code-opencode", "code-codex", "code-vibe", "mcp-chrome", "mcp-playwright"}

// The default set. Opt-in: Ruby, Rust, Go, Pi (released several times a
// week), Playwright MCP (a second browser-driving server, whose tools cost
// context in every agent), and code-server with its extensions (an editor
// most use on the host).
var defaultSoftware = []string{"python", "node", "docker", "chromium", "gh", "claude", "opencode", "codex", "vibe", "mcp-chrome"}

// skipPrereqs is for tests, on hosts without KVM.
var skipPrereqs = false

type install map[string]bool

func (in install) set(names ...string) {
	for _, n := range names {
		in[n] = true
	}
}

// nodeNeededBy says why the choices need Node.js, if they do: Codex and Pi
// install with npm, Chrome DevTools MCP runs with npx.
func (in install) nodeNeededBy() string {
	switch {
	case in["codex"]:
		return "Codex CLI requires npm"
	case in["pi"]:
		return "Pi requires npm"
	case in["chromium"] && in["mcp-chrome"] && (in["claude"] || in["opencode"] || in["vibe"] || in["code-claude"] || in["code-opencode"] || in["code-codex"] || in["code-vibe"]):
		return "Chrome DevTools MCP uses npx"
	}
	return ""
}

// exports are the choices as the setup script reads them.
func (in install) exports() string {
	var b strings.Builder
	for _, n := range software {
		v := 0
		if in[n] {
			v = 1
		}
		fmt.Fprintf(&b, "export AGENT_VM_INSTALL_%s=%d\n", strings.ToUpper(strings.ReplaceAll(n, "-", "_")), v)
	}
	return b.String()
}

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
			case f == "code-opencode":
				// OpenCode's extension requires both the editor and the OpenCode CLI.
				in.set(f, "code-server", "opencode")
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

// swapBase puts the finished build in the base's place: the old base and its
// markers go, the build is cloned to the base's name and marked ready, last
// the build goes. Under the base's lock, so that no start clones the base
// meanwhile. Lima has no rename, so the disk is copied once more; the build
// is kept if the copy cannot be made, and said.
func (e *app) swapBase(ctx context.Context, b vm.Backend) bool {
	w := e.io.Stderr
	unlock, err := e.lockVM(ctx, vmname.Template)
	if err != nil {
		fmt.Fprintf(w, "Error: could not lock the base template: %v. The new base is VM '%s'; 'agent-vm setup' again builds another.\n", err, building)
		return false
	}
	defer unlock()
	if d := filepath.Join(LimaHome(e.state), vmname.Template); isDirNoYAML(d) {
		fmt.Fprintf(w, "Detected partial VM state at %s (no lima.yaml): cleaning up.\n", d)
		if err := os.RemoveAll(d); err != nil {
			fmt.Fprintf(w, "Error: could not remove %s: %v\n", d, err)
			return false
		}
	}
	// Forgets the old base's markers with it: from here on, nothing says a
	// base is ready.
	if !e.deleteVM(ctx, vmname.Template) {
		fmt.Fprintf(w, "Error: could not replace the base VM. The new one is VM '%s'; 'agent-vm setup' again builds another.\n", building)
		return false
	}
	if err := b.Clone(ctx, building, vmname.Template); err != nil {
		fmt.Fprintf(w, "Error: could not copy the new base VM to '%s': %v\nThere is no base now. The new one is VM '%s'; 'agent-vm setup' again builds another.\n", vmname.Template, err, building)
		return false
	}
	// The version last: it says the base can be cloned.
	if err := e.state.Write(state.BaseBuiltBy, []byte(version.Version+"\n")); err != nil {
		fmt.Fprintf(w, "Error: could not record the version that built the base: %v\nThe base VM is not marked ready: 'agent-vm setup' again.\n", err)
		return false
	}
	if err := e.state.Write(state.BaseVersion, []byte(strconv.FormatInt(time.Now().Unix(), 10)+"\n")); err != nil {
		fmt.Fprintf(w, "Error: could not record when the base was built: %v\nThe base VM is not marked ready: 'agent-vm setup' again.\n", err)
		return false
	}
	if !e.deleteVM(ctx, building) {
		fmt.Fprintf(w, "Warning: the base is ready, but VM '%s' stays: 'agent-vm rm %s' frees its disk.\n", building, building)
	}
	return true
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
	for _, a := range []struct{ key, name string }{
		{"claude", "Claude Code"},
		{"opencode", "OpenCode"},
		{"codex", "Codex"},
		{"vibe", "Mistral Vibe"},
	} {
		if in[a.key] {
			names = append(names, a.name)
		}
	}
	if len(names) == 0 {
		return
	}
	fmt.Fprintf(e.io.Stderr, "  %s in the editor:\n", strings.Join(names, ", "))
	promptExtOnly := "Extension only"
	if in["opencode"] {
		promptExtOnly = "Extension only (OpenCode keeps the CLI, required by its extension)"
	}
	choice := e.ui.AskChoice("Pick one", 1, "Extension and command line (agent-vm claude...)", promptExtOnly, "Command line only")
	if choice == 3 {
		return
	}
	in["code-claude"], in["code-opencode"], in["code-codex"], in["code-vibe"] = in["claude"], in["opencode"], in["codex"], in["vibe"]
	if choice == 2 {
		in["claude"], in["codex"], in["vibe"] = false, false, false
	}
}

// building is the VM the new base is built as. The base that is there keeps
// serving the starts, with its markers, until the new one is complete.
const building = vmname.Template + "-building"

// buildBase makes the base template: built as `building` (created, booted,
// provisioned by the setup script and the user's, stopped), then swapped in
// for the base and marked as ready. A setup that fails before the swap
// leaves the base it found.
func (e *app) buildBase(ctx context.Context, in install, disk, memory, cpus int) int {
	b, err := e.backend()
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	// One setup at a time: two would build in the same VM.
	unlockSetup, err := e.lockVM(ctx, vmname.Template+"-setup")
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: could not lock the base template's setup: %v\n", err)
		return 1
	}
	defer unlockSetup()
	if !(&start{app: e, ctx: ctx}).limaOverridesOK() {
		return 1
	}
	if err := policiesErr(e.state); err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	warnDomains(e.state, e.io.Stderr)
	// A build an earlier setup left, finished or not, is not this one's.
	if d := filepath.Join(LimaHome(e.state), building); isDirNoYAML(d) {
		fmt.Fprintf(e.io.Stderr, "Detected partial VM state at %s (no lima.yaml): cleaning up.\n", d)
		if err := os.RemoveAll(d); err != nil {
			fmt.Fprintf(e.io.Stderr, "Error: could not remove %s: %v\n", d, err)
			return 1
		}
	}
	if !e.deleteVM(ctx, building) {
		return 1
	}

	cpus = host.Cap("cpus", cpus, e.io.Stderr)
	memory = host.Cap("memory", memory, e.io.Stderr)
	host.WarnDiskSpace(LimaHome(e.state), disk, e.io.Stderr)

	if err := os.MkdirAll(string(e.state), 0o755); err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	logPath := e.state.Path("setup.log")
	log, err := os.Create(logPath)
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	defer log.Close()
	// Every step from here shows its output in a 10-line window, all of it
	// kept in one log for when something fails.
	windowed := func(fn func(w io.Writer) error) bool {
		win := e.ui.NewWindow(e.io.Stdout, log)
		err := fn(win)
		win.Close()
		if err != nil {
			fmt.Fprintf(log, "%v\n", err)
			if f, ok := e.io.Stdout.(*os.File); ok && ui.IsTerminal(f) {
				fmt.Fprint(e.io.Stderr, ui.Tail(logPath, 20))
			}
			return false
		}
		return true
	}
	stopBase := func() { _ = b.Stop(ctx, building) }

	fmt.Fprintln(e.io.Stdout, "Creating base VM...")
	none := []vm.Mount{}
	if !windowed(func(w io.Writer) error {
		return b.Create(ctx, building, "template:debian-13", vm.Settings{CPUs: cpus, MemoryGiB: memory, DiskGiB: disk, Mounts: &none, NoContainerd: true}, w)
	}) {
		fmt.Fprintf(e.io.Stderr, "Error: Failed to create base VM. Full log: %s\n", logPath)
		return 1
	}
	(&start{app: e, ctx: ctx, name: building}).printResources()

	fmt.Fprintln(e.io.Stdout, "Starting base VM (the first run downloads a Debian image)...")
	if !windowed(func(w io.Writer) error { return e.startVM(ctx, b, building, w) }) {
		ha := filepath.Join(LimaHome(e.state), building, "ha.stderr.log")
		fmt.Fprintf(e.io.Stderr, "Error: Failed to start base VM. Full log: %s\nLima's own log: %s\n", logPath, ha)
		host.WindowsStartHint(e.io.Stderr, logPath, ha)
		return 1
	}

	// The choices as export lines, then the script, on stdin. Without them it
	// installs the default set.
	fmt.Fprintln(e.io.Stdout, "Installing packages inside VM...")
	if !windowed(func(w io.Writer) error {
		code, err := b.Shell(ctx, building, vm.ShellOpts{Args: []string{"bash", "-l"},
			Stdin: strings.NewReader(in.exports() + agentvm.SetupScript), Stdout: w, Stderr: w})
		if err == nil && code != 0 {
			err = fmt.Errorf("exit status %d", code)
		}
		return err
	}) {
		fmt.Fprintf(e.io.Stderr, "Error: Setup script failed. Full log: %s\n", logPath)
		stopBase()
		return 1
	}

	if user, ok := readRegular(e.state.Path("setup.sh")); ok {
		fmt.Fprintf(e.io.Stdout, "Running custom setup from %s...\n", e.state.Path("setup.sh"))
		code, err := b.Shell(ctx, building, vm.ShellOpts{Args: []string{"zsh", "-l"},
			Stdin: strings.NewReader(env.StripCR(user)), Stdout: e.io.Stdout, Stderr: e.io.Stderr})
		if err != nil || code != 0 {
			fmt.Fprintln(e.io.Stderr, "Error: Custom setup script failed.")
			stopBase()
			return 1
		}
	}

	// Ready only once stopped: Lima clones only a stopped instance.
	if !e.stopVM(ctx, building) {
		fmt.Fprintf(e.io.Stderr, "Error: the new base VM is set up but did not stop: 'agent-vm stop %s', then 'agent-vm setup' again. The base from before is untouched.\n", building)
		return 1
	}
	if !e.swapBase(ctx, b) {
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
