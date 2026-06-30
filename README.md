# agent-vm

Run Claude Code / Codex / OpenCode inside a per-project libkrun microVM,
booting in ~2 seconds, with:

- **Host OAuth tokens never enter the VM.** The TLS-intercept proxy in
  [microsandbox](https://github.com/wirenboard/microsandbox) substitutes
  the real bearer for a placeholder on the way out. OAuth refresh is
  MITM'd so multi-hour sessions survive token rotation.
- **Per-launch GitHub repo allow-list.** Auto-detected from
  `git remote -v`; extend with `--repo OWNER/NAME`. `gh pr create`,
  `git push` etc. are filtered at the proxy — off-list calls get a 403
  before they reach GitHub.
- **Sandbox is the boundary.** Root inside the VM, project bind-mounted
  at its host path, `--dangerously-skip-permissions` set by default
  (the microVM is the only thing actually keeping the agent on rails).

This is the Rust rewrite of the original Bash
[`wirenboard/agent-vm`](https://github.com/wirenboard/agent-vm) on
top of microsandbox. Living on `rewrite-microsandbox` until v1.

## Requirements

- Linux with `/dev/kvm` (rw) — your user must be in the `kvm`
  group: `sudo usermod -aG kvm $USER` and re-login.
- Node.js 18+ (already there if you use Claude Code / Codex CLI /
  OpenCode — they're all npm-distributed).

`~/.microsandbox/lib/libkrunfw.so.5.x` auto-installs on first
launch.

## Quick start

```bash
npm install -g @wirenboard/agent-vm        # or: npx @wirenboard/agent-vm <cmd>

curl -fsSL https://claude.ai/install.sh | bash        #install claude client

claude        #run for login in claud.io, more details https://github.com/wirenboard/agent-vm#credentials

agent-vm setup            # pulls the latest image from ghcr.io and verifies it boots

cd ~/your-project

agent-vm claude           # or codex / opencode / shell
```

The npm package bundles a prebuilt `agent-vm` binary, the patched
`msb`, and libkrunfw. agent-vm finds them via
`current_exe()`-relative paths, so a user's separate
`~/.microsandbox/bin/msb` (if any) never shadows the patched build.

## Build from source

```bash
git clone -b rewrite-microsandbox https://github.com/wirenboard/agent-vm
cd agent-vm
git submodule update --init vendor/microsandbox
sudo apt-get install -y libcap-ng-dev libdbus-1-dev pkg-config
cargo build --release -p agent-vm
cargo build --release --manifest-path vendor/microsandbox/Cargo.toml \
    -p microsandbox-cli --bin msb
./target/release/agent-vm setup       # uses the locally-built msb sibling
```

`agent-vm setup` pulls
`ghcr.io/wirenboard/agent-vm-template:latest` by default; pass
`--image localhost:5000/agent-vm-template:latest` to use a local image
you've built via `images/build.sh`.

## Subcommands

```
claude | codex | opencode | shell   launch an agent in a per-project sandbox
pull                                refresh the cached image
setup                               pull base image + verify boot
clipboard {get,put} [--sys]         exchange a string with the project sandbox
```

## Image release cadence

The base OCI image (`ghcr.io/wirenboard/agent-vm-template:latest`) is
rebuilt hourly by CI, picking up the latest Claude Code, Codex CLI,
and OpenCode releases automatically. Pin a specific build with
`--image ghcr.io/wirenboard/agent-vm-template:YYYY-MM-DDTHH` (date tags are
immutable; the last 14 days are retained).

The agent-vm binary and the image are version-locked through an
**image-API-version** integer
(`/etc/agent-vm-image-version` inside the image). Mismatch → clean
error at launch instead of mysterious in-VM failures.

Each launcher accepts:

| flag | what |
|---|---|
| `--memory N` | VM memory GiB (default 2) |
| `--cpus N` | vCPUs (default 2) |
| `--image REF` | override the OCI image |
| `--no-update-check` | skip the registry HEAD on launch |
| `--no-git` | skip gh/git auth injection (still respects `--repo`) |
| `--repo OWNER/NAME` | add to the GitHub allow-list (repeatable) |
| `--mount HOST[:GUEST]` | extra bind mount (one virtio-fs each, ~210 mount headroom) |

Trailing args go to the agent: `agent-vm claude -p "say hi"`,
`agent-vm shell -- -c 'cargo test'`.

Env-var knobs (all opt-in; set to *any* value, empty included):

| var | what |
|---|---|
| `RUST_LOG` | tracing filter; default `warn`. e.g. `RUST_LOG=agent_vm=debug` |
| `AGENT_VM_PROFILE` | print per-phase wall-time (create/run/stop/remove) |
| `AGENT_VM_DEBUG_CONFIG` | dump the SandboxConfig JSON before boot |
| `AGENT_VM_NO_CHROME_MCP` | skip the Chrome DevTools MCP entirely (no entry in claude.json, no chrome-user setup at boot) |
| `AGENT_VM_IMAGE_TAG` | override the OCI image (same as `--image`) |
| `AGENT_VM_MEMORY_GIB` / `AGENT_VM_CPUS` | same as `--memory` / `--cpus` |

## Chrome DevTools MCP

The image ships chromium and a `chrome-devtools` MCP entry pinned to
`chrome-devtools-mcp@1.0.1`. To keep chromium's nested user-namespace
sandbox active (we'd rather not pass `--no-sandbox`) the MCP runs as a
dedicated `chrome` user via a sudo wrapper at
`/usr/local/bin/agent-vm-chrome-mcp`. The launcher installs the
per-boot microsandbox MITM CA into chrome's NSS DB at startup so
chromium accepts the intercepted TLS chain without
`--acceptInsecureCerts` (which would trust *any* untrusted cert).

If the CA install fails (e.g. someone broke the in-image sudoers rule)
the launcher prints a warning naming the symptom — without it, every
HTTPS navigate would silently return `ERR_CERT_AUTHORITY_INVALID`.
Set `AGENT_VM_NO_CHROME_MCP=1` to skip the whole setup.

## Credentials

Reads from the host:

- `~/.claude/.credentials.json` (Claude)
- `~/.codex/auth.json` (Codex, OpenCode)
- `gh auth token` (git/gh)

The guest gets placeholder strings; the proxy substitutes on the wire.
Real tokens live in `${XDG_STATE_HOME}/agent-vm/<hash>.secrets/` (0700)
on the host, **outside** the bind mount the guest sees. A SHA-256
snapshot of the three credential files is taken at launch and
re-checked on exit; unexpected mutations print a warning.

For Claude/Codex, when the in-VM agent's bearer expires the
hook MITMs the OAuth refresh, runs `claude -p`/`codex exec` on the
host to rotate, and feeds the new placeholder back to the guest — no
re-attach required.

## Project hook

If the project root contains an executable `.agent-vm.runtime.sh`,
the launcher sources it inside the guest before exec'ing the agent.
Use for `npm install`, env exports, dev-server startup. Non-zero
exit aborts the launch.

## Ports & egress

The default network policy (`public_only`) lets the guest reach
the public internet plus DNS, and denies everything else
(loopback, RFC1918 LAN, link-local, cloud-metadata, the host).
Open holes per-launch with these flags — they compose:

| flag | what it opens | guest-side address |
|---|---|---|
| `--publish HOST:GUEST[/proto]` | host port `HOST` → guest port `GUEST` (`tcp` default; `/udp` for UDP) | inbound to the guest |
| `--auto-publish` | every `0.0.0.0:*` / `127.0.0.1:*` listener inside the guest is mirrored to the host loopback (Lima-style) | host: `127.0.0.1:<guest-port>` |
| `--allow-egress IP\|CIDR` (repeatable) | one IP or one CIDR through the egress deny | dial directly by IP |
| `--allow-lan` | the whole `DestinationGroup::Private` (10/8, 172.16/12, 192.168/16, 100.64/10, fc00::/7) | dial any LAN IP |
| `--allow-host` | the per-sandbox gateway IP, which the smoltcp stack rewrites to host `127.0.0.1` | `host.microsandbox.internal:<port>` (already in guest `/etc/hosts`) |

Loopback (guest's own `127.0.0.1`), link-local, and cloud metadata
(`169.254.169.254`) stay denied even with `--allow-lan` — they're
disjoint groups by design. `--allow-host` is the narrowest way to
reach a dev server bound to host `127.0.0.1`; `--allow-lan` is the
broadest. A compromised in-guest process gets full access to
whatever you open, so prefer the narrowest flag that fits.

## Troubleshooting

- **`RegisterNetDevice(IrqsExhausted)` at boot** — the userspace split
  irqchip raises the cap to ~219 IRQs, so this should only happen with
  hundreds of `--mount`s or on a host whose KVM lacks
  `KVM_CAP_SPLIT_IRQCHIP` (pre-Linux 4.7 or some nested-virt /
  seccomp-restricted setups). Drop a `--mount` to recover.
- **`handshake read id_offset: timed out`** — `free -h`; the VM needs
  more memory than is available. Try `--memory 1`.
- **GitHub 403 from the proxy** — repo isn't in the allow-list.
  Pass `--repo OWNER/NAME` or run from a project with the right
  remote.

## See also

- [PLAN.md](PLAN.md) — phased roadmap, what's done, what's deferred.
- [ARCHITECTURE.md](ARCHITECTURE.md) — design notes; why things look
  the way they do.
- [AGENTS.md](AGENTS.md) — conventions for coding agents (Claude
  Code, Codex, etc.) working on this repo: post-merge version bump,
  submodule-merge ordering, what not to do.
