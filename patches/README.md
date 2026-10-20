# Patches to Lima, sshocker, pkg/sftp and gvisor-tap-vsock

agent-vm builds Lima, sshocker, pkg/sftp and gvisor-tap-vsock from `third_party/`: each one is its upstream commit
(`third_party/SOURCES`) with the patches of this folder applied, in name order. The result is a set of packages
of agent-vm's module: the sync drops each tree's `go.mod` and `go.sum`, rewrites the import paths to
`github.com/sylvinus/agent-vm/third_party/<name>` (patches stay written against upstream's paths), and adds an
`agentvm_patches.go` with `AgentVMPatches`, the number of the last patch (`"lima-7"`), which agent-vm refers to.
Because they are packages and not replaced modules, a program importing agent-vm builds them patched. Every patch is a
change meant for upstream, kept small enough to be sent as a PR on its own. Never edit
`third_party/` by hand: change a patch, then `scripts/third-party-sync <name>`. CI runs
`scripts/third-party-sync all --check`.

## Why

agent-vm shares the project with `mountType: reverse-sshfs`, `sftpDriver: builtin` and
`readonlyNames`. The SFTP server is sshocker's rooted server on top of pkg/sftp's `RequestServer`.
It runs inside the Lima hostagent, which with vz also runs the VM: a panic there kills the VM.

| # | Bug | Effect | Fixed by |
|---|-----|--------|----------|
| 1 | `openFile` reads `r.AttrFlags()`/`r.Attributes()` on Open requests, where pkg/sftp stores the open flags in `r.Flags`. `SSH_FXF_APPEND` is the bit of `ATTR_PERMISSIONS`, `Attributes()` fails and returns nil. | Any `O_APPEND` open (`>>`, loggers) panics the hostagent: the VM dies. | sshocker 0003 |
| 2 | RequestServer runs READ/WRITE on 8 parallel workers and everything else on another one, with no ordering between them (only CLOSE waits). | Rewriting a block 8 times leaves an older write last on the host in 241/300 runs; `write` then `ftruncate` leaves the wrong content in 214/300; FSTAT after WRITE returns the old size and the guest reads short files (206/300). OpenSSH: 0/300. | sftp 0001, sshocker 0004 |
| 3 | [pkg/sftp#664](https://github.com/pkg/sftp/issues/664): FSTAT/FSETSTAT act on the path the handle was opened with. | After a rename, `ftruncate(fd)`/`fstat(fd)` hit whatever file is now at the old path. | sftp 0002, sshocker 0004 |
| 4 | `SSH_FXF_APPEND` is ignored, the client's offset is used. | With sshfs's attribute cache, an append right after the host grew the file overwrites the host's data. | sshocker 0005 |
| 5 | pkg/sftp drops MKDIR attributes. | `mkdir -m 700` gives 0755 on the host. | sftp 0003 |
| 6 | `isNoopTimes` and unix `setstat` use `r.Attributes()` without a nil check. | A SETSTAT whose attributes are shorter than its flags announce panics the hostagent. | sshocker 0005 |
| 7 | A handle answers packets meant for another kind: READ on a write-only handle, WRITE on a read-only one, READDIR on a file, READ on a directory. | A READ on a write-only handle wrote zeros into the file. | sftp 0004 |
| 8 | No bound on open handles. | A guest holding thousands of handles exhausts the hostagent's file descriptors. | sftp 0004 (`WithRSMaxHandles`), sshocker 0006 (4096) |
| 9 | A panic in a handler kills the server. | One bad request ends every share and, in the hostagent, the VM. | sftp 0004 |
| 10 | `orderID`s compared as plain uint32. | Past 2^32 packets, responses go out in the wrong order. | sftp 0004 |
| 11 | `statusFromError` matches errnos with `==`, not `errors.As`, and maps ENOTDIR, ELOOP, EINVAL, ENOSYS unlike OpenSSH. | A wrapped EACCES is a generic failure. | sftp 0004 |
| 12 | ATTRS report mtime as atime; `fsync@openssh.com` unsupported. | Wrong access times; `fsync()` in the guest does nothing on the host. | sftp 0004 |
| 13 | Opening a FIFO or a device blocks; a directory is read whole when opened. | A FIFO in the project blocks the server, which handles one request at a time. | sshocker 0006 |
| 14 | FSETSTAT on a read handle applies to whatever is at the path now; a no-replace rename checks then renames. | A chmod through a read handle reaches the file that replaced it; a no-replace rename can overwrite. | sshocker 0006 |
| 15 | Windows: names NtCreateFile accepts but Win32 cannot open or delete (trailing dots or spaces, `NUL`, `COM1`...). | The VM creates files the user cannot remove on the host. | sshocker 0006 |
| 16 | `ReverseSSHFS.Close` dereferences a nil command; the rooted server leaks its root fd when ssh fails to start. | A crash on a close before start; an fd per failed start. | sshocker 0006 |
| 17 | `readonlyNames` compared with `strings.EqualFold`: APFS also ignores normalization (`é` and `e` + U+0301) and folds case fully (`ß` as `ss`). | On macOS the guest writes a read-only name that is not ASCII (a hooks folder) under another spelling. | sshocker 0007 |
| 18 | When the first sshfs mount fails, Lima retries with `-o nonempty` in place of the share's options. | The share is mounted again without `cache=no` (sshfs's attribute cache back on). | lima 0003 |
| 19 | The host's event for a removal the guest asked for is relayed back as a host deletion. | The guest's next removal of a file it created again is taken for the relayed one and not done: the file stays on the host. | sshocker 0009 |
| 20 | The client sets any mode bit, setuid, setgid and sticky included. | A file the host runs carries the privileges of its owner. | sshocker 0006 |
| 21 | `instance.StartWithPaths` starts the hostagent with `exec.CommandContext`: os/exec kills it when the caller's context ends, also after Start returned. | The end of the agent-vm command that started a VM kills its hostagent: QEMU runs on without it (Broken, every later start fails), vz VMs die. | lima 0006 |

## The patches

| Patch | Upstream | Status | Content |
|-------|----------|--------|---------|
| `lima/0001-mounts-add-sshfs.readonlyNames` | lima-vm/lima | [#5529](https://github.com/lima-vm/lima/issues/5529), PR #5531 open | `mounts[*].sshfs.readonlyNames`, enforced by the rooted SFTP server. A writable mount of a folder holding another writable mount must list the same names. |
| `lima/0002-hostagent-relay-host-deletions` | lima-vm/lima | with #5531 | The hostagent relays deletions made on the host to the guest's sshfs (`ExpectRemove`). |
| `lima/0003-hostagent-keep-sshfs-options-on-retry` | lima-vm/lima | not sent | Bug 18: the retry adds `nonempty` to the options. No test: it needs a guest whose first mount fails. |
| `lima/0004-portfwd-not-next-to-a-host-program` | lima-vm/lima | not sent | A guest port is forwarded only when no host program uses it: with `SO_REUSEADDR`, a listener on 127.0.0.1:P is allowed next to a host program's 0.0.0.0:P on macOS and BSD, and takes its local connections. The port is tried on 127.0.0.1, ::1, 0.0.0.0 and :: first (with `SO_EXCLUSIVEADDRUSE` on Windows); one in use gives a `failed` port-forward event. Tests `TestForwardNotNextToHostProgram`, `TestForwardFreePort`. |
| `lima/0005-network-isolation-hooks` | lima-vm/lima | not sent | Hooks for agent-vm's network policy: `usernet.Outbound` and `usernet.AllowHostService` (the hostagent's DNS ports), `dns.Names`/`dns.Answered` (a name refused is NXDOMAIN, never looked up). QEMU gets its own netstack per instance, as vz has, so the policy applies to both, and its guest's DNS is the gateway's. QEMU is handed the connected socket, or on Windows, which cannot pass it, connects itself (`stream` netdev, QEMU 7.2 or later). `usernet.Names` and `usernet.Answered` reach the gateway's DNS server through gvisor-tap-vsock 0002, and a host service is allowed for its network and port on 127.0.0.1 only. Tests `TestNamesAnswered`, `TestOutboundHostServices`; the rest is covered by agent-vm's e2e (`internal/vm/lima_e2e_test.go`). |
| `lima/0006-instance-hostagent-outlives-start-context` | lima-vm/lima | not sent; the issue to open is the patch's header | Bug 21: `exec.Command`. No Lima test (its unit tests start no hostagent): agent-vm's e2e (`internal/cli/e2e_test.go`) fails without it. The header also reports the QEMU driver's "send on closed channel" panic that follows, not fixed here. |
| `lima/0007-instances-dir` | lima-vm/lima | not sent | `$LIMA_INSTANCES_DIR`: when set, the instance NAME is in `$LIMA_INSTANCES_DIR/NAME/lima`, and the embedding program keeps its own files for NAME beside it (agent-vm: `metadata.json`, `policy.json`). `dirnames.InstanceName` is the name of an instance dir, which templates' `{{.Name}}` read (it is no longer the base of the dir); `store.Instances` lists the folders holding an instance folder; Clone makes the parent folder. A `$LIMA_HOME` per VM would name every instance alike (hostnames, SSH aliases, the Windows drivers' distro and system names) and put the name twice in each socket path. Tests `TestInstancesDir`, `TestInstancesDirRelative`, `TestInstancesDirUnset`. |
| `sshocker/0001-rooted-server-readonly-names` | lima-vm/sshocker | fork branch `readonly-names` | The builtin server serves only the mounted directory, and `ReadonlyNames`. |
| `sshocker/0002-expect-remove` | lima-vm/sshocker | fork branch `expect-remove` | `ExpectRemove`, for 0002 of Lima. |
| `sshocker/0003-append-fix` | lima-vm/sshocker | not sent | Bug 1. Tests `TestRootedOpenAppend`, `TestRootedOpenMode`. No pkg/sftp dependency: send first. |
| `sshocker/0004-664-sequential` | lima-vm/sshocker | after a pkg/sftp release | Bugs 2, 3: `WithRSSequential()`, FSTAT on the handle's file, FSETSTAT on it for writable handles only. Tests `TestRootedFstatFsetstatAfterRename`, `TestRootedFsetstatReadHandle`. Needs sftp 0001, 0002. |
| `sshocker/0005-append-mkdir-guards` | lima-vm/sshocker | nil guards now, `O_APPEND` after pkg/sftp | Bugs 4, 6. Tests `TestRootedAppendAfterHostWrite`, `TestRootedSetstatShortAttributes`. Needs sftp 0001 (ordering of appends), 0003 (mkdir modes). |
| `sshocker/0006-robustness` | lima-vm/sshocker | not sent | Bugs 8, 13 to 16. Tests `TestRootedFifo`, `TestRenameNoReplace`, `TestRootedReadHandleSetstatAfterRename`, `TestRootedListLarge`, `TestRootedMaxHandles`, `TestReverseSSHFSCloseNotStarted`, `TestWritableNameWin32`. Also: the client never sets the setuid, setgid or sticky bits (`TestRootedNoSpecialBits`), `Close` waits for the processes it killed (`TestCloseReaps`), and a directory renamed while open lists its own entries, not those of a symlink put in its place (`TestRootedListNoEscape`). Needs sftp 0004. |
| `sshocker/0007-name-folding-fuzz` | lima-vm/sshocker | not sent | Bug 17: names compared in NFD, fully case-folded (`golang.org/x/text`). Test `TestSameName`. `FoldName` (`fold.go`) is exported, so that Guard's users fold as the server does, and drops the code points casefold file systems ignore (`TestFoldNameIgnorables`, `FuzzFoldIgnorables`, `TestSameNameCasefold`). Fuzzers: `FuzzSameNameFS` (the host file system as the oracle: run it on macOS and Windows), `FuzzSameNameEqualFold`, `FuzzRootedOps` (a hostile client's request sequences: nothing outside the root read or changed, `.git` intact). `make fuzz`. |
| `sshocker/0008-write-guard` | lima-vm/sshocker | not sent | `reversesshfs.Guard`: asked before a write, create, rename or removal of a path, which it may refuse (EACCES). agent-vm asks the user for the files the host runs (`internal/guard`). `entry` is true for a name being created, moved, linked or removed: then a folder holding a guarded path matters too. On Windows Guard is asked with the normalized names (8.3 short names replaced by long ones). Tests `TestRootedGuard`, `TestRootedGuardParents`. |
| `sshocker/0009-relay-ignore-own-removals` | lima-vm/sshocker | not sent | `ExpectRemove` returns false, and the removal is not relayed, when the server just removed or moved the path away itself; a removal of a path the guest created again since is the guest's own. An operation that failed takes its record back. Tests `TestRootedOwnRemovalNotRelayed`, `TestRootedFailedRemovalNotOwn`, `TestRootedTokenDroppedByCreate`, `TestExpectRemoveMany`, `TestExpiringKeyAddedAgain`. Needs 0002. |
| `sftp/0001-sequential` | pkg/sftp | issue to open (draft below) | Bug 2: `WithRSSequential()`, opt-in, one worker, packets in order, as OpenSSH's sftp-server. Test `TestPacketManagerSequential`. |
| `sftp/0002-664-handle-file` | pkg/sftp | references #664 | Bug 3: `Request.HandleFile()` for FSTAT/FSETSTAT. Test `TestRequestHandleFile`. |
| `sftp/0003-mkdir-attrs` | pkg/sftp | not sent | Bug 5. Test `TestRequestMkdirAttributes`; for a standalone PR, move it to the end of `request-server_test.go`. |
| `sftp/0004-robustness` | pkg/sftp | not sent, one PR per item | Bugs 7 to 12. Tests `TestRequestHandlePacketMismatch`, `TestRequestServerMaxHandles`, `TestRequestServerHandlerPanic`, `TestRequestFsync`, `TestRequestServerOrderIDWrap`, `TestStatusFromErrorErrno`, `TestFileStatFromInfoAtime`; `TestRequestReaddir` updated (ENOTDIR is `SSH_FX_NO_SUCH_FILE`, as in OpenSSH). |
| `sftp/0005-fuzz-request-server` | pkg/sftp | not sent | `FuzzRequestServer`: any bytes after INIT, to a server set as sshocker sets it; it never panics nor hangs. Its seed is a WRITE at a huge offset, which made `InMemHandler` allocate it. |
| `gvisor-tap-vsock/0001-outbound-policy` | containers/gvisor-tap-vsock | not sent | `Configuration.Outbound`: the TCP and UDP forwarders refuse a destination it denies, checked after NAT (the gateway's address is the host's loopback by then). No test of its own: agent-vm's e2e connects to denied and allowed addresses. |
| `gvisor-tap-vsock/0002-dns-policy` | containers/gvisor-tap-vsock | not sent | `Configuration.DNSNames` and `DNSAnswered`: the gateway's DNS server answers NXDOMAIN, over UDP and TCP, for a name `DNSNames` refuses, without asking the host's resolver, and tells `DNSAnswered` the IPv4 addresses it gave, so that `Outbound` can allow those only. Test `TestPolicy`. |

Lima's `0b63ae0` of the fork (`replace` of sshocker) is gone: the four trees are packages of
agent-vm's module. FSETSTAT through a read handle keeps the path checks (0004): a read handle can be
opened through a symlink into `.git` (`TestRootedFsetstatReadHandle`).

Every test was checked to fail with its fix removed. Keep that property when rebasing: revert the
fix, see the test fail, restore.

## Working on a patch

```bash
scripts/third-party-sync sshocker                 # third_party/sshocker from SOURCES and patches
scripts/third-party-sync sshocker --ref <commit>  # move to another upstream commit
scripts/third-party-sync all --check              # what CI runs
```

To change a patch: clone upstream at the commit of `SOURCES`, `git am` (or `git apply`) the
patches before it, make the change, and write the patch back with `git format-patch` or `git diff`.
Rebasing on a new upstream: the same, from the new commit, then `--ref`.

Tests run from agent-vm's module root (`make test-third-party`):

```bash
go test -vet=off -race ./third_party/sftp/...    # pkg/sftp's vet fails on upstream code
go test -race ./third_party/sshocker/pkg/...
go test ./third_party/lima/pkg/...
go test ./third_party/gvisor-tap-vsock/pkg/...
tests/sftp/run                                   # through real sshfs, see tests/sftp/run
```

The folders that would add requirements nothing in agent-vm uses are left out (the last column of
`SOURCES`): Lima's MCP server, sshocker's command, and gvisor-tap-vsock's commands, `vendor`,
`tools` and test suites. Lima's `gomodjail` annotations went with its `go.mod`, and with them
`make gomodjail`, which agent-vm did not run.

A sync raises agent-vm's `go.mod` to the requirements of the upstream `go.mod` it drops, then runs
`go mod tidy`. `make fuzz` runs every fuzzer of the four trees and of agent-vm, `FUZZTIME` each.

### Through real sshfs

`tests/sftp/run` builds sshocker's rooted server outside Lima and runs `tests/sftp/fs_suite.py`
through sshfs with Lima's and agent-vm's options; `--openssh` runs OpenSSH's sftp-server as the
control. A DIFF the control shows too comes from sshfs or SFTP v3, not from the server. Last run
(2026-10-04, Linux arm64, WORK on ext4): no CRASH, HANG or FDLEAK, and 10 DIFFs, each of which
OpenSSH's sftp-server shows too (it has an 11th, `utime_symlink_nofollow`: it fails `lutimes`):

- `utimes_ranges`, `utime_now_and_touch`: SFTP v3 times are 32-bit seconds.
- `chown_ops`, `rename_matrix`, `names`: SFTP v3 has few status codes (EPERM, ENOTEMPTY,
  ENAMETOOLONG come back as EACCES or EPERM).
- `renameat2_flags`, `special_files`: no RENAME_EXCHANGE, FIFO, xattr or O_TMPFILE over sshfs.
- `links`: `st_nlink` stays 1 after `link()` until sshfs's attribute cache expires.
- `create_modes`: the server's umask applies, as with OpenSSH.
- `huge_offsets`: EIO on ext4, with OpenSSH as well; none on tmpfs.

Not run yet: sshocker's tests on macOS (`rooted_darwin.go`, `unix.Futimes`, `O_APPEND` writes)
and on Windows (`appendWrite`, `fsetstat` on a handle, `FILE_READ_ATTRIBUTES` on write-only opens):
only vetted. The CI matrix covers them.

## Upstream

Upstream, each step waits for a release of the previous one: pkg/sftp, then sshocker, then Lima.
pkg/sftp merges rarely and some of these patches add API, so split what needs no pkg/sftp release:

- **sshocker, now:** 0003 (crash on append), and the nil guards of 0005. Crash fixes for any Lima
  user of the builtin driver. 0001 and 0002 go with the Lima #5531 discussion.
- **pkg/sftp:** an issue for the ordering bug (below), then a PR with 0001; a PR with 0002
  referencing #664; a PR with 0003. Rebase each on pkg/sftp's master separately: none needs
  another's code.
- **sshocker, after a pkg/sftp release:** the rest of 0004 and 0005. `O_APPEND` waits too: without
  sequential processing two appends can land in either order.
- **Lima:** once sshocker has released, #5531 needs no vendored sshocker.

Each patch merged upstream is dropped from here when `SOURCES` moves past it. Never push, tag or
open a PR without the owner's go-ahead.

Lima's contribution rules (`website/content/en/docs/community/contributing.md`, "AI Contribution
Rules"): the human who submits signs off every commit (`git commit -s`, DCO), writes the PR
description and answers reviews themselves, and discloses AI help with an `Assisted-by:` trailer.
New Go files need an SPDX header there.

### Draft: pkg/sftp issue for the ordering bug

> **RequestServer: requests run out of order with the WRITEs sent before them**
>
> `packetManager.workerChan` sends READ and WRITE to `SftpServerWorkerCount` workers and every other
> packet to another worker; only CLOSE waits for the reads and writes in flight. So:
> - two WRITEs to the same range run in either order: through sshfs, rewriting a 4 KiB block 8 times
>   left an older write last in 241 runs out of 300;
> - a FSETSTAT (`ftruncate(fd)`) after a WRITE can run first: wrong file content in 214/300;
> - a FSTAT after a WRITE can return the old size, and the kernel caches it: short reads in 206/300.
>
> OpenSSH's sftp-server, same sshfs, same tests: 0/300. Proposal: `WithRSSequential()`, opt-in, one worker
> processing packets in the order received (PR attached). Responses were already sent in order.

## Wanted from Lima (proposals, no patch yet)

- **Expose sshfs's `dcache_timeout`** (`sshfs.cacheTimeout`, passed as `-o dcache_timeout=`): agent-vm
  turns sshfs's cache off on writable shares, because with the default 20 s timeout the VM can
  write back a file as it was before the host changed it. A 1 s cache would keep most of the speed.
- **Network isolation between VMs** (agent-vm's own Lima config, not a patch): any VM can listen on
  a port Lima forwards to the host, so it can lure the browser to another VM's `agent-vm code` host
  name. Per-VM `portForwards`, or forwarding off by default.
