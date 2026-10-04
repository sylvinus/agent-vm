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
   - A run that tagged and then failed is resumed by running it again.
3. In a commit after it: `NEXT_VERSION` to the next version, and a new `## Unreleased` section.

## 0.3.0 from its branch, main staying on 0.2.1

`main` holds 0.2.1, and the site, `www/public/install.sh` included, is deployed from it. 0.3.0 can
go out from the `0.3.0` branch for those who ask for it, while everyone else keeps 0.2.1.

1. On `main`, the new installer only: it takes the tarball of the machine, as 0.3 publishes them,
   and still installs 0.2.x releases (one tarball for all). Without it, nothing installs 0.3.0.

   ```bash
   git checkout main
   git checkout 0.3.0 -- www/public/install.sh
   git commit -m "installer: per-platform release tarballs"
   git push        # the www workflow deploys it
   ```

   Then check that `curl -fsSL https://www.agent-vm.org/install.sh | sh` still installs 0.2.1.

2. On `0.3.0`: CHANGELOG.md's `## Unreleased` renamed `## 0.3.0` (`NEXT_VERSION` is already
   0.3.0), committed and pushed; CI passes on it.

3. On the Mac, from the `0.3.0` branch:

   ```bash
   RELEASE_BRANCH=0.3.0 ./release.sh 0.3.0 --not-latest --dry-run
   RELEASE_BRANCH=0.3.0 ./release.sh 0.3.0 --not-latest
   ```

   `--not-latest` publishes it without making it GitHub's latest release: the installer's default
   stays 0.2.1. It also leaves the Homebrew formula alone, `AGENT_VM_TAP` or not.

4. Check: `gh release view v0.3.0` shows it; a plain install still gives 0.2.1; on a test machine,
   `curl -fsSL https://www.agent-vm.org/install.sh | sh -s -- --version 0.3.0` gives 0.3.0.

5. Tell people how to try it:

   ```bash
   curl -fsSL https://www.agent-vm.org/install.sh | sh -s -- --version 0.3.0
   # or, from a clone (Go needed)
   git checkout v0.3.0 && ./agent-vm.sh install
   ```

   Their 0.2 setup carries over: the first command offers to move their VMs, and what 0.2 left on
   their PATH or in their shell rc runs 0.3 (CHANGELOG.md).

A 0.2.x release from `main` meanwhile is made with `main`'s own `release.sh`, as before. It
becomes the latest release, which the installer then gives by default, as wanted.

## Making 0.3 the default

1. Merge `0.3.0` into `main`: the site then documents 0.3.
2. `gh release edit v0.3.0 --latest`, or release the next 0.3.x without `--not-latest`.
3. The Homebrew formula: one url and sha256 per platform (`on_macos`/`on_linux`,
   `on_arm`/`on_intel`), installing the tarball's `agent-vm`. From then on, `AGENT_VM_TAP` keeps it
   up to date at each release.
