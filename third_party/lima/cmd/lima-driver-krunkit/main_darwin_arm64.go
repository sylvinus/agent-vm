// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"

	"github.com/sylvinus/agent-vm/third_party/lima/pkg/driver/external/server"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/driver/krunkit"
)

// To be used as an external driver for Lima.
func main() {
	server.Serve(context.Background(), krunkit.New())
}
