// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"github.com/spf13/cobra"

	"github.com/sylvinus/agent-vm/third_party/lima/pkg/guestagent/fakecloudinit"
)

func newFakeCloudInitCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "fake-cloud-init",
		Short: "Run fake cloud-init",
		RunE:  fakeCloudInitAction,
	}
	return cmd
}

func fakeCloudInitAction(cmd *cobra.Command, _ []string) error {
	ctx := cmd.Context()
	return fakecloudinit.Run(ctx)
}
