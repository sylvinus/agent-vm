// Command agent-vm runs AI coding agents in a disposable Linux VM per
// project, with Lima built in.
package main

import (
	"os"
	"strings"

	"github.com/sylvinus/agent-vm/internal/cli"
	"github.com/sylvinus/agent-vm/internal/limaembed"
)

// extraPath goes first on PATH, for this process and what it starts (the
// hostagent, QEMU): set at build time (-ldflags -X) by a build that ships
// QEMU with agent-vm (flake.nix). Empty otherwise.
var extraPath string

func main() {
	if p := os.Getenv("PATH"); extraPath != "" && !strings.HasPrefix(p, extraPath+string(os.PathListSeparator)) {
		os.Setenv("PATH", extraPath+string(os.PathListSeparator)+p)
	}
	// Lima's libraries start this executable again for its hostagent.
	if limaembed.Run(os.Args[1:]) {
		return
	}
	os.Exit(cli.Main(os.Args[1:], cli.Stdio()))
}
