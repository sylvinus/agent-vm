// Package provision describes how a base template is built: the VM every
// project's VM is cloned from. A Template is a name, the resources of the VM
// it is built in, and scripts run in it as it boots for the first time.
// AgentVM is agent-vm's own: dev tools, Docker, Chromium and the coding agents.
//
// This package is experimental until a program other than agent-vm has used
// it.
package provision

import (
	_ "embed"
	"fmt"
	"regexp"
	"strings"
)

// Script is a program run in the build VM, fed through its standard input.
type Script struct {
	// Name labels it in messages and errors.
	Name string
	// Message is told before it runs ("Installing packages...").
	Message string
	// Shell is the command that runs the content, in the VM, as the user
	// of the VM: {"bash", "-l"}.
	Shell []string
	// Content is the script, written to the standard input of Shell, after
	// the Env of its Template as `export` lines.
	Content string
	// Env are more KEY=value pairs exported before Content, after the
	// Template's.
	Env []string
}

// Template is a base template to build.
//
// What the engine expects of the guest the scripts make: a user who can
// sudo; zsh, through which it runs commands (a login shell, from the project's
// folder) and the runtime scripts; and, for the env file it pushes
// (~/.agent-vm.env, written on each start) to reach those commands, a
// ~/.zshenv that sources it. AgentVM does all of it.
type Template struct {
	// Name is the template's VM name: "base" by default for the engine.
	// Reserved: "base" and names starting with "base-".
	Name string
	// CPUs, MemoryGiB and DiskGiB are the resources of the build VM, and so
	// of every VM cloned from it unless they ask for others. 0: the engine's
	// defaults (1 CPU, 3 GiB of memory, 10 GiB of disk).
	CPUs, MemoryGiB, DiskGiB int
	// Scripts run in order. A failing one stops the build, and the template
	// from before is kept.
	Scripts []Script
	// Env are KEY=value pairs exported before every script.
	Env []string
	// Preinstall records the software the scripts install, by name, for
	// the programs that show it. The scripts are what installs.
	Preinstall []string
}

// Software is what agent-vm.setup.sh installs, by name (it reads
// AGENT_VM_INSTALL_<NAME>).
var Software = []string{"python", "node", "ruby", "rust", "golang", "docker", "chromium", "gh", "claude", "opencode", "codex", "vibe", "pi",
	"code-server", "code-claude", "code-codex", "code-vibe", "mcp-chrome", "mcp-playwright"}

// DefaultSoftware is the default set. Opt-in: Ruby, Rust, Go, Pi (released
// several times a week), Playwright MCP (a second browser-driving server,
// whose tools cost context in every agent), and code-server with its
// extensions (an editor most use on the host).
var DefaultSoftware = []string{"python", "node", "docker", "chromium", "gh", "claude", "opencode", "codex", "vibe", "mcp-chrome"}

//go:embed agent-vm.setup.sh
var agentVMScript string

// AgentVMScript is agent-vm's setup script, for the programs that run it
// themselves.
func AgentVMScript() string { return agentVMScript }

// AgentVM is agent-vm's template: its setup script with the software named
// installed (all of DefaultSoftware if none is named). Names are those of
// Software; "default", "all" and "none" are the sets.
func AgentVM(preinstall ...string) (Template, error) {
	in := map[string]bool{}
	if len(preinstall) == 0 {
		preinstall = []string{"default"}
	}
	for _, f := range preinstall {
		switch {
		case f == "":
		case f == "all":
			set(in, Software...)
		case f == "default":
			set(in, DefaultSoftware...)
		case f == "none":
		case f == "code-claude" || f == "code-codex" || f == "code-vibe":
			// An extension needs the editor.
			set(in, f, "code-server")
		case contains(Software, f):
			set(in, f)
		default:
			return Template{}, fmt.Errorf("unknown software %q (names are lowercase): %s, default, all, none", f, strings.Join(Software, ", "))
		}
	}
	if r := NodeNeededBy(in); r != "" {
		in["node"] = true
	}
	return AgentVMChoices(in), nil
}

// AgentVMChoices is agent-vm's template for the software chosen, by name,
// as is: Node.js is not added when a choice needs it (see NodeNeededBy).
func AgentVMChoices(in map[string]bool) Template {
	s := Script{Name: "agent-vm.setup.sh", Message: "Installing packages inside VM...", Shell: []string{"bash", "-l"}, Content: agentVMScript}
	t := Template{Name: "base"}
	for _, n := range Software {
		v := 0
		if in[n] {
			v = 1
			t.Preinstall = append(t.Preinstall, n)
		}
		s.Env = append(s.Env, fmt.Sprintf("AGENT_VM_INSTALL_%s=%d", strings.ToUpper(strings.ReplaceAll(n, "-", "_")), v))
	}
	t.Scripts = []Script{s}
	return t
}

// NodeNeededBy says why the choices need Node.js, if they do: Codex and Pi
// install with npm, Chrome DevTools MCP runs with npx.
func NodeNeededBy(in map[string]bool) string {
	switch {
	case in["codex"]:
		return "Codex CLI requires npm"
	case in["pi"]:
		return "Pi requires npm"
	case in["chromium"] && in["mcp-chrome"] && (in["claude"] || in["opencode"] || in["vibe"] || in["code-claude"] || in["code-codex"] || in["code-vibe"]):
		return "Chrome DevTools MCP uses npx"
	}
	return ""
}

func set(in map[string]bool, names ...string) {
	for _, n := range names {
		in[n] = true
	}
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

var plain = regexp.MustCompile(`^[A-Za-z0-9_./:@%+=,-]*$`)

// Exports are the pairs as `export` lines, for the standard input of a
// script: a value with anything a shell reads is single-quoted.
func Exports(pairs ...[]string) string {
	var b strings.Builder
	for _, ps := range pairs {
		for _, p := range ps {
			k, v, _ := strings.Cut(p, "=")
			if !plain.MatchString(v) {
				v = "'" + strings.ReplaceAll(v, "'", `'\''`) + "'"
			}
			fmt.Fprintf(&b, "export %s=%s\n", k, v)
		}
	}
	return b.String()
}
