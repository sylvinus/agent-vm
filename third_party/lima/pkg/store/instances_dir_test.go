// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package store

import (
	"os"
	"path/filepath"
	"testing"

	"gotest.tools/v3/assert"

	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype/dirnames"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype/filenames"
)

func TestInstancesDir(t *testing.T) {
	home := t.TempDir()
	instances := t.TempDir()
	t.Setenv("LIMA_HOME", home)
	t.Setenv(dirnames.InstancesEnv, instances)
	realInstances, err := filepath.EvalSymlinks(instances)
	assert.NilError(t, err)

	dir, err := dirnames.InstanceDir("vm1")
	assert.NilError(t, err)
	assert.Equal(t, dir, filepath.Join(realInstances, "vm1", dirnames.InstanceSubdir))
	assert.Equal(t, dirnames.InstanceName(dir), "vm1")

	// A folder of the caller's without an instance folder is not an instance.
	assert.NilError(t, os.MkdirAll(filepath.Join(instances, "unfinished"), 0o755))
	assert.NilError(t, os.MkdirAll(filepath.Join(instances, "vm1", dirnames.InstanceSubdir), 0o755))
	assert.NilError(t, os.MkdirAll(filepath.Join(instances, "vm2", dirnames.InstanceSubdir), 0o755))
	// An instance in LIMA_HOME is not seen.
	assert.NilError(t, os.MkdirAll(filepath.Join(home, "vm3"), 0o755))

	names, err := Instances()
	assert.NilError(t, err)
	assert.DeepEqual(t, names, []string{"vm1", "vm2"})

	// Validate looks for lima.yaml in the instance folder.
	assert.ErrorContains(t, Validate(), filenames.LimaYAML)
	for _, n := range names {
		assert.NilError(t, os.WriteFile(filepath.Join(instances, n, dirnames.InstanceSubdir, filenames.LimaYAML), nil, 0o644))
	}
	assert.NilError(t, Validate())

	// LIMA_HOME keeps the rest.
	cfg, err := dirnames.LimaConfigDir()
	assert.NilError(t, err)
	assert.Equal(t, filepath.Dir(cfg), func() string { r, _ := filepath.EvalSymlinks(home); return r }())
}

func TestInstancesDirRelative(t *testing.T) {
	t.Setenv(dirnames.InstancesEnv, "relative/path")
	_, err := dirnames.InstanceDir("vm1")
	assert.ErrorContains(t, err, "absolute")
}

func TestInstancesDirUnset(t *testing.T) {
	home := t.TempDir()
	t.Setenv("LIMA_HOME", home)
	t.Setenv(dirnames.InstancesEnv, "")
	realHome, err := filepath.EvalSymlinks(home)
	assert.NilError(t, err)

	dir, err := dirnames.InstanceDir("vm1")
	assert.NilError(t, err)
	assert.Equal(t, dir, filepath.Join(realHome, "vm1"))
	assert.Equal(t, dirnames.InstanceName(dir), "vm1")
}
