// Command sandbox is a program that embeds agentvm: it runs a command in a
// disposable Linux VM of the current folder, with nothing of the machine
// shared but that folder.
//
//	sandbox setup                  build the base VM, once
//	sandbox run make test          run a command in this folder's VM
//	sandbox shell                  a shell in it
//	sandbox rm                     delete it
//
// Its state, VMs included, is in ~/.sandbox ($SANDBOX_STATE_DIR): apart from
// agent-vm's own and from any other program that embeds agentvm.
package main

//go:generate go run github.com/sylvinus/agent-vm/cmd/agent-vm-assets -o assets

import (
	"bufio"
	"context"
	"embed"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/signal"
	"strings"

	agentvm "github.com/sylvinus/agent-vm"
	"github.com/sylvinus/agent-vm/provision"
)

// The guest agent and Lima's templates, made by go generate.
//
//go:embed all:assets
var assetsFS embed.FS

// baseName is this program's template: another than agent-vm's, so that the
// two programs' VMs never mix.
const baseName = "base-sandbox"

func main() {
	// Lima's host agent is this executable again: first thing.
	agentvm.RunHelper()
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: sandbox setup | run <command> [args] | shell | rm")
		return 2
	}
	assets, err := fs.Sub(assetsFS, "assets")
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	stateDir := os.Getenv("SANDBOX_STATE_DIR")
	if stateDir == "" {
		stateDir = "~/.sandbox"
	}
	e, err := agentvm.Open(agentvm.Options{
		StateDir: stateDir,
		AppName:  "sandbox",
		Assets:   assets,
		Asker:    &askTerminal{in: bufio.NewReader(stdin), out: stderr},
		OnEvent:  func(ev agentvm.Event) { printEvent(ev, stdout, stderr) },
	})
	if err != nil {
		fmt.Fprintln(stderr, "sandbox:", err)
		return 1
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	switch args[0] {
	case "setup":
		return setup(ctx, e, stderr)
	case "run", "shell":
		cmd := args[1:]
		if args[0] == "shell" {
			cmd = []string{"zsh", "-l"}
		}
		if len(cmd) == 0 {
			fmt.Fprintln(stderr, "usage: sandbox run <command> [args]")
			return 2
		}
		return runIn(ctx, e, cmd, stdin, stdout, stderr)
	case "rm":
		v, err := e.ProjectVM("")
		if err != nil {
			fmt.Fprintln(stderr, "sandbox:", err)
			return 1
		}
		if !v.Remove(ctx) {
			return 1
		}
		return 0
	}
	fmt.Fprintf(stderr, "sandbox: unknown command %q\n", args[0])
	return 2
}

// setup builds the base VM: Debian with zsh, git and curl, nothing else. The
// engine runs commands through a login zsh, whose ~/.zshenv reads the env
// file the engine pushes (~/.agent-vm.env): a template provides both.
func setup(ctx context.Context, e *agentvm.Engine, stderr io.Writer) int {
	t := provision.Template{
		Name:      baseName,
		MemoryGiB: 2,
		DiskGiB:   10,
		Scripts: []provision.Script{{
			Name:    "packages",
			Message: "Installing zsh, git and curl...",
			Shell:   []string{"bash", "-l"},
			Content: `set -e
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zsh git curl
echo '[ -f "$HOME/.agent-vm.env" ] && . "$HOME/.agent-vm.env"' > "$HOME/.zshenv"
`,
		}},
	}
	if err := e.Setup(ctx, t, nil); err != nil {
		fmt.Fprintln(stderr, "sandbox:", err)
		return 1
	}
	return 0
}

// runIn makes this folder's VM exist and run, then runs the command in it.
func runIn(ctx context.Context, e *agentvm.Engine, cmd []string, stdin io.Reader, stdout, stderr io.Writer) int {
	v, err := e.ProjectVM("")
	if err != nil {
		fmt.Fprintln(stderr, "sandbox:", err)
		return 1
	}
	if err := v.Ensure(ctx, agentvm.Spec{Base: baseName}); err != nil {
		if errors.Is(err, agentvm.ErrBaseMissing) {
			fmt.Fprintln(stderr, "sandbox: run 'sandbox setup' first")
		}
		return 1
	}
	code, err := v.Exec(ctx, agentvm.Exec{Args: cmd, Stdin: stdin, Stdout: stdout, Stderr: stderr})
	if err != nil {
		fmt.Fprintln(stderr, "sandbox:", err)
		return 1
	}
	return code
}

// printEvent shows what the engine tells: progress on stdout would mix with
// the command's output, so everything goes to stderr.
func printEvent(ev agentvm.Event, _, stderr io.Writer) {
	if ev.Title != "" {
		fmt.Fprintf(stderr, "== %s ==\n", ev.Title)
	}
	fmt.Fprintln(stderr, ev.Text)
}

// askTerminal puts the engine's questions on the terminal.
type askTerminal struct {
	in  *bufio.Reader
	out io.Writer
}

func (a *askTerminal) CanAsk() bool {
	f, ok := a.out.(*os.File)
	if !ok {
		return false
	}
	st, err := f.Stat()
	return err == nil && st.Mode()&os.ModeCharDevice != 0
}

func (a *askTerminal) Ask(_ context.Context, q agentvm.Question) bool {
	if q.Detail != "" {
		fmt.Fprintf(a.out, "%s\n%s\n", q.Title, q.Detail)
	}
	def := "y/N"
	if q.Default {
		def = "Y/n"
	}
	fmt.Fprintf(a.out, "%s [%s] ", q.Prompt, def)
	line, _ := a.in.ReadString('\n')
	switch strings.ToLower(strings.TrimSpace(line)) {
	case "y", "yes":
		return true
	case "n", "no":
		return false
	}
	return q.Default
}
