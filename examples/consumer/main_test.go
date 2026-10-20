package main

import (
	"bytes"
	"os"
	"strings"
	"testing"

	agentvm "github.com/sylvinus/agent-vm"
)

// Lima starts the test binary again as a host agent: the first thing a main,
// and a TestMain, does.
func TestMain(m *testing.M) {
	agentvm.RunHelper()
	os.Exit(m.Run())
}

func TestUsage(t *testing.T) {
	t.Setenv("SANDBOX_STATE_DIR", t.TempDir())
	for _, c := range []struct {
		args []string
		want string
	}{
		{nil, "usage: sandbox"},
		{[]string{"frobnicate"}, `unknown command "frobnicate"`},
		{[]string{"run"}, "usage: sandbox run"},
	} {
		var stdout, stderr bytes.Buffer
		if code := run(c.args, strings.NewReader(""), &stdout, &stderr); code != 2 || !strings.Contains(stderr.String(), c.want) {
			t.Errorf("%q: %d %q", c.args, code, stderr.String())
		}
	}
}

// Before setup there is no base VM: said, and told how to go on, without
// Lima having started a VM.
func TestRunWithoutSetup(t *testing.T) {
	t.Setenv("SANDBOX_STATE_DIR", t.TempDir())
	var stdout, stderr bytes.Buffer
	code := run([]string{"run", "true"}, strings.NewReader(""), &stdout, &stderr)
	if code != 1 || !strings.Contains(stderr.String(), "Run 'sandbox setup' first.") || !strings.Contains(stderr.String(), "sandbox: run 'sandbox setup' first") {
		t.Errorf("%d %q", code, stderr.String())
	}
}
