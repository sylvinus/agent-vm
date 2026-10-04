// Package agentvm holds the files of this repository the binary embeds.
package agentvm

import _ "embed"

// SetupScript provisions the base VM: `agent-vm setup` runs it in the guest,
// after the choices as export lines.
//
//go:embed agent-vm.setup.sh
var SetupScript string
