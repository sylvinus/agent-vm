# 0.4.0 design

Status: built, except for what "As built" (at the end) lists. The sections
below are the design as proposed; "As built" says where the code differs and
what it settled.

0.4.0 changes where agent-vm keeps its VMs, splits the CLI from what it
drives, and makes that a Go library another tool can build on. Named VMs and
VMs with no shares come on top of it.

Order of work, each step shippable and tested on its own:

1. Vendor the patched dependencies under agent-vm's module path.
2. One folder per VM: `~/.agent-vm/vms/<name>/`, with the 0.3.0 migration.
3. `internal/engine`: the start sequence without terminal I/O.
4. The public packages, the CLI as their first consumer.
5. `--name` and `--no-shares`.

## 1. Vendoring

Today `third_party/` holds four modules (Lima, sshocker, pkg/sftp,
gvisor-tap-vsock), each its upstream commit plus `patches/`, wired in with
`replace`. A `replace` only applies in the main module: a tool importing
agent-vm would build against upstream, without the patches (read-only
`.git` names, network isolation, the SFTP fixes). Copying our `replace`
lines into every consumer is fragile, and breaks `go install` for it.

They become packages of `github.com/sylvinus/agent-vm`:

- `scripts/third-party-sync` builds each tree as upstream, then `patches/`,
  then an import rewrite (`github.com/lima-vm/lima/v2` to
  `github.com/sylvinus/agent-vm/third_party/lima`, and so on). `--check`
  checks the result, rewrite included. Patches stay written against
  upstream's paths, so they can still go upstream.
- The four `third_party/*/go.mod` go: their requirements move into ours. The
  `replace` block and the `tool` directives go: the guest agent builds from
  `./third_party/lima/cmd/lima-guestagent`.
- The `-X` path of Lima's version in the Makefile and `flake.nix` changes,
  and `scripts/licenses` follows.
- Lima's `gomodjail` annotations in its `go.mod` are lost, and with them
  `make gomodjail`, Lima's static check that the modules marked confined
  reach no denied capability. agent-vm does not run it today.
- A consumer that also imports upstream Lima gets two copies under two
  paths: slower to build, no conflict.

Each patched tree gets a constant naming its patch level (for Lima,
`AgentVMPatches = "lima-5"`), which the engine refers to: a tree without the
patches does not compile.

## 2. One folder per VM

```
~/.agent-vm/
  env, volumes, network, guarded, setup.sh, runtime.sh   unchanged
  locks/<name>
  lima/                  LIMA_HOME: Lima's global state only (_config, _networks)
  vms/<name>/
    lima/                Lima's instance folder
    metadata.json        what the markers hold today
    policy.json          the policies the VM boots with (section 4)
    file-mounts/         staged single files of ~/.agent-vm/volumes
```

Deleting a VM is Lima's delete, then removing `vms/<name>`: no marker can
outlive its VM, and `state.Forget` and `state.Rename` go.

### Lima patch

Lima wants every instance at `$LIMA_HOME/<name>`. A `LIMA_HOME` per VM does
not work: with every instance named `lima`, the Windows drivers name their
WSL2 distro and HCS system `lima-lima` for all of them, and the guests'
hostnames and SSH aliases collide; named `<name>`, the path holds the name
twice, which the socket path limit cannot afford (about 23 characters left
on macOS).

A patch makes `dirnames.InstanceDir` return `<vms>/<name>/lima`, and
`store.Instances` and `store.Validate` (which joins the path by hand) follow.
Names stay unique, `_config` stays shared. `vm.MaxName` computes from the new
path: 4 characters less than today (42 for `/Users/sylvinus`).

### What stays shared

- `locks/<name>`: the lock is a `flock` on a file kept forever. In
  `vms/<name>/`, an `rm` would delete the file while a run waits on it, a
  third run would create a new one, and two runs would hold the lock.
- Lima's `_config` (SSH key, networks).

### metadata.json

```json
{"schema": 1,
 "base": {"name": "base", "built": 1760000000, "built_by": "0.4.0"},
 "term": "xterm-ghostty",
 "bound": "/Users/x/proj",
 "scratch_pid": 12345}
```

- Written only under the VM's lock, through a temporary file renamed over it.
  Every write of a marker happens under that lock today.
- `base` in `vms/base/metadata.json` is the template itself, written last by
  setup (what `.agent-vm-base-version` says today). In a VM it is the template
  it was cloned from, copied by `cloneBase`: one field for both, so
  `BaseLabel` has no special case. `name` is there for several templates
  (krunkit, other tools' bases, section 7).
- `scratch_pid` is written before the clone: `vms/<name>/` exists before
  Lima makes `lima/` in it. A `vms/<name>/` without `lima/lima.yaml` is a
  creation that did not finish, removed unless its run is alive.
- An unreadable file is "nothing known": no `base` fails as a 0.1.0 base
  does, no `bound` refuses a named VM. `doctor` names the file.
- `SSHFSOf`, `MountsOf`, `CacheOf` are not carried over. `PolicyOf` becomes
  `policy.json`.

### Migration from 0.3.0

One time, no way back. Run by the first command that changes VMs, under
`locks/migrate`:

1. A VM still running cannot move (its hostagent holds sockets in its
   folder): asked to stop on a terminal, as the 0.2 migration does, else left
   for next time.
2. For each stopped `lima/<name>/` with a `lima.yaml`: `mkdir vms/<name>`,
   `os.Rename` into `vms/<name>/lima`, `metadata.json` from its markers,
   `file-mounts/<name>` moved, then its markers removed. `sshfs` without
   `built-by` becomes `built_by: "0.1.0"`, which keeps the 0.1.0 check
   working.
3. The base's `.agent-vm-base-*` go to `vms/base/metadata.json`.
4. Markers and `file-mounts/` of no VM are removed, and every `mounts` and
   `sshfs-cache` marker.
5. Interrupted, it picks up where it stopped.

`os.Rename` only: a copy would break the blocks shared with the base
(section 8). `EXDEV` stops the migration with the reason.

0.2's migration moves its VMs into the 0.3.0 layout, then this one runs.

0.3.0 after the migration sees no VM. The CHANGELOG says so.

## 3. Engine

`internal/cli/start.go` (and `checks.go`, `probe.go`, `policy.go`,
`commands.go`) runs the start sequence and prints and asks as it goes.
`internal/engine` does the same with no terminal:

- Questions are typed (`hooks`, `git-config`, `bare-repo`, a restart to
  change mode) and go to an `Asker`. No Asker is no, as with no terminal.
- Errors are typed (`ErrNameTooLong`, `ErrBaseMissing`, `*RefusedError`).
  Progress and warnings are `Event`s.
- `context.Context` everywhere. The context that starts a VM is never the
  one its hostagent lives by (see "Hostagent lifetime" below).
- It never reads `AGENT_VM_*`: the CLI turns them into options.

The CLI keeps its output: the recorded `bashref` tests say so.

## 4. Policies through the VM's folder

Lima starts the program again as the VM's hostagent, and the network policy
and the write guard run there: today that process reads
`~/.agent-vm/network` and `guarded` itself. The engine writes
`vms/<name>/policy.json` (network rules, guarded paths, guard mode, app
name) before the VM boots, and the hostagent reads it from its instance
folder. Policies given as Go values reach it this way, and the file is the
record of what the VM booted with.

Guarded writes: dialog, deny, or an allow-list. A Go callback would need the
hostagent to call the consumer's process: later, if needed.

## 5. Library

Public, v0.x and marked experimental until a real consumer has used it:

| Package | Holds |
|---|---|
| `agentvm` (root, exists for the embeds) | `RunHelper`, `Open(Options)`, `Engine`, `VM`, `Spec`, `Asker`, `Question`, `Event`, errors |
| `agentvm/policy` | network rules, guarded paths and volumes as values, and the parsers of agent-vm's files |
| `agentvm/provision` | `Template{Name, Scripts, Preinstall, Env}`; `provision.AgentVM()` is `agent-vm.setup.sh` and its presets |
| `agentvm/agents` | `Agent{Name, Command, ...}`; the CLI's agent commands and their help come from the defaults |

Internal: the Lima backend, building the mounts, the `.git` scan, the guard
and SFTP server, `limaembed`. They hold the guarantees (`.git` read-only,
shares confined, no share of home or state), which `Engine` enforces; an
`x/` package can expose lower layers later.

```go
func main() {
	agentvm.RunHelper() // Lima's hostagent re-exec; on macOS also main_darwin_gui.go's job
	e, err := agentvm.Open(agentvm.Options{StateDir: "~/.mytool", AppName: "mytool", Asker: a})
	e.Setup(ctx, myTemplate)
	vm := e.ProjectVM(dir)
	vm.Ensure(ctx, agentvm.Spec{Base: "base-mytool"})
	vm.Exec(ctx, agentvm.Exec{Args: []string{"mytool-agent"}})
}
```

- `Options` holds every feature, agent-vm's defaults otherwise: state folder
  (required: each tool its own, and its own Lima home), app name, Asker,
  events, network policy, guarded paths, volumes, env sources, runtime
  scripts, `.git` protection, sshfs cache, host share. What lowers a
  protection is named `Unsafe...`.
- One `Engine` per process: Lima's home is an environment variable, and
  logrus is global. The library installs no signal handler and writes
  nothing to stdout.
- `Open` fails, saying why, when `RunHelper` was not called.
- macOS: cgo, and the binary signed with Lima's `vz.entitlements`.
- Guest agent and templates: `go run
  github.com/sylvinus/agent-vm/cmd/agent-vm-assets -o assets/` at build
  time, embedded by the consumer, given as `Options.Assets` (`fs.FS`).

`examples/consumer/` is a module of its own with no `replace`: CI builds it
and runs its e2e test.

## 6. Named VMs, VMs with no shares

Three choices, apart:

| | default | flag |
|---|---|---|
| which VM | the folder's (`<folder>-<hash>`) | `--name NAME` |
| what is shared | the project and the volumes | `--no-shares` |
| how long it lives | kept | `--rm` |

`--scratch` stays as it is: `--no-shares --rm`, a random name, the question
before deletion, the cleanup of what a killed run left. `--scratch --name`
is a usage error: `--no-shares --rm --name X` instead.

```bash
agent-vm --name agent2 claude                 # a second VM on this folder
agent-vm --name sandbox --no-shares claude    # nothing shared, kept, from any folder
agent-vm --name tmp --no-shares --rm run make
agent-vm stop agent2 / rm sandbox
```

A named VM belongs to the folder it was made in, or to none, recorded in
`metadata.json` (`bound`: the folder as `pwd` spells it, or `-`):

- With shares: usable from its folder only. Elsewhere it stops, with "VM
  'agent2' belongs to /path. Run it from there, or agent-vm rm agent2".
  Otherwise a VM that has seen one project would get another.
- With no shares: from any folder, `--no-shares` not needed again, and it
  never gets shares.
- `--reset` re-clones it, the only way to change its binding.
- No `bound`: refused, `rm` suggested.
- `--no-shares` without `--name` is an error.

Names: `^[a-z0-9]+(-[a-z0-9]+)*$`, at most 40 characters; lowercase because
macOS folders ignore case; 40 keeps `<name>.localhost` (`agent-vm code`) a
DNS label. Not ending in `-[0-9a-f]{8}`, which every project and scratch name
does: names cannot meet. Not `base` nor `base-*`, the templates' and the
setup lock's.

Two VMs on one folder: separate locks, probes, protections and editor ports
already. A port both listen on is forwarded for the first only, as between
projects today. They write the same tree: the docs point to git worktrees.

`info [dir]`, `doctor`, and `stop`/`rm` with no argument keep meaning the
folder's VM. `list` marks the named VMs of the current folder too.

## 7. krunkit

The vendored Lima has a krunkit driver (macOS arm64), not imported yet. It
runs `krunkit`, a program of its own (Homebrew): agent-vm would no longer be
one binary there, and `doctor` checks it. Raw disks, like vz.

Accounted for now:

- Templates per driver: `vms/base`, `vms/base-krunkit`. Hence `base-*`
  reserved, and `base.name` in `metadata.json`.
- The driver is Lima's `vmType`, in `lima.yaml`. A VM changes driver with
  `--reset` only.

To check when it is wired in:

- Patch `0005` (network isolation) changes `usernet/gvproxy.go`, the
  hostagent and the qemu driver; krunkit calls
  `usernet.StartGVisorNetstack` itself.
- Its socket names against `vm.MaxName`.
- A separate process with GPU passthrough gives the guest more of the host
  to reach than vz: the Security section says so.

## 8. Disk space

Lima clones with `continuity.CopyFile`: `clonefile` on APFS, so VMs share
the base's blocks until they write their own; `copy_file_range` on Linux,
which shares blocks on btrfs and XFS with reflink, and copies the data on
ext4. Holes are kept everywhere.

The layout keeps the bases and the VMs on one filesystem, and the migration
renames. A new base shares nothing with the VMs of the old one, until
`--reset`.

Next, by value:

1. `list` shows the space a VM uses (allocated blocks), not its disk's size.
2. ext4: a qemu VM's disk as a qcow2 overlay on its base's, bases kept in
   `~/.agent-vm/bases/<id>/` while a VM uses them. qemu only.
3. Giving back the space of deleted files needs discard through the virtual
   disk and `fstrim` in the guest: to check for vz and krunkit.

Not proposed: caches written by several VMs (Docker images, npm), which let
one project's VM plant files another one uses. Read-only shared caches are
fine.

## Hostagent lifetime

Upstream Lima starts the hostagent with `exec.CommandContext(ctx, ...)`
(`pkg/instance/start.go`), so canceling the context of the start kills it.
0.3.0 hands it the context of the command, which `endedBySignal` cancels on
SIGTERM, SIGHUP and when the command returns: the VM goes Broken. Lima
patch 0006 starts it with `exec.Command`. The engine keeps to that: the
context of a call never ends a VM, whose processes live by `Stop` and
`Delete` only.

## Open questions

1. `AGENT_VM_LIMA_HOME`: drop it, or keep it for Lima's global state only?
2. `vms/<name>/env`: an env layer per VM (`agent-vm env --name X set KEY`),
   pushed after `~/.agent-vm/env` and before the project's, the place for the
   secrets of a VM with no shares? Or only the name reserved?
3. The working folder of a VM with no shares: a fixed `~/work` (so
   `claude --continue` finds its history from any host folder), or the host
   path made in the VM, as `--scratch` does?
4. `list`: a column with the binding (folder, `none`, `scratch`)?
5. `AppName`: dialogs and messages only, or the guest side too
   (`~/.agent-vm.env`, `/tmp/.agent-vm-file-mounts`)?
6. `policy.json` per VM as the only way to the hostagent?
7. Linux on ext4: plan the qcow2 overlays, or only show the space used?
8. A krunkit entry in `docs/BACKLOG.md`?

## As built

Where the code differs from the design, and the open questions as they were
settled by default, to revisit:

1. Vendoring (`scripts/third-party-sync`): the import rewrite only touches
   import lines (and the module path Lima's schema generator reads comments
   of), not the strings of the `.pb.go` descriptors, which are
   length-prefixed. The folders that would add requirements nothing uses are
   left out (the last column of `third_party/SOURCES`: Lima's MCP server,
   sshocker's command, gvisor-tap-vsock's commands and test suites). The
   constant naming the patch level is `AgentVMPatches` in a generated
   `agentvm_patches.go` of each tree ("lima-7": the number of the last
   patch). `vendorHash` in `flake.nix` needs Nix to be recomputed.
2. Layout: Lima's patch 0007 adds `LIMA_INSTANCES_DIR`. `policy.json` is done
   here, not in the engine step: the host agent reads the network rules and
   the guarded paths from it, so a program's policies reach it as values.
   Settled: `AGENT_VM_LIMA_HOME` stays, for Lima's global state only; the
   migration is `state.MigrateLayout` (idempotent, run under `locks/migrate`);
   `metadata.json` also holds `file_mounts` (the lines the
   `.agent-vm-file-mounts-<vm>` marker held) and `scratch_pid` is -1 for a
   record whose process number was unreadable.
3. Engine: `internal/engine`. Events are `Event{Level, VM, Title, Text}` with
   the text as the command line prints it. Questions are `Question{Kind, ...}`
   put to an `Asker` (`CanAsk` and `Ask`). Errors are `*Failure` (a kind that
   `errors.Is` matches: `ErrBaseMissing`, `ErrAborted`...) and
   `*RefusedError`. `Options` takes the volumes, the env and the runtime
   script as paths of files in agent-vm's formats (`VolumesFile`, `EnvFile`,
   `RuntimeScript`), the project's own by a function of the folder, and the
   network and guarded policies as values (`Network`, `Guarded`) or by a
   function called at each boot (`Policy`); not volumes as values yet.
   `Setup` shows its steps through an `Output`, which the command line
   draws as a window and a log.
4. Library: the root package re-exports the engine's types, and adds
   `RunHelper` and `Open` (which refuses to open without `RunHelper`). The
   setup script moved to `provision/agent-vm.setup.sh`. `agents`, `policy`,
   `cmd/agent-vm-assets` and `examples/consumer` are as designed; the
   example is built by `make test-example` in a copy of its module to which
   the replace is added (it has none), because the module it requires is not
   released yet. Settled: `AppName` is for the messages and dialogs, not the
   guest side.
5. Named VMs: `bound` is the folder as `pwd` spells it (compared as a string),
   or `-`. A VM with no shares gets its working folder as `--scratch` does:
   the host path made in the VM (the other choice, a fixed `~/work`, is left
   open). `list` marks them with `>` and has no column for the binding.
   `vms/<name>/env` is not built. krunkit and the disk space ideas are in
   `docs/BACKLOG.md`.
