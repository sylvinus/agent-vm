//go:build !external_qemu

// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

// Copied from third_party/lima/cmd/limactl: the drivers limactl has.
package vm

// Import qemu driver to register it in the registry on all platforms.
import _ "github.com/lima-vm/lima/v2/pkg/driver/qemu"
