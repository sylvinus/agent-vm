// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package store

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/sylvinus/agent-vm/third_party/lima/pkg/driverutil"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/identifiers"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype/dirnames"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype/filenames"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limayaml"
)

// Directory returns the LimaDir.
func Directory() string {
	limaDir, err := dirnames.LimaDir()
	if err != nil {
		return ""
	}
	return limaDir
}

// Validate checks the LimaDir.
func Validate() error {
	names, err := Instances()
	if err != nil {
		return err
	}
	for _, name := range names {
		// Each instance directory needs to have limayaml
		instDir, err := dirnames.InstanceDir(name)
		if err != nil {
			return err
		}
		yamlPath := filepath.Join(instDir, filenames.LimaYAML)
		if _, err := os.Stat(yamlPath); err != nil {
			return err
		}
	}
	return nil
}

// Instances returns the names of the instances under LimaDir, or under
// $LIMA_INSTANCES_DIR when it is set (see dirnames.InstancesEnv): there, a
// folder without an instance folder in it is not one.
func Instances() ([]string, error) {
	instancesDir, err := dirnames.InstancesDir()
	if err != nil {
		return nil, err
	}
	limaDir := instancesDir
	if limaDir == "" {
		if limaDir, err = dirnames.LimaDir(); err != nil {
			return nil, err
		}
	}
	limaDirList, err := os.ReadDir(limaDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var names []string
	for _, f := range limaDirList {
		if strings.HasPrefix(f.Name(), ".") || strings.HasPrefix(f.Name(), "_") {
			continue
		}
		if !f.IsDir() {
			continue
		}
		if instancesDir != "" {
			if st, err := os.Stat(filepath.Join(limaDir, f.Name(), dirnames.InstanceSubdir)); err != nil || !st.IsDir() {
				continue
			}
		}
		names = append(names, f.Name())
	}
	return names, nil
}

func Disks() ([]string, error) {
	limaDiskDir, err := dirnames.LimaDisksDir()
	if err != nil {
		return nil, err
	}
	limaDiskDirList, err := os.ReadDir(limaDiskDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var names []string
	for _, f := range limaDiskDirList {
		names = append(names, f.Name())
	}
	return names, nil
}

func DiskDir(name string) (string, error) {
	if err := identifiers.Validate(name); err != nil {
		return "", err
	}
	limaDisksDir, err := dirnames.LimaDisksDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(limaDisksDir, name)
	return dir, nil
}

// LoadYAMLByFilePath loads and validates the yaml.
func LoadYAMLByFilePath(ctx context.Context, filePath string) (*limatype.LimaYAML, error) {
	// We need to use the absolute path because it may be used to determine hostSocket locations.
	absPath, err := filepath.Abs(filePath)
	if err != nil {
		return nil, err
	}
	yContent, err := os.ReadFile(absPath)
	if err != nil {
		return nil, err
	}
	y, err := limayaml.Load(ctx, yContent, absPath)
	if err != nil {
		return nil, err
	}
	// If VMType is not specified, we go with the default platform driver.
	if err := driverutil.ResolveVMType(y); err != nil {
		return nil, errors.Join(errors.New("failed to resolve vm for "+absPath), err)
	}
	if err := limayaml.Validate(y, false); err != nil {
		return nil, err
	}
	return y, nil
}
