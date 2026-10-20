// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package snapshot

import (
	"context"
	"fmt"

	"github.com/sylvinus/agent-vm/third_party/lima/pkg/driver"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/driverutil"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limayaml"
)

func Del(ctx context.Context, inst *limatype.Instance, tag string) error {
	limaDriver, err := createConfiguredDriver(ctx, inst)
	if err != nil {
		return fmt.Errorf("failed to create driver instance: %w", err)
	}

	return limaDriver.DeleteSnapshot(ctx, tag)
}

func Save(ctx context.Context, inst *limatype.Instance, tag string) error {
	limaDriver, err := createConfiguredDriver(ctx, inst)
	if err != nil {
		return fmt.Errorf("failed to create driver instance: %w", err)
	}
	return limaDriver.CreateSnapshot(ctx, tag)
}

func Load(ctx context.Context, inst *limatype.Instance, tag string) error {
	limaDriver, err := createConfiguredDriver(ctx, inst)
	if err != nil {
		return fmt.Errorf("failed to create driver instance: %w", err)
	}
	return limaDriver.ApplySnapshot(ctx, tag)
}

func List(ctx context.Context, inst *limatype.Instance) (string, error) {
	limaDriver, err := createConfiguredDriver(ctx, inst)
	if err != nil {
		return "", fmt.Errorf("failed to create driver instance: %w", err)
	}
	return limaDriver.ListSnapshots(ctx)
}

func createConfiguredDriver(ctx context.Context, inst *limatype.Instance) (*driver.ConfiguredDriver, error) {
	limaDriver, err := driverutil.CreateConfiguredDriver(ctx, inst, 0)
	if err != nil {
		return nil, fmt.Errorf("failed to create driver instance: %w", err)
	}
	if err := limayaml.Validate(inst.Config, true); err != nil {
		return nil, fmt.Errorf("failed to validate the instance YAML after filling defaults: %w", err)
	}
	return limaDriver, nil
}
