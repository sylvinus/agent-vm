package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/bashref"
	"github.com/sylvinus/agent-vm/internal/version"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

func run(t *testing.T, args ...string) bashref.Result {
	t.Helper()
	var stdout, stderr bytes.Buffer
	code := Main(args, IO{Stdin: strings.NewReader(""), Stdout: &stdout, Stderr: &stderr})
	return bashref.Result{Stdout: stdout.String(), Stderr: stderr.String(), Code: code}
}

// bashAgentVM runs 0.2's agent-vm with args, in dir, with a limactl on PATH
// (it checks for one before most commands; Lima is built in here).
func bashAgentVM(t *testing.T, dir string, args ...string) bashref.Result {
	t.Helper()
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "limactl"), []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return bashref.Script(t, dir, []string{"PATH=" + bin + ":" + os.Getenv("PATH")}, `agent-vm "$@"`, args...)
}

// Same output and status as 0.2, with this build's version set to 0.2's.
func TestMainBash(t *testing.T) {
	saved := version.Version
	t.Cleanup(func() { version.Version = saved })
	version.Version = strings.TrimSpace(bashref.Script(t, "", nil, `echo "$AGENT_VM_VERSION"`).Stdout)

	proj := t.TempDir()
	t.Chdir(proj)
	t.Setenv("PWD", proj)
	cases := [][]string{
		{"version"}, {"--version"}, {"-V"},
		{"version", "--min", "0.1.0"}, {"version", "--min=0.2.1"}, {"version", "--min", "0.10.0"},
		{"version", "--min"}, {"version", "--min", "x"}, {"version", "--min", ""}, {"version", "--max", "1"},
		{"version", "--min", "1.2.3-rc.1"},
		{"name"}, {"name", proj}, {"name", "."}, {"name", proj + "/missing"},
		{"frobnicate"},
		{"--disk"}, {"--disk", "10G", "claude"}, {"--disk=0", "shell"}, {"--memory", "-1"}, {"--ram=x"},
		{"--cpus", "01"}, {"--ssh-port", "80"}, {"--ssh-port", "70000"}, {"--ssh-port=00"},
		{"--readonly", "stop"}, {"--disk", "10", "--rm", "list"}, {"--rm", "version"}, {"--scratch", "help"},
		{"--unsafe-writable-git=1", "name"}, {"--unsafe-disable-security-prompts", "doctor"},
	}
	// How to update depends on how each copy was installed.
	update := regexp.MustCompile(`(?m)^  Update it:  .*$`)
	hash := regexp.MustCompile(`(?m)-[0-9a-f]{8}$`)
	for _, args := range cases {
		want := bashAgentVM(t, proj, args...)
		got := run(t, args...)
		want.Stderr = update.ReplaceAllString(want.Stderr, "  Update it:")
		got.Stderr = update.ReplaceAllString(got.Stderr, "  Update it:")
		// 0.3's names drop 0.2's prefix. The hash is of the folder bash had
		// (TestNameBash compares hashes).
		if args[0] == "name" {
			want.Stdout = strings.TrimPrefix(want.Stdout, vmname.OldPrefix)
			want.Stdout = hash.ReplaceAllString(want.Stdout, "-HASH")
			got.Stdout = hash.ReplaceAllString(got.Stdout, "-HASH")
		}
		if got.Stdout != want.Stdout || got.Stderr != want.Stderr || got.Code != want.Code {
			t.Errorf("agent-vm %q:\n go:   %+v\n bash: %+v", args, got, want)
		}
	}
}

// The help is 0.2's, but for what Lima built in changed (CHANGELOG).
func TestHelp(t *testing.T) {
	want := bashref.Run(t, "", nil, "_agent_vm_help").Stdout
	for _, args := range [][]string{{}, {"help"}, {"--help"}, {"-h"}} {
		r := run(t, args...)
		if r.Code != 0 || r.Stdout != helpText || r.Stderr != "" {
			t.Errorf("%q: %+v", args, r)
		}
	}
	strip := func(s string) string {
		s = strings.Replace(s, "agent-vm rm agent-vm-old-name-1a2b3c4d     ", "agent-vm rm old-name-1a2b3c4d              ", 1)
		for _, cut := range []string{
			"AGENT_VM_BIN_DIR). Run it from the clone:\n                     ./agent-vm.sh install\n",
			"AGENT_VM_BIN_DIR)\n",
			"  ~/.agent-vm/network               What the VMs may reach (above)\n",
			"  ~/.agent-vm/guarded               More files to ask about (above)\n",
		} {
			s = strings.Replace(s, cut, "", 1)
		}
		// Network isolation and guarded files are new.
		if before, rest, ok := strings.Cut(s, "The VMs reach the internet"); ok {
			_, after, _ := strings.Cut(rest, "Both files are read when a VM starts.\n\n")
			s = before + after
		}
		before, _, _ := strings.Cut(s, "Every .git in the shared folders")
		_, after, _ := strings.Cut(s, "A VM that already runs gets the warnings only")
		return before + after
	}
	if strip(helpText) != strip(want) {
		t.Error("the help differs from 0.2's beyond the Lima paragraphs and install")
	}
	if strings.Contains(helpText, "Lima build") || strings.Contains(helpText, "agent-vm.sh") {
		t.Error("the help still offers a Lima build or the clone")
	}
}

func TestSplit(t *testing.T) {
	for _, c := range []struct {
		in   []string
		cmd  []string
		tty  bool
		opts VMOpts
	}{
		{[]string{"docker", "run", "--rm", "x"}, []string{"docker", "run", "--rm", "x"}, false, newVMOpts()},
		{[]string{"--rm", "--tty", "htop"}, []string{"htop"}, true, VMOpts{RM: true, SSHPort: -1}},
		{[]string{"--disk=5", "--", "--rm"}, []string{"--rm"}, false, VMOpts{Disk: 5, SSHPort: -1}},
		{[]string{"--ssh-port", "0", "--ram", "4", "x"}, []string{"x"}, false, VMOpts{Memory: 4, SSHPort: 0}},
		{[]string{"--readonly", "--scratch", "--reset", "--unsafe-writable-git", "--unsafe-disable-security-prompts"}, []string{}, false,
			VMOpts{ReadOnly: true, Scratch: true, Reset: true, UnsafeWritableGit: true, UnsafeNoPrompts: true, SSHPort: -1}},
	} {
		opts := newVMOpts()
		cmd, tty, err := opts.split(c.in)
		if err != nil || strings.Join(cmd, " ") != strings.Join(c.cmd, " ") || tty != c.tty || opts != c.opts {
			t.Errorf("split(%q) = %q, %v, %+v, %v", c.in, cmd, tty, opts, err)
		}
	}
}
