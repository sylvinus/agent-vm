// Package runscript is the runtime scripts: ~/.agent-vm/runtime.sh and a
// project's .agent-vm.runtime.sh, run in the VM on every command that enters
// it, under the shell their shebang names.
package runscript

import (
	"os"
	"strings"

	"github.com/sylvinus/agent-vm/internal/env"
)

// ShebangAWK reads the interpreter a script asks for: bash or sh, zsh
// otherwise. Only shells: the script is fed on stdin, read with -s. The
// program is the shebang's first word ("#!/bin/bash -e"), or after env, its
// options and assignments ("#!/usr/bin/env -S bash -e"). The VM runs it on a
// project's script, which only the VM reads: keep it as it is.
const ShebangAWK = `
  NR == 1 {
    sub(/\r$/, "")
    if (substr($0, 1, 2) == "#!") {
      n = split(substr($0, 3), w)
      for (i = 1; i < n; i++)
        if (w[i] != "env" && w[i] !~ /\/env$/ && w[i] !~ /^-/ && w[i] !~ /=/) break
      p = w[i]
      sub(/.*\//, "", p)
    }
    exit
  }
  END { print ((p == "bash" || p == "sh") ? p : "zsh") }
`

// StripCRAWK drops the CR ending each line, in the VM.
const StripCRAWK = `{ sub(/\r$/, ""); print }`

// Interpreter is the shell content's shebang asks for, as ShebangAWK reads
// it.
func Interpreter(content string) string {
	first, _, _ := strings.Cut(content, "\n")
	first = strings.TrimSuffix(first, "\r")
	p := ""
	if rest, ok := strings.CutPrefix(first, "#!"); ok {
		w := strings.FieldsFunc(rest, func(r rune) bool { return r == ' ' || r == '\t' })
		i := 0
		for ; i < len(w)-1; i++ {
			if w[i] != "env" && !strings.HasSuffix(w[i], "/env") && !strings.HasPrefix(w[i], "-") && !strings.Contains(w[i], "=") {
				break
			}
		}
		if i < len(w) {
			p = w[i][strings.LastIndexByte(w[i], '/')+1:]
		}
	}
	if p == "bash" || p == "sh" {
		return p
	}
	return "zsh"
}

// ProjectPath is the project dir's runtime script (see env.ProjectPath).
func ProjectPath(dir string) string {
	p := os.Getenv("AGENT_VM_PROJECT_RUNTIME")
	if p == "" {
		p = ".agent-vm.runtime.sh"
	}
	return env.ProjectPath(dir, p)
}
