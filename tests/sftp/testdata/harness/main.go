// Command harness runs sshocker's builtin rooted SFTP server (the one the Lima
// hostagent runs in-process for agent-vm shares) outside of Lima.
//
//	harness mount <hostdir> <mountpoint> [extra sshfs args...]
//	    sshfs -o slave <mountpoint>, served by the rooted server, with Lima's options.
//	harness stdio <hostdir>
//	    the rooted server on stdin/stdout, for raw SFTP clients.
//
// readonlyNames is .git and .hg, as agent-vm sets it. A panic in the server
// exits the process with Go's stack trace on stderr, as it would kill the hostagent.
package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"

	"github.com/lima-vm/sshocker/pkg/reversesshfs"
	"github.com/lima-vm/sshocker/pkg/util"
)

var readonlyNames = []string{".git", ".hg"}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: harness mount <hostdir> <mountpoint> [sshfs args...] | harness stdio <hostdir>")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "mount":
		mount(os.Args[2], os.Args[3], os.Args[4:])
	case "stdio":
		serve(&util.RWC{ReadCloser: os.Stdin, WriteCloser: os.Stdout}, os.Args[2])
	default:
		os.Exit(2)
	}
}

func mount(hostDir, mnt string, extra []string) {
	// Lima: "-o slave" from sshocker, "allow_other" from the hostagent (cache and
	// follow_symlinks at Lima's defaults), "no_contain_symlinks" from agent-vm's wrapper.
	args := append([]string{":" + hostDir, mnt, "-o", "slave", "-o", "allow_other", "-o", "no_contain_symlinks", "-f"}, extra...)
	cmd := exec.Command("sshfs", args...)
	cmd.Stderr = os.Stderr
	in, err := cmd.StdinPipe()
	if err != nil {
		panic(err)
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		panic(err)
	}
	if err := cmd.Start(); err != nil {
		panic(err)
	}
	fmt.Fprintf(os.Stderr, "harness: serving %s on %s (pid %d)\n", hostDir, mnt, os.Getpid())
	serve(&util.RWC{ReadCloser: out, WriteCloser: in}, hostDir)
	_ = cmd.Process.Kill()
}

func serve(rwc io.ReadWriteCloser, hostDir string) {
	srv, err := reversesshfs.HarnessServer(rwc, hostDir, readonlyNames)
	if err != nil {
		panic(err)
	}
	fmt.Fprintln(os.Stderr, "harness: Serve returned:", srv.Serve())
}
