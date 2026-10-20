// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package instance

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/sylvinus/agent-vm/third_party/lima/pkg/cidata"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/driver/external/server"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/driverutil"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype/dirnames"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype/filenames"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limayaml"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/osutil"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/store"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/version"
)

func Create(ctx context.Context, instName string, instConfig []byte, saveBrokenYAML bool) (*limatype.Instance, error) {
	if instName == "" {
		return nil, errors.New("got empty instName")
	}
	if len(instConfig) == 0 {
		return nil, errors.New("got empty instConfig")
	}

	instDir, err := dirnames.InstanceDir(instName)
	if err != nil {
		return nil, err
	}

	// the full path of the socket name must be less than UNIX_PATH_MAX chars.
	maxSockName := filepath.Join(instDir, filenames.LongestSock)
	if len(maxSockName) >= osutil.UnixPathMax {
		return nil, fmt.Errorf("instance name %#q too long: %#q must be less than UNIX_PATH_MAX=%d characters, but is %d",
			instName, maxSockName, osutil.UnixPathMax, len(maxSockName))
	}
	if _, err := os.Stat(instDir); !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("instance %#q already exists (%#q)", instName, instDir)
	}
	// limayaml.Load() needs to pass the store file path to limayaml.FillDefault() to calculate default MAC addresses
	filePath := filepath.Join(instDir, filenames.LimaYAML)
	loadedInstConfig, err := limayaml.LoadWithWarnings(ctx, instConfig, filePath)
	if err != nil {
		return nil, err
	}
	// If VMType is not specified, we go with the default platform driver.
	if err := driverutil.ResolveVMType(loadedInstConfig); err != nil {
		return nil, err
	}
	if err := limayaml.Validate(loadedInstConfig, false); err != nil {
		if !saveBrokenYAML {
			return nil, err
		}
		rejectedYAML := "lima.REJECTED.yaml"
		if writeErr := os.WriteFile(rejectedYAML, instConfig, 0o644); writeErr != nil {
			return nil, fmt.Errorf("the YAML is invalid, attempted to save the buffer as %#q but failed: %w: %w", rejectedYAML, writeErr, err)
		}
		return nil, fmt.Errorf("the YAML is invalid, saved the buffer as %#q: %w", rejectedYAML, err)
	}
	if err := os.MkdirAll(instDir, 0o700); err != nil {
		return nil, err
	}
	var createSucceeded bool
	defer func() {
		server.Stop(instDir, true)
		if !createSucceeded {
			_ = os.RemoveAll(instDir)
		}
	}()

	if err := os.WriteFile(filePath, instConfig, 0o644); err != nil {
		return nil, err
	}
	if err := os.WriteFile(filepath.Join(instDir, filenames.LimaVersion), []byte(version.Version), 0o444); err != nil {
		return nil, err
	}

	inst, err := store.Inspect(ctx, instName)
	if err != nil {
		return nil, err
	}

	limaDriver, err := driverutil.CreateConfiguredDriver(ctx, inst, 0)
	if err != nil {
		return nil, fmt.Errorf("failed to create driver instance: %w", err)
	}
	if err := limayaml.Validate(inst.Config, true); err != nil {
		if !saveBrokenYAML {
			return nil, err
		}
		rejectedYAML := "lima.REJECTED.yaml"
		if writeErr := os.WriteFile(rejectedYAML, instConfig, 0o644); writeErr != nil {
			return nil, fmt.Errorf("the YAML is invalid, attempted to save the buffer as %#q but failed: %w: %w", rejectedYAML, writeErr, err)
		}
		return nil, fmt.Errorf("the YAML is invalid, saved the buffer as %#q: %w", rejectedYAML, err)
	}
	if err := cidata.GenerateCloudConfig(ctx, instDir, instName, inst.Config); err != nil {
		return nil, err
	}

	if err := limaDriver.Create(ctx); err != nil {
		return nil, err
	}

	createSucceeded = true
	return inst, nil
}
