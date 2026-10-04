// Command agent-vm runs AI coding agents in a disposable Linux VM per
// project, with Lima built in.
package main

import (
	"os"

	"github.com/sylvinus/agent-vm/internal/cli"
	"github.com/sylvinus/agent-vm/internal/limaembed"
)

func main() {
	// Lima's libraries start this executable again for its hostagent.
	if limaembed.Run(os.Args[1:]) {
		return
	}
	os.Exit(cli.Main(os.Args[1:], cli.Stdio()))
}
