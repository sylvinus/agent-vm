// Package limaembed runs what Lima's libraries expect of limactl: they start
// the current executable again for some commands (`hostagent`, from
// instance.Start), and look for the guest agent and the templates next to it.
package limaembed

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"

	"github.com/sirupsen/logrus"
	"github.com/spf13/cobra"

	"github.com/sylvinus/agent-vm/third_party/lima/pkg/debugutil"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/driver/external/server"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/envutil"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/hostagent/dns"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype/dirnames"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/networks/usernet"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/osutil"
	"github.com/sylvinus/agent-vm/third_party/sshocker/pkg/reversesshfs"

	"github.com/sylvinus/agent-vm/internal/guard"
	"github.com/sylvinus/agent-vm/internal/policy"
	"github.com/sylvinus/agent-vm/internal/state"
)

var called atomic.Bool

// Called reports whether Run has run: the program looks for the commands
// Lima starts it for.
func Called() bool { return called.Load() }

// Run runs args (os.Args[1:]) when they are a command Lima's libraries start
// this executable for, as limactl would, and reports whether they were. Such
// a command never returns: it exits.
func Run(args []string) bool {
	called.Store(true)
	i := 0
	for i < len(args) && args[i] == "--debug" {
		i++
	}
	if i == len(args) || args[i] != "hostagent" {
		return false
	}
	if runtime.GOOS == "windows" {
		windowsPath()
	}
	// Lima's own port forwarder, the one patched to never take a port a
	// program of the host serves; not the ssh one.
	os.Unsetenv("LIMA_SSH_PORT_FORWARDER")
	// The policies the VM was booted with, in its folder: the folder of the
	// VMs is the one the process that started this one gave Lima, whatever
	// state folder that program keeps. The instance is the last argument. An
	// unreadable policy stops the VM rather than leave it open.
	vms, err := dirnames.InstancesDir()
	if err != nil || vms == "" {
		logrus.Fatalf("no folder for the VMs ($%s): %v", dirnames.InstancesEnv, err)
	}
	vmName := args[len(args)-1]
	pf, err := policy.Read(filepath.Join(vms, vmName, state.PolicyFile))
	if err != nil {
		logrus.Fatal(err)
	}
	// What the guest may reach (netguard): every connection it opens is made
	// here, by the instance's netstack.
	net := pf.Network
	usernet.Outbound = net.Allows
	if len(net.Domains) > 0 {
		// Both resolvers the guest can reach: the gateway's, which every
		// query gets whatever the guest's iptables say, and the hostagent's.
		usernet.Names, usernet.Answered = net.Name, net.Answered
		dns.Names, dns.Answered = net.Name, net.Answered
	}
	// The user is asked before the VM changes a file their machine runs on
	// its own (guard): the shares' SFTP server runs here.
	g := guard.New(pf.Guarded, vmName)
	g.App = pf.App
	reversesshfs.Guard = g.Allow
	root := &cobra.Command{
		Use:           "agent-vm",
		SilenceUsage:  true,
		SilenceErrors: true,
		PersistentPreRun: func(cmd *cobra.Command, _ []string) {
			if debug, _ := cmd.Flags().GetBool("debug"); debug {
				logrus.SetLevel(logrus.DebugLevel)
				debugutil.Debug = true
			}
		},
	}
	root.PersistentFlags().Bool("debug", false, "debug mode")
	root.AddCommand(newHostagentCommand())
	root.SetArgs(args)
	// Its events, as limactl's, and a notice for each port it forwards. The
	// instance is the last argument.
	root.SetOut(newEventWatch(os.Stdout, pf.App, vmName))
	err = root.Execute()
	server.Disconnect()
	osutil.HandleExitError(err)
	if err != nil {
		logrus.Fatal(err)
	}
	os.Exit(0)
	return true
}

// windowsPath puts QEMU's usual folders on PATH, as limactl's main does.
func windowsPath() {
	if extras, ok := os.LookupEnv("_LIMA_WINDOWS_EXTRA_PATH"); ok && strings.TrimSpace(extras) != "" {
		_ = os.Setenv("PATH", strings.TrimSpace(extras)+string(filepath.ListSeparator)+os.Getenv("PATH"))
	}
	p := os.Getenv("PATH")
	if np := envutil.AppendDirsToPath(p, envutil.PlatformCommonToolDirs); np != p {
		_ = os.Setenv("PATH", np)
	}
}
