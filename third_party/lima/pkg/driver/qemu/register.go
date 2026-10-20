//go:build !external_qemu

// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package qemu

import (
	"context"

	"github.com/sylvinus/agent-vm/third_party/lima/pkg/registry"
)

func init() {
	registry.Register(context.Background(), New())
}
