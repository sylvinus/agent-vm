//go:build !external_wsl2

// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package main

// Import wsl2 driver to register it in the registry on windows.
import _ "github.com/sylvinus/agent-vm/third_party/lima/pkg/driver/wsl2"
