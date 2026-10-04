// Package cli is agent-vm's command line: the commands of 0.2's agent-vm.sh,
// with the same options, output and exit statuses.
package cli

import (
	"context"
	_ "embed"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"

	"github.com/sylvinus/agent-vm/internal/version"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

//go:embed help.txt
var helpText string

// IO is where a command reads and writes.
type IO struct {
	Stdin          io.Reader
	Stdout, Stderr io.Writer
}

// The commands VM options mean nothing to: `agent-vm --readonly stop` must
// not read as if something had been made read-only.
var noVMOpts = map[string]bool{
	"stop": true, "rm": true, "destroy": true, "destroy-all": true, "list": true, "status": true,
	"name": true, "info": true, "env": true, "project-env": true, "version": true, "--version": true,
	"-V": true, "doctor": true, "install": true, "uninstall": true, "help": true, "--help": true, "-h": true,
}

// Main runs agent-vm with args (os.Args[1:]) and returns its exit status.
func Main(args []string, io IO) int {
	e, err := newApp(io)
	if err != nil {
		fmt.Fprintf(io.Stderr, "Error: %v\n", err)
		return 1
	}
	return e.main(context.Background(), args)
}

func (e *app) main(ctx context.Context, args []string) int {
	io := e.io
	opts := newVMOpts()
	lead, args, err := opts.takeAll(args)
	if err != nil {
		fmt.Fprintf(io.Stderr, "Error: %v\n", err)
		return 1
	}
	cmd := "help"
	if len(args) > 0 {
		cmd, args = args[0], args[1:]
	}
	if len(lead) > 0 && noVMOpts[cmd] {
		fmt.Fprintf(io.Stderr, "Error: %s is an option for the commands that start a VM (claude, opencode, codex, vibe, pi, shell, run, code), not for '%s'.\n", lead[0], cmd)
		return 1
	}
	switch cmd {
	case "help", "--help", "-h":
		fmt.Fprint(io.Stdout, helpText)
		return 0
	case "version", "--version", "-V":
		return versionCmd(args, io)
	case "name":
		return nameCmd(args, io)
	case "list", "status":
		return e.listCmd(ctx, args)
	case "stop":
		return e.stopCmd(ctx, args)
	case "rm", "destroy":
		return e.rmCmd(ctx, args)
	case "destroy-all":
		return e.destroyAllCmd(ctx, args)
	case "info":
		return e.infoCmd(ctx, args)
	case "env":
		return e.sharedEnvCmd(args)
	case "project-env":
		return e.projectEnvCmd(ctx, args)
	case "claude", "opencode", "codex", "vibe", "pi":
		return e.agentCmd(ctx, cmd, opts, args)
	case "shell", "sh":
		return e.shellCmd(ctx, opts, args)
	case "run":
		return e.runCmd(ctx, opts, args)
	case "setup":
		return e.setupCmd(ctx, append(lead, args...))
	case "doctor":
		return e.doctorCmd(ctx, args)
	case "install":
		return e.installCmd(ctx, args)
	case "uninstall":
		return e.uninstallCmd(args)
	case "code":
		return e.codeCmd(ctx, opts, args)
	default:
		fmt.Fprintf(io.Stderr, "Unknown command: %s\nRun 'agent-vm help' for usage.\n", cmd)
		return 1
	}
}

var versionRe = regexp.MustCompile(`^[0-9]+(\.[0-9]+)*(-[A-Za-z0-9.]+)?$`)

// `version [--min X.Y.Z]`: silent and 0 when this agent-vm is at least
// X.Y.Z, an error and 1 when older, 2 when the call itself is wrong.
func versionCmd(args []string, io IO) int {
	if len(args) == 0 {
		fmt.Fprintln(io.Stdout, version.Version)
		return 0
	}
	want := ""
	for len(args) > 0 {
		switch a := args[0]; {
		case a == "--min":
			if len(args) < 2 {
				fmt.Fprintln(io.Stderr, "Error: --min needs a version (e.g. --min 0.2.0)")
				return 2
			}
			want, args = args[1], args[2:]
		case strings.HasPrefix(a, "--min="):
			want, args = strings.TrimPrefix(a, "--min="), args[1:]
		default:
			fmt.Fprintf(io.Stderr, "Error: unknown option for version: %s\n", a)
			return 2
		}
	}
	if !versionRe.MatchString(want) {
		fmt.Fprintf(io.Stderr, "Error: --min expects a version like 1.2.3 (got: '%s')\n", want)
		return 2
	}
	if version.AtLeast(version.Version, want) {
		return 0
	}
	fmt.Fprintf(io.Stderr, "Error: agent-vm %s is older than the required %s.\n", version.Version, want)
	fmt.Fprintf(io.Stderr, "  Update it:  %s\n", updateCommand())
	return 1
}

// updateCommand is how this copy of agent-vm is updated.
// TODO(0.3): the install methods of the Go releases (see PLAN_0.3.0.md, phase 4).
func updateCommand() string {
	return "curl -fsSL https://www.agent-vm.org/install.sh | sh"
}

// `name [dir]`: the VM name of a directory, the current one by default.
func nameCmd(args []string, io IO) int {
	dir := ""
	if len(args) > 0 {
		dir = args[0]
	}
	abs, err := vmname.AbsDir(dir)
	if err != nil {
		fmt.Fprintf(io.Stderr, "Error: %v\n", err)
		return 1
	}
	fmt.Fprintln(io.Stdout, vmname.Name(abs))
	return 0
}

// Stdio is the process's own.
func Stdio() IO {
	return IO{Stdin: os.Stdin, Stdout: os.Stdout, Stderr: os.Stderr}
}
