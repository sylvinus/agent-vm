# sandbox

A small program that embeds [agentvm](../..): it runs a command in a disposable Linux VM of the current folder, with nothing of the machine shared but that folder.

```bash
go generate ./...            # the guest agent and Lima's templates, into assets/
go build -o sandbox .        # on macOS, then: codesign -f --entitlements vz.entitlements -s - sandbox
sandbox setup                # build the base VM, once
sandbox run make test        # run a command in this folder's VM
sandbox shell
sandbox rm
```

Its VMs and settings are in `~/.sandbox` (`$SANDBOX_STATE_DIR`), apart from agent-vm's own.

This module requires the released agent-vm and has no `replace`. In the agent-vm repository, `make test-example` builds it against the checkout, in a copy of its module, and runs its tests; `go test -tags e2e` boots a real VM.

The base VM must have what the engine expects of a guest (zsh, sudo, a `~/.zshenv` that sources `~/.agent-vm.env`): see `provision.Template`.

What it shows: `agentvm.RunHelper()` first in `main`; `Options` with `StateDir`, `AppName`, `Assets`, an `Asker` and an event callback; `Setup` with a `provision.Template`; `ProjectVM`, `Ensure` and `Exec`.
