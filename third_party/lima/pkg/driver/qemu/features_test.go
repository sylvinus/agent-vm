//go:build !windows

// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package qemu

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"gotest.tools/v3/assert"
)

// Each help text is its own: the features are searched as text, and a netdev
// list holding the accelerators' words would match them.
func TestInspectFeaturesOwnOutputs(t *testing.T) {
	exe := filepath.Join(t.TempDir(), "qemu-fake")
	script := `#!/bin/sh
case "$*" in
  *-cpu*) echo "cpus: max" ;;
  *-accel*) echo "accels: tcg" ;;
  *-netdev*) echo "netdevs: dgram" ;;
  *-machine*) echo "machines: virt" ;;
esac
`
	assert.NilError(t, os.WriteFile(exe, []byte(script), 0o755))
	f, err := inspectFeatures(context.Background(), exe, "virt")
	assert.NilError(t, err)
	assert.Equal(t, string(f.AccelHelp), "accels: tcg\n")
	assert.Equal(t, string(f.NetdevHelp), "netdevs: dgram\n")
	assert.Equal(t, string(f.MachineHelp), "machines: virt\n")
	assert.Equal(t, string(f.CPUHelp), "cpus: max\n")
}
