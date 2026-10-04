//go:build !external_wsl2

// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

// Copied from third_party/lima/cmd/limactl: the drivers limactl has.
package vm

// Import wsl2 driver to register it in the registry on windows.
import _ "github.com/lima-vm/lima/v2/pkg/driver/wsl2"
