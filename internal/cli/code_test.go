package cli

import (
	"fmt"
	"strconv"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/bashref"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

func TestCodePortsHostBash(t *testing.T) {
	for _, n := range []string{"proj-0000270f", "proj-ffffffff", "proj-00000000", "noHash", strings.Repeat("Long", 20) + "-abcdef12"} {
		var ps []string
		for _, p := range codePorts(n) {
			ps = append(ps, strconv.Itoa(p))
		}
		r := bashref.Run(t, "", nil, "_agent_vm_code_ports", n)
		if strings.Join(ps, " ")+" " != r.Stdout {
			t.Errorf("codePorts(%q) = %v, bash %q", n, ps, r.Stdout)
		}
		r = bashref.Run(t, "", nil, "_agent_vm_code_host", n)
		if codeHost(n)+"\n" != r.Stdout {
			t.Errorf("codeHost(%q) = %q, bash %q", n, codeHost(n), r.Stdout)
		}
	}
}

func TestCode(t *testing.T) {
	se := newStartEnv(t)
	se.base()
	name := vmname.Name(se.proj)
	answer := "missing\n"
	var started []string
	se.fake.ShellFunc = func(n string, o vm.ShellOpts) int {
		if len(o.Args) > 2 && o.Args[2] == codePrep {
			fmt.Fprint(o.Stdout, answer)
			return 0
		}
		if strings.Contains(strings.Join(o.Args, " "), "code-server --config") {
			started = o.Args
			return 0
		}
		return se.g.shell(n, o)
	}
	if se.run("code") != 1 || !strings.Contains(se.out(), "code-server is not installed in VM") {
		t.Errorf("missing: %s", se.out())
	}
	ports := codePorts(name)
	answer = fmt.Sprintf("config=/home/u/.config/code-server/agent-vm-h.yaml\npassword=s3cret\nlistening=%d\n", ports[0])
	if se.run("code") != 0 {
		t.Fatalf("code: %s", se.out())
	}
	want := fmt.Sprintf("Address:   http://%s:%d/", codeHost(name), ports[1])
	if !strings.Contains(se.out(), want) || !strings.Contains(se.out(), "Password:  s3cret") {
		t.Errorf("box: %s", se.out())
	}
	args := strings.Join(started, " ")
	for _, w := range []string{"--bind-addr 127.0.0.1:" + strconv.Itoa(ports[1]), "--cookie-suffix " + name, "--app-name " + name, "--disable-proxy",
		"--config /home/u/.config/code-server/agent-vm-h.yaml", "--disable-telemetry", "--disable-update-check", "--disable-workspace-trust",
		"--disable-getting-started-override", "--link-protection-trusted-domains https://claude.com/cai/oauth",
		"--link-protection-trusted-domains https://platform.claude.com/oauth", "--vscode-option disable-experiments",
		"--vscode-option disable-extension=GitHub.copilot-chat", "VSCODE_PROXY_URI=http://localhost:{{port}}/", se.proj} {
		if !strings.Contains(args, w) {
			t.Errorf("missing %q in %s", w, args)
		}
	}
	answer = "config=/c.yaml\npassword=x\nrunning=23456\n"
	started = nil
	if se.run("code") != 0 || !strings.Contains(se.out(), "already runs, from another") || !strings.Contains(se.out(), ":23456/") || started != nil {
		t.Errorf("running: %s", se.out())
	}
	answer = "config=/c.yaml\npassword=a\033]0;x\007\n"
	if se.run("code") != 1 || !strings.Contains(se.out(), "could not read the editor's password") {
		t.Errorf("control characters: %s", se.out())
	}
	if se.run("code", "x") != 1 || !strings.Contains(se.out(), "unknown argument for code: x") {
		t.Errorf("argument: %s", se.out())
	}
}
