package runscript

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestProjectPath(t *testing.T) {
	dir := filepath.FromSlash("/p")
	for v, want := range map[string]string{
		"":                 filepath.Join(dir, ".agent-vm.runtime.sh"),
		".mytool/run.sh":   filepath.Join(dir, ".mytool", "run.sh"),
		"/etc/mytool/r.sh": filepath.FromSlash("/etc/mytool/r.sh"),
	} {
		t.Setenv("AGENT_VM_PROJECT_RUNTIME", v)
		if got := ProjectPath(dir); got != want {
			t.Errorf("%q: %q, want %q", v, got, want)
		}
	}
}

// The same answers as the awk program the VM runs.
func TestInterpreterAWK(t *testing.T) {
	if _, err := exec.LookPath("awk"); err != nil {
		t.Skip("no awk")
	}
	for _, c := range []string{
		"", "echo hi\n", "#!/bin/bash\n", "#!/bin/bash -e\n", "#!/bin/sh\r\n", "#!/usr/bin/env bash\n",
		"#!/usr/bin/env -S bash -e\n", "#!/usr/bin/env FOO=1 sh\n", "#!/usr/bin/env\n", "#!env -i\n", "#!\n",
		"#! /bin/bash\n", "#!/usr/bin/python3\n", "#!/bin/zsh\n", "#!/bin/bash", "#!/opt/x/env\n", "#!\tsh\n",
		"#!/usr/bin/env -S\n", "#!/bin/dash\n", " #!/bin/bash\n",
	} {
		f := filepath.Join(t.TempDir(), "s")
		os.WriteFile(f, []byte(c), 0o644)
		out, err := exec.Command("awk", ShebangAWK, f).Output()
		if err != nil {
			t.Fatal(err)
		}
		if got := Interpreter(c); got != strings.TrimSuffix(string(out), "\n") {
			t.Errorf("Interpreter(%q) = %q, awk %q", c, got, out)
		}
	}
}
