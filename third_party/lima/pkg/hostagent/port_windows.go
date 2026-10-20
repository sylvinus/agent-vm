// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package hostagent

import (
	"context"

	"github.com/sylvinus/agent-vm/third_party/sshocker/pkg/ssh"
)

func forwardTCP(ctx context.Context, sshConfig *ssh.SSHConfig, sshAddress string, sshPort int, local, remote, verb string) error {
	return forwardSSH(ctx, sshConfig, sshAddress, sshPort, local, remote, verb, false)
}
