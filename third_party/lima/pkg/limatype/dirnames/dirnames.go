// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package dirnames

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/sylvinus/agent-vm/third_party/lima/pkg/identifiers"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype/filenames"
)

// DotLima is a directory that appears under the home directory.
const DotLima = ".lima"

// LimaDir returns the absolute path of `~/.lima` (or $LIMA_HOME, if set).
//
// NOTE: We do not use `~/Library/Application Support/Lima` on macOS.
// We use `~/.lima` so that we can have enough space for the length of the socket path,
// which can be only 104 characters on macOS.
func LimaDir() (string, error) {
	dir := os.Getenv("LIMA_HOME")
	if dir == "" {
		homeDir, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		dir = filepath.Join(homeDir, DotLima)
	}
	if _, err := os.Stat(dir); errors.Is(err, os.ErrNotExist) {
		return dir, nil
	}
	realdir, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return "", fmt.Errorf("cannot evaluate symlinks in %#q: %w", dir, err)
	}
	return realdir, nil
}

// LimaConfigDir returns the path of the config directory, $LIMA_HOME/_config.
func LimaConfigDir() (string, error) {
	limaDir, err := LimaDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(limaDir, filenames.ConfigDir), nil
}

// LimaNetworksDir returns the path of the networks log directory, $LIMA_HOME/_networks.
func LimaNetworksDir() (string, error) {
	limaDir, err := LimaDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(limaDir, filenames.NetworksDir), nil
}

// LimaDisksDir returns the path of the disks directory, $LIMA_HOME/_disks.
func LimaDisksDir() (string, error) {
	limaDir, err := LimaDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(limaDir, filenames.DisksDir), nil
}

// LimaTemplatesDir returns the path of the templates directory, $LIMA_HOME/_templates.
func LimaTemplatesDir() (string, error) {
	limaDir, err := LimaDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(limaDir, filenames.TemplatesDir), nil
}

// InstancesEnv is the environment variable that moves the instances out of
// $LIMA_HOME. When it is set, the instance NAME is in
// $LIMA_INSTANCES_DIR/NAME/InstanceSubdir, and a program embedding Lima can
// keep its own files for NAME in $LIMA_INSTANCES_DIR/NAME. $LIMA_HOME keeps
// the rest (_config, _networks, _disks, _templates).
const InstancesEnv = "LIMA_INSTANCES_DIR"

// InstanceSubdir is the instance's folder in $LIMA_INSTANCES_DIR/NAME.
const InstanceSubdir = "lima"

// InstancesDir returns the absolute path of $LIMA_INSTANCES_DIR, or "" when
// it is not set and the instances are in LimaDir.
func InstancesDir() (string, error) {
	dir := os.Getenv(InstancesEnv)
	if dir == "" {
		return "", nil
	}
	if !filepath.IsAbs(dir) {
		return "", fmt.Errorf("$%s must be an absolute path, got %#q", InstancesEnv, dir)
	}
	if _, err := os.Stat(dir); errors.Is(err, os.ErrNotExist) {
		return dir, nil
	}
	realdir, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return "", fmt.Errorf("cannot evaluate symlinks in %#q: %w", dir, err)
	}
	return realdir, nil
}

// InstanceDir returns the instance dir.
// InstanceDir does not check whether the instance exists.
func InstanceDir(name string) (string, error) {
	if err := ValidateInstName(name); err != nil {
		return "", err
	}
	instances, err := InstancesDir()
	if err != nil {
		return "", err
	}
	if instances != "" {
		return filepath.Join(instances, name, InstanceSubdir), nil
	}
	limaDir, err := LimaDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(limaDir, name)
	return dir, nil
}

// InstanceName returns the name of the instance whose dir is instDir.
func InstanceName(instDir string) string {
	if os.Getenv(InstancesEnv) != "" {
		return filepath.Base(filepath.Dir(instDir))
	}
	return filepath.Base(instDir)
}

// ValidateInstName checks if the name is a valid instance name. For this it needs to
// be a valid identifier, and not end in .yml or .yaml (case insensitively).
func ValidateInstName(name string) error {
	if err := identifiers.Validate(name); err != nil {
		return fmt.Errorf("instance name %#q is not a valid identifier: %w", name, err)
	}
	lower := strings.ToLower(name)
	if strings.HasSuffix(lower, ".yml") || strings.HasSuffix(lower, ".yaml") {
		return fmt.Errorf("instance name %#q must not end with .yml or .yaml suffix", name)
	}
	return nil
}
