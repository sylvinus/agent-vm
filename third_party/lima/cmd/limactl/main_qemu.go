//go:build !external_qemu

// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package main

// Import qemu driver to register it in the registry on all platforms.
import _ "github.com/sylvinus/agent-vm/third_party/lima/pkg/driver/qemu"
