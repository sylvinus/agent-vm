module github.com/sylvinus/agent-vm/examples/consumer

go 1.26.9

// No replace: this module builds against the agent-vm it requires, patched
// Lima included. In this repository it builds in a workspace with the root
// module (make test-example); once agent-vm 0.4.0 is released, `go mod tidy`
// pins it.
require github.com/sylvinus/agent-vm v0.4.0
