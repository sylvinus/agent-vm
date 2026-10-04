package runscript

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The host picks a script's shell with Interpreter, the guest with
// ShebangAWK: both must pick the same.
func FuzzInterpreter(f *testing.F) {
	if _, err := exec.LookPath("awk"); err != nil {
		f.Skip("no awk")
	}
	for _, s := range []string{"#!/bin/bash\n", "#!/usr/bin/env -S bash -e\r\n", "#! /bin/sh -x", "#!/usr/bin/env FOO=1 zsh", "echo hi", "#!env\n", "#!/bin/bash\tx"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		if strings.ContainsRune(s, 0) {
			return
		}
		p := filepath.Join(t.TempDir(), "s")
		if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
		out, err := exec.Command("awk", ShebangAWK, p).Output()
		if err != nil {
			return // input awk refuses (invalid bytes for its locale)
		}
		if g, a := Interpreter(s), strings.TrimSpace(string(out)); g != a {
			t.Fatalf("Interpreter(%q) = %q, the guest's awk %q", s, g, a)
		}
	})
}
