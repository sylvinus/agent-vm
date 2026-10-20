package agentvm

import (
	_ "embed"

	"github.com/sylvinus/agent-vm/provision"
)

// SetupScript provisions the base VM: `agent-vm setup` runs it in the guest,
// after the choices as export lines.
var SetupScript = provision.AgentVMScript()

// The license of agent-vm, the notice about third_party/, and the licenses of
// what the binary is built from (scripts/licenses): `agent-vm licenses`.
var (
	//go:embed LICENSE
	License string
	//go:embed NOTICE
	Notice string
	//go:embed THIRD_PARTY_LICENSES
	ThirdPartyLicenses string
)
