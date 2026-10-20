# Backlog

Known gaps and ideas, not on the website.

## Windows, natively

Status: built, not yet tried.

agent-vm runs on Windows without Git Bash now, its paths handled as `C:/...`
and seen by the VM as `/c/...`, as in 0.2, and its tests run on any OS. Nothing
of it has run on a Windows machine yet: setup, the shares, the network
isolation, the port check.

## Review the agent's writes

Status: idea.

Every write of the VM goes through agent-vm's SFTP server. It could keep them
aside and let you review the diff, and apply all or part of it to the real
folder. A first step: the list of every path the VM wrote during a session.

## Run a VM inside the VM

Status: needs an M3.

A `--allow-nested-vm` flag, for testing VM tooling from in there. Lima supports
nested virtualization, but it is off by default and cannot be turned on
unconditionally: below an Apple M3, Lima fails to start the VM instead of
degrading, so every VM would stop starting. The flag would have to detect host
support first. Nothing here has an M3 to test it on. It would also hand the
agent a hypervisor interface.

## krunkit on macOS

Status: vendored, not wired in.

The Lima in `third_party/` has a krunkit driver (macOS arm64) that nothing here
imports. It runs `krunkit`, a program of its own (Homebrew): agent-vm would no
longer be one binary there, and `doctor` would check it. Templates would be per
driver (`vms/base`, `vms/base-krunkit`; `base-*` is reserved, and `base.name` in
`metadata.json` says which), and the driver is Lima's `vmType`, which a VM
changes with `--reset` only. To check when it is wired in: patch
`lima/0005-network-isolation-hooks` changes `usernet/gvproxy.go`, the host agent
and the qemu driver, and krunkit calls `usernet.StartGVisorNetstack` itself; its
socket names against `vm.MaxName`; and a separate process with GPU passthrough
gives the guest more of the host to reach than vz does.

## Disk space of the VMs

Status: ideas, by value.

Lima clones with `clonefile` on APFS, so VMs share the base's blocks until they
write their own; `copy_file_range` on Linux shares blocks on btrfs and XFS with
reflink, and copies the data on ext4. A new base shares nothing with the VMs of
the old one, until `--reset`.

1. `list` could show the space a VM uses (allocated blocks), not its disk's size.
2. ext4: a qemu VM's disk as a qcow2 overlay on its base's, the bases kept while
   a VM uses them. qemu only.
3. Giving back the space of deleted files needs discard through the virtual disk
   and `fstrim` in the guest: to check for vz and krunkit.

Not proposed: caches written by several VMs (Docker images, npm), which let one
project's VM plant files another one uses. Read-only shared caches are fine.

## Run the VMs on another machine

Status: designed, not built.

One install on your laptop driving VMs on a box you rent. Close the laptop, the
agent keeps working. Open questions: addressing a VM by name rather than by
working directory, and who owns deleting a workspace.
