package cli

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/sylvinus/agent-vm/internal/paths"
	"github.com/sylvinus/agent-vm/internal/ui"
	"github.com/sylvinus/agent-vm/internal/vm"
)

// codePrep runs in the VM before the editor starts, the candidate ports as
// arguments. Prints `missing` without code-server, else its config file and
// password, the port of an editor of this VM already running, and which
// candidates something in the VM listens on (ss; without it, curl, any
// answer but a refused connection, the VM's proxy bypassed).
//
// The password is made in the VM, on first use, never in the base: every VM
// is a copy of the base disk, and one VM knowing another's password could
// log into it through the host's loopback, which every VM reaches. The file
// is named after the hostname, which Lima sets per VM.
const codePrep = `
command -v code-server >/dev/null 2>&1 || { echo missing; exit 0; }
cfg="$HOME/.config/code-server/agent-vm-$(hostname).yaml"
if [ ! -s "$cfg" ]; then
  pw="$(od -An -N16 -tx1 /dev/urandom | tr -d " \n")"
  [ "${#pw}" = 32 ] || exit 1
  mkdir -p "${cfg%/*}" || exit 1
  (umask 077 && printf "auth: password\npassword: %s\ncert: false\n" "$pw" > "$cfg") || exit 1
fi
echo "config=$cfg"
echo "password=$(sed -n "s/^password: //p" "$cfg")"
pgrep -u "$(id -u)" -af -- "--config $cfg" \
  | sed -n "s/.*--bind-addr 127\.0\.0\.1:\([0-9]*\).*/running=\1/p" | head -n 1
if command -v ss >/dev/null 2>&1; then
  open=" $(ss -Hltn 2>/dev/null | awk "{ n = split(\$4, a, \":\"); printf \"%s \", a[n] }")"
  for p in "$@"; do
    case "$open" in *" $p "*) echo "listening=$p" ;; esac
  done
else
  for p in "$@"; do
    curl -s -o /dev/null --noproxy "*" --max-time 1 "http://127.0.0.1:$p/"
    [ $? -eq 7 ] || echo "listening=$p"
  done
fi
exit 0
`

var hex4 = regexp.MustCompile(`^[0-9a-f]{4}$`)

// codePorts are ten host ports for the VM's editor, from 20000 to 29999,
// from its name: the same on every start, so the browser finds the saved
// password at the same address while the first is free. The last four
// digits of the name's hash start them, so two VMs rarely share them.
func codePorts(vmName string) []int {
	h := ""
	if len(vmName) >= 4 {
		h = vmName[len(vmName)-4:]
	}
	if !hex4.MatchString(h) {
		sum := sha256.Sum256([]byte(vmName))
		h = hex.EncodeToString(sum[:])[:4]
	}
	n, _ := strconv.ParseInt(h, 16, 64)
	base := 20000 + int(n)%9991
	var out []int
	for i := range 10 {
		out = append(out, base+i)
	}
	return out
}

// codeHost is where the browser reaches the VM's editor: <vm>.localhost,
// which browsers send to 127.0.0.1 on their own. Browsers keep cookies per
// host name, not per port: on 127.0.0.1, a page served by any VM would get
// the session cookie of every editor. Lowercase, at most 63 characters (a
// DNS label), the hash at the end kept.
func codeHost(vmName string) string {
	l := strings.ToLower(vmName)
	if len(l) > 63 {
		l = l[:54] + "-" + l[len(l)-8:]
	}
	return l + ".localhost"
}

func hostPortOpen(p int) bool {
	c, err := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(p), time.Second)
	if err == nil {
		c.Close()
		return true
	}
	return false
}

// codeSay prints the editor's address and password, and a note, in a box.
// Safari leaves *.localhost to macOS, which may not resolve it: 127.0.0.1
// then, in a window of its own.
func (s *start) codeSay(port int, pw, note string) {
	body := fmt.Sprintf("  Address:   http://%s:%d/\n  Password:  %s\n", codeHost(s.name), port, pw)
	if runtime.GOOS == "darwin" {
		body += fmt.Sprintf("\nIf Safari does not open it: http://127.0.0.1:%d/ in a private window kept for this editor, so pages from other VMs never get its cookie.\n", port)
	}
	if note != "" {
		body += "\n" + note + "\n"
	}
	s.ui.Box("VS Code", body)
}

// `code`: code-server for the project, in the foreground until Ctrl-C.
func (e *app) codeCmd(ctx context.Context, opts VMOpts, args []string) int {
	rest, tty, err := opts.split(args)
	if err != nil {
		fmt.Fprintf(e.io.Stderr, "Error: %v\n", err)
		return 1
	}
	if len(rest) > 0 || tty {
		a := "--tty"
		if len(rest) > 0 {
			a = rest[0]
		}
		fmt.Fprintf(e.io.Stderr, "Error: unknown argument for code: %s\nUsage: agent-vm [vm options] code\n", a)
		return 1
	}
	return e.inVM(ctx, opts, (*start).codeSession)
}

func (s *start) codeSession() int {
	ports := codePorts(s.name)
	args := []string{"zsh", "-lc", codePrep, "agent-vm-code"}
	for _, p := range ports {
		args = append(args, strconv.Itoa(p))
	}
	b, err := s.backend()
	if err != nil {
		return 1
	}
	var out strings.Builder
	code, err := b.Shell(s.ctx, s.name, vm.ShellOpts{Args: args, Stdin: strings.NewReader(""), Stdout: &out, Stderr: s.io.Stderr})
	if err != nil || code != 0 {
		s.warnf("Error: could not set up the editor's password in VM '%s'.", s.name)
		return 1
	}
	var cfg, pw, running string
	listening := map[string]bool{}
	for _, l := range strings.Split(out.String(), "\n") {
		switch {
		case l == "missing":
			s.warnf("Error: code-server is not installed in VM '%s'.\n  'agent-vm setup --preinstall=default,code-claude' (or code-server alone) adds it to the base, then 'agent-vm --reset code'\n  re-clones this VM (its disk is lost).", s.name)
			return 1
		case strings.HasPrefix(l, "config="):
			cfg = strings.TrimPrefix(l, "config=")
		case strings.HasPrefix(l, "password="):
			pw = strings.TrimPrefix(l, "password=")
		case strings.HasPrefix(l, "running="):
			running = strings.TrimPrefix(l, "running=")
		case strings.HasPrefix(l, "listening="):
			listening[strings.TrimPrefix(l, "listening=")] = true
		}
	}
	// Printed to the terminal: nothing the VM wrote may carry escape
	// sequences.
	if _, perr := strconv.Atoi(running); pw == "" || strings.IndexFunc(pw+cfg, unicode.IsControl) >= 0 || running != "" && perr != nil {
		s.warnf("Error: could not read the editor's password in VM '%s'.", s.name)
		return 1
	}
	if running != "" {
		p, _ := strconv.Atoi(running)
		s.codeSay(p, pw, fmt.Sprintf("The editor of VM '%s' already runs, from another terminal.", s.name))
		return 0
	}
	// The first port free both here and in the VM: Lima forwards the VM's
	// port to the same one here, and only when nothing holds it.
	port := 0
	for _, p := range ports {
		if !listening[strconv.Itoa(p)] && !hostPortOpen(p) {
			port = p
			break
		}
	}
	if port == 0 {
		var ps []string
		for _, p := range ports {
			ps = append(ps, strconv.Itoa(p))
		}
		s.warnf("Error: no free port for the editor among: %s ", strings.Join(ps, " "))
		return 1
	}
	s.codeSay(port, pw, "The password is kept in the VM, in "+cfg+". Ctrl-C stops the editor.")
	// A terminal for Ctrl-C to reach code-server: without one, it would
	// keep running in the VM once this command ends.
	tty := ui.IsTerminal(os.Stdin) && ui.IsTerminal(os.Stdout)
	// Bound to the VM's loopback, which Lima forwards to this machine's
	// only. The cookie suffix keeps sessions apart at 127.0.0.1.
	// --disable-proxy: no route from the browser to the VM's other ports;
	// VSCODE_PROXY_URI sends a link to localhost:<port> to that port here.
	// No experiments, and the built-in Copilot Chat never loads. Claude
	// Code's login pages open without the link prompt, those paths only.
	//
	// Not a full boundary between VMs: no VM reaches this port itself
	// (netguard), but any VM can listen on a port Lima forwards to this
	// machine, and a page it serves can send the browser, with this editor's
	// cookie, to a host name it chose.
	return s.lima(tty, "VSCODE_PROXY_URI=http://localhost:{{port}}/", "code-server",
		"--config", cfg,
		"--bind-addr", "127.0.0.1:"+strconv.Itoa(port),
		"--cookie-suffix", s.name,
		"--app-name", s.name,
		"--disable-telemetry",
		"--disable-update-check",
		"--disable-workspace-trust",
		"--disable-proxy",
		"--disable-getting-started-override",
		"--link-protection-trusted-domains", "https://claude.com/cai/oauth",
		"--link-protection-trusted-domains", "https://platform.claude.com/oauth",
		"--vscode-option", "disable-experiments",
		"--vscode-option", "disable-extension=GitHub.copilot-chat",
		paths.Guest(s.dir))
}
