package cli

import (
	"fmt"
	"io"
	"math/rand/v2"
	"os"
	"path/filepath"
	"strings"

	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/vm"
)

// probeResult is what the guest answered.
type probeResult struct {
	writable     string // "true", "false", or "lost": the share is not mounted
	runtimeFound bool
	envOK        bool
}

// The guest's side of the probe, its arguments the project's path, the
// project's env file and runtime script (by their paths in the VM), and the
// token the host put in the project.
const probeScript = `
(umask 077 && rm -f "$HOME/.agent-vm.env" && { cat; [ -z "$2" ] || [ ! -f "$2" ] || awk "{ sub(/\r\$/, \"\"); print }" "$2"; } > "$HOME/.agent-vm.env") && echo env-ok
[ -z "$3" ] || [ ! -f "$3" ] || echo runtime-found
[ -z "$4" ] || [ ! -f "$1/$4" ] || echo share-ok
p="$1/.agent-vm-write-probe.$$"; touch "$p" 2>/dev/null || exit 1; rm -f "$p"`

// probe pushes the env and checks the project share, in one round trip:
//   - writes ~/.agent-vm.env in the VM (mode 600, sourced by its ~/.zshenv):
//     payload, then the project's env, read by the VM, CRs dropped; empty
//     too, so env removed on the host goes;
//   - says whether the project's runtime script is there;
//   - writes into the project, a real write removed at once, not `test -w`:
//     after a mode change the guest's fstab still shows the old one;
//   - "lost" when the share is not mounted (sshfs died, or never mounted),
//     where the VM writes on its own disk: the guest does not see the file
//     put in the project just before. Not for a scratch VM, which shares
//     nothing.
func (s *start) probe(payload, guestEnv, guestRuntime string) probeResult {
	token := ""
	if !s.opts.Scratch {
		t := fmt.Sprintf(".agent-vm-probe.%d.%d", os.Getpid(), rand.IntN(1e9))
		// Never through something already there.
		if f, err := os.OpenFile(filepath.Join(s.dir, t), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644); err == nil {
			f.Close()
			token = t
			defer os.Remove(filepath.Join(s.dir, t))
		}
	}
	in := ""
	if payload != "" {
		in = payload + "\n"
	}
	var out strings.Builder
	b, err := s.backend()
	code := 1
	if err == nil {
		code, err = b.Shell(s.ctx, s.name, vm.ShellOpts{
			Args:  []string{"sh", "-c", probeScript, "sh", paths.Guest(s.dir), guestEnv, guestRuntime, token},
			Stdin: strings.NewReader(in), Stdout: &out, Stderr: io.Discard,
		})
	}
	r := probeResult{
		envOK:        strings.Contains(out.String(), "env-ok"),
		runtimeFound: strings.Contains(out.String(), "runtime-found"),
		writable:     fmt.Sprint(err == nil && code == 0),
	}
	// The guest answered, but without the share.
	if token != "" && r.envOK && !strings.Contains(out.String(), "share-ok") {
		r.writable = "lost"
	}
	if !r.envOK {
		s.warnf("Warning: failed to push the env files into VM '%s'.", s.name)
	}
	return r
}
