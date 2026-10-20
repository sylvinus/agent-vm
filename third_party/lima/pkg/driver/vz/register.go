//go:build darwin && !no_vz && !external_vz

// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package vz

import (
	"context"

	"github.com/sylvinus/agent-vm/third_party/lima/pkg/registry"
)

func init() {
	registry.Register(context.Background(), New())
}
