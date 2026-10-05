package runscript

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/paths"
)

func TestProjectPath(t *testing.T) {
	// Both spellings, on every host: backslashes never reach here, the
	// callers pass the project dir Host-spelled.
	for _, win := range []bool{false, true} {
		old := paths.Windows
		paths.Windows = func() bool { return win }
		dir := "/p"
		if win {
			dir = "C:/p"
		}
		for v, want := range map[string]string{
			"":                 dir + "/.agent-vm.runtime.sh",
			".mytool/run.sh":   dir + "/.mytool/run.sh",
			"/etc/mytool/r.sh": "/etc/mytool/r.sh",
		} {
			t.Setenv("AGENT_VM_PROJECT_RUNTIME", v)
			if got := ProjectPath(dir); got != want {
				t.Errorf("windows=%v %q: %q, want %q", win, v, got, want)
			}
		}
		paths.Windows = old
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
