# Releasing agent-vm

`release.sh` checks a commit, tags it, builds a tarball per platform from the tag, publishes them
on GitHub with their `SHA256SUMS`, and prints the Homebrew lines. It runs on a Mac: the macOS
binaries need its SDK and `codesign`; Linux and Windows are cross-built there. It bumps and
commits nothing.

Needs: git, make, Go, the Xcode command line tools, `gh` logged in, and for signed Windows
binaries `osslsigncode` (`brew install osslsigncode`).

## A release

1. In an ordinary commit on the branch: `NEXT_VERSION := X.Y.Z` in the Makefile, and CHANGELOG.md's
   `## Unreleased` renamed `## X.Y.Z`. Push it, and wait for CI (the `go` workflow) to pass on it.
2. On the Mac, in a clean clone of that commit:

   ```bash
   ./release.sh X.Y.Z --dry-run   # every check and the builds, nothing changed
   ./release.sh X.Y.Z
   ```

   - Windows binaries, signed: `AGENT_VM_WINDOWS_PFX=<certificate and key, .pfx>` and
     `AGENT_VM_WINDOWS_PFX_PASS=<its password>`. Without, they go out unsigned, with a warning.
   - Homebrew: `AGENT_VM_TAP=<clone of the tap>` updates `Formula/agent-vm.rb` there (each
     platform's url and sha256) and prints the commands to commit it.
   - The Linux `.deb` and `.rpm` (`packaging/nfpm.yaml`) are made with nfpm, built with Go at the
     version pinned in `release.sh` (`NFPM_VERSION`; `AGENT_VM_NFPM=<binary>` uses another). They
     are release assets and in `SHA256SUMS`, after the tarballs.
   - A run that tagged and then failed is resumed by running it again.
3. In a commit after it: `NEXT_VERSION` to the next version, and a new `## Unreleased` section.

## After it

- Check: `gh release view vX.Y.Z` shows it, and on a test machine
  `curl -fsSL https://www.agent-vm.org/install.sh | sh -s -- --version X.Y.Z` gives X.Y.Z.
- The Homebrew formula has one url and sha256 per platform (`on_macos`/`on_linux`,
  `on_arm`/`on_intel`), installing the tarball's `agent-vm`: that is the shape `AGENT_VM_TAP` updates.
  Then, in the tap: `brew audit --strict sylvinus/tap/agent-vm`, `brew reinstall` and `brew test`
  before pushing.
- `flake.nix` builds from source, with its `vendorHash` for the Go dependencies. When go.mod or
  go.sum change, `release.sh` stops until it is updated: on a machine with Nix, set
  `pkgs.lib.fakeHash`, run `nix build .#agent-vm` (Linux), put the hash it prints back, and update
  the `go.mod+go.sum:` checksum line next to it (the error gives the value). The hash is of the
  downloaded modules only (`proxyVendor`), so patches to `third_party/` leave it as it is. Do the
  same after `nix flake update`: `flake.lock` pins nixpkgs, and with it the Go that downloads them.
- `--not-latest` publishes a release without making it GitHub's latest: the installer's default
  stays the previous release, and the Homebrew formula is left alone, `AGENT_VM_TAP` or not.
