// Package agents lists the coding agents agent-vm runs, each with the flag
// that lets it work unattended, which is safe in a VM. A program that embeds
// agentvm can run these, or its own.
//
// This package is experimental until a program other than agent-vm has used
// it.
package agents

// Agent is a command that works on a project, in a VM.
type Agent struct {
	// Name is what the command line calls it: `agent-vm claude`.
	Name string
	// Command is the program and the flags that let it work without asking
	// permission.
	Command []string
	// TTY says the agent draws a full-screen terminal interface: it needs
	// one even when its output is not a terminal.
	TTY bool
}

// Defaults are agent-vm's agents.
func Defaults() []Agent {
	return []Agent{
		// The VM also enforces bypass mode with managed settings: Claude Code
		// drops the flag when it relaunches itself.
		{Name: "claude", Command: []string{"claude", "--dangerously-skip-permissions"}},
		// Approves every prompt that is not explicitly denied.
		{Name: "opencode", Command: []string{"opencode", "--auto"}, TTY: true},
		{Name: "codex", Command: []string{"codex", "--dangerously-bypass-approvals-and-sandbox"}},
		{Name: "vibe", Command: []string{"vibe", "--agent", "auto-approve"}, TTY: true},
		// No permission prompts: it runs every tool as asked.
		{Name: "pi", Command: []string{"pi"}, TTY: true},
	}
}

// Lookup is the default agent called name.
func Lookup(name string) (Agent, bool) {
	for _, a := range Defaults() {
		if a.Name == name {
			return a, true
		}
	}
	return Agent{}, false
}

// Names are the names of the default agents, in the order they are listed.
func Names() []string {
	var out []string
	for _, a := range Defaults() {
		out = append(out, a.Name)
	}
	return out
}
