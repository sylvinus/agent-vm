#!/usr/bin/env bash
#
# Cut an agent-vm release.
#
#   ./release.sh X.Y.Z             check, then tag, push and publish
#   ./release.sh X.Y.Z --dry-run   run every check and build, change nothing
#   ./release.sh X.Y.Z --yes       no confirmation prompt
#   ./release.sh X.Y.Z --bypass-checks   without waiting for the CI workflow
#   ./release.sh X.Y.Z --not-latest      not GitHub's latest release
#   ./release.sh notes X.Y.Z       print that version's CHANGELOG.md section
#
# --not-latest: the curl installer keeps installing the latest release, and
# this one only with --version X.Y.Z; the Homebrew formula is left alone.
# RELEASE_BRANCH=<branch> releases from that branch instead of main. See
# RELEASING.md.
#
# It bumps and commits nothing. First, in an ordinary commit on main: set
# NEXT_VERSION := X.Y.Z in the Makefile and rename CHANGELOG.md's "##
# Unreleased" to "## X.Y.Z". Push it and let CI pass. This script then checks
# that commit and publishes it:
#
#   1. clean tree, on main, level with origin/main, tag vX.Y.Z not taken (or
#      already on this commit with no release: a failed run, resumed at 5)
#   2. the Makefile's NEXT_VERSION is X.Y.Z, CHANGELOG.md has a non-empty
#      X.Y.Z section
#   3. the CI workflow passed on this commit
#   4. annotated tag vX.Y.Z, pushed
#   5. GitHub release: the CHANGELOG section as notes, plus
#      agent-vm-X.Y.Z-<os>-<arch>.tar.gz for each platform and their
#      SHA256SUMS. Each tarball holds that platform's binary, agent-vm, built
#      here from the tag, and agent-vm.sh: the curl installer takes the one
#      of the machine, unpacks it and runs `agent-vm.sh install`.
#   6. the url and sha256 lines for the Homebrew formula, per platform. With
#      AGENT_VM_TAP=<path to a homebrew-tap clone>, Formula/agent-vm.rb there
#      (checked to exist before step 1) is updated too: each url naming a
#      platform's tarball, and the sha256 after it. The commands to commit it
#      are printed.
#
# Runs on macOS: the macOS binaries need its SDK (vz, through cgo) and
# codesign, and its Go builds the Linux and Windows ones too (without cgo,
# which they never use). A dry run elsewhere builds those only, with a
# warning.
#
# The Windows binaries are signed (Authenticode, with osslsigncode) when
# AGENT_VM_WINDOWS_PFX names the certificate and key, a PKCS#12 file, and
# AGENT_VM_WINDOWS_PFX_PASS is its password; timestamped by
# AGENT_VM_WINDOWS_TIMESTAMP (default http://timestamp.digicert.com; empty:
# none). Without, they are unsigned, with a warning: Windows warns before
# running one downloaded by a browser.
#
# Needs git, make, Go, the Xcode command line tools, gh (logged in) and
# shasum or sha256sum. A dry run reads origin without fetching, and without
# gh skips the checks that need it, with a warning.

set -euo pipefail

REPO_DIR="$(CDPATH= cd -P -- "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)"
BRANCH="${RELEASE_BRANCH:-main}"
PLATFORMS="darwin-arm64 darwin-amd64 linux-arm64 linux-amd64 windows-arm64 windows-amd64"

c_g=''; c_y=''; c_r=''; c_0=''
if [ -t 1 ]; then c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_0=$'\033[0m'; fi
ok()   { printf '%s✓%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s!%s %s\n' "$c_y" "$c_0" "$*"; }
die()  { printf '%s✗%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }

usage() {
  sed -n '5,10p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

valid_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# The "## X.Y.Z" section of CHANGELOG.md, without its heading and without
# leading or trailing blank lines. Empty when there is none.
changelog_notes() {
  awk -v v="$1" '
    /^## / { if (inside) exit; inside = ($2 == v); next }
    inside { lines[++n] = $0 }
    END {
      first = 1; while (first <= n && lines[first] ~ /^[ \t]*$/) first++
      last = n;  while (last >= first && lines[last] ~ /^[ \t]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }
  ' "$REPO_DIR/CHANGELOG.md"
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else die "neither shasum nor sha256sum is installed"
  fi
}

# Show a command, then run it, unless this is a dry run.
run() {
  printf '  $ %s\n' "$*"
  [ -n "$DRY_RUN" ] || "$@"
}

# package <ref> <version> <outdir> <platform>...: in outdir, built from ref,
# agent-vm-<version>-<platform>.tar.gz for each platform, holding the binary
# (agent-vm), agent-vm.sh and the docs.
package() {
  local ref="$1" version="$2" out="$3"; shift 3
  local src="$out/src" stage p os arch bin
  mkdir -p "$src"
  git -C "$REPO_DIR" archive "$ref" | tar -x -C "$src"
  for p in "$@"; do
    os="${p%-*}"; arch="${p#*-}"
    stage="$out/stage-$p/agent-vm-$version"
    mkdir -p "$stage"
    echo "  building $p"
    # The Makefile sets cgo (macOS only). GOWORK=off: a go.work above $WORK
    # would take part in the build.
    make -C "$src" clean >/dev/null
    env -u CGO_ENABLED GOWORK=off make -C "$src" agent-vm GOOS="$os" GOARCH="$arch" VERSION="$version" \
      >"$out/build-$p.log" 2>&1 || { tail -n 20 "$out/build-$p.log" >&2; die "the $p build failed: $out/build-$p.log"; }
    bin=agent-vm
    [ "$os" != windows ] || bin=agent-vm.exe
    cp "$src/_output/bin/$bin" "$src/agent-vm.sh" "$src/LICENSE" "$src/README.md" "$src/CHANGELOG.md" \
      "$src/runtime.example.sh" "$stage/"
    [ "$os" != windows ] || [ -z "${AGENT_VM_WINDOWS_PFX:-}" ] || sign_windows "$stage/$bin" "$out"
    tar -czf "$out/agent-vm-$version-$p.tar.gz" -C "$out/stage-$p" "agent-vm-$version"
  done
}

# sign_windows <exe> <workdir>: Authenticode signature (see the top). The
# password goes through a file, not the command line.
sign_windows() {
  local exe="$1" pass="$2/pfx-pass" ts="${AGENT_VM_WINDOWS_TIMESTAMP-http://timestamp.digicert.com}"
  local args=(sign -pkcs12 "$AGENT_VM_WINDOWS_PFX" -readpass "$pass" -h sha256 -n agent-vm -i https://www.agent-vm.org/)
  [ -z "$ts" ] || args+=(-t "$ts")
  ( umask 077; printf '%s' "${AGENT_VM_WINDOWS_PFX_PASS:-}" > "$pass" )
  osslsigncode "${args[@]}" -in "$exe" -out "$exe.signed" >"$exe.sign.log" 2>&1 \
    || { rm -f "$pass"; cat "$exe.sign.log" >&2; die "could not sign $exe"; }
  rm -f "$pass" "$exe.sign.log"
  mv "$exe.signed" "$exe"
}

# --- arguments -----------------------------------------------------------------
[ $# -ge 1 ] || usage
if [ "$1" = "notes" ]; then
  [ $# -eq 2 ] && valid_version "$2" || usage
  notes="$(changelog_notes "$2")"
  [ -n "$notes" ] || die "CHANGELOG.md has no '## $2' section, or it is empty"
  printf '%s\n' "$notes"
  exit 0
fi

VERSION="$1"; shift
valid_version "$VERSION" || die "not a version: '$VERSION' (expected X.Y.Z)"
TAG="v$VERSION"
DRY_RUN=""; ASSUME_YES=""; BYPASS_CHECKS=""; NOT_LATEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes)     ASSUME_YES=1 ;;
    --bypass-checks) BYPASS_CHECKS=1 ;;
    --not-latest) NOT_LATEST=1 ;;
    *)         usage ;;
  esac
  shift
done

cd "$REPO_DIR"
for t in git make go; do
  command -v "$t" >/dev/null 2>&1 || die "$t is required"
done
if [ -n "${AGENT_VM_RELEASE_TEST_NO_MACOS:-}" ]; then
  # tests/release.sh, against a throwaway repository: the whole run, here.
  PLATFORMS="linux-arm64 linux-amd64 windows-arm64 windows-amd64"
elif [ "$(uname -s)" != Darwin ]; then
  [ -n "$DRY_RUN" ] || die "a release is built on macOS: the macOS binaries need its SDK and codesign"
  PLATFORMS="linux-arm64 linux-amd64 windows-arm64 windows-amd64"
  warn "not on macOS: this dry run builds the Linux and Windows binaries only"
fi
if [ -n "${AGENT_VM_WINDOWS_PFX:-}" ]; then
  command -v osslsigncode >/dev/null 2>&1 || die "osslsigncode is required to sign the Windows binaries (brew install osslsigncode)"
  [ -f "$AGENT_VM_WINDOWS_PFX" ] || die "no file at $AGENT_VM_WINDOWS_PFX (AGENT_VM_WINDOWS_PFX)"
else
  warn "AGENT_VM_WINDOWS_PFX is not set: the Windows binaries are not signed"
fi
# A dry run changes nothing, here included: no fetch (origin is read with
# ls-remote), and gh only for reading, skipped with a warning when it is
# missing or not logged in.
GH=1
if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  [ -n "$DRY_RUN" ] || die "gh is required, and logged in"
  GH=""
  warn "gh is missing or not logged in: the checks that need it are skipped"
fi

# Checked now, not at step 6: by then the tag is pushed and the release out.
if [ -n "${AGENT_VM_TAP:-}" ]; then
  FORMULA="$AGENT_VM_TAP/Formula/agent-vm.rb"
  [ -f "$FORMULA" ] || die "no formula at $FORMULA (AGENT_VM_TAP): create it first, or unset AGENT_VM_TAP"
fi

# --- 1. the repository ---------------------------------------------------------
echo "Checking the repository"
dirty="$(git status --porcelain)"
[ -z "$dirty" ] || die "the working tree is not clean:
$dirty"
ok "working tree is clean"

current="$(git rev-parse --abbrev-ref HEAD)"
[ "$current" = "$BRANCH" ] || die "on branch '$current', not '$BRANCH' (RELEASE_BRANCH overrides)"
ok "on $BRANCH"

head="$(git rev-parse HEAD)"
# `|| true`: under set -e and pipefail, a failed ls-remote would exit here
# without a word; the check below says what went wrong.
remote_head="$(git ls-remote origin "refs/heads/$BRANCH" | cut -f1)" || true
[ -n "$remote_head" ] || die "could not read origin/$BRANCH"
[ "$head" = "$remote_head" ] \
  || die "HEAD is not origin/$BRANCH: push or pull first"
ok "level with origin/$BRANCH (${head:0:12})"

# A tag already at HEAD with no release behind it is a previous run that
# pushed the tag and then failed: pick up from the release. The commit a tag
# names: the peeled line of an annotated tag, or the tag itself.
tag_commit() {
  local local_c remote
  if local_c="$(git rev-parse -q --verify "refs/tags/$TAG^{commit}")"; then
    printf '%s\n' "$local_c"
    return
  fi
  remote="$(git ls-remote --tags origin "refs/tags/$TAG" "refs/tags/$TAG^{}")"
  printf '%s\n' "$remote" | awk -v t="refs/tags/$TAG" '$2 == t "^{}" { p = $1 } $2 == t { l = $1 } END { print (p != "" ? p : l) }'
}
RESUME=""
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
   || [ -n "$(git ls-remote --tags origin "refs/tags/$TAG")" ]; then
  if [ -z "$GH" ]; then
    die "tag $TAG already exists (without gh, whether it has a release cannot be checked)"
  elif [ "$(tag_commit)" = "$head" ] && ! gh release view "$TAG" >/dev/null 2>&1; then
    RESUME=1
    warn "tag $TAG is already at ${head:0:12}, with no release: resuming from the release"
  else
    die "tag $TAG already exists"
  fi
else
  ok "tag $TAG is free"
fi

# --- 2. version and changelog --------------------------------------------------
echo "Checking the version"
next="$(awk '$1 == "NEXT_VERSION" && $2 == ":=" { print $3 }' Makefile)"
[ "$next" = "$VERSION" ] \
  || die "the Makefile's NEXT_VERSION is '$next': set it to $VERSION and commit"
ok "the Makefile's NEXT_VERSION is $VERSION"

NOTES="$(changelog_notes "$VERSION")"
[ -n "$NOTES" ] || die "CHANGELOG.md has no '## $VERSION' section, or it is empty"
ok "CHANGELOG.md has a $VERSION section ($(printf '%s\n' "$NOTES" | wc -l | tr -d ' ') lines)"

# --- 3. tests ------------------------------------------------------------------
# CI is the authority: it runs on Linux, macOS and Windows.
# --bypass-checks skips the workflow only: the checks above decide what the
# tag and the release are, and still apply.
echo "Checking the tests"
ci="skipped"
[ -z "$GH" ] || [ -n "$BYPASS_CHECKS" ] || ci="$(gh run list --workflow go.yml --commit "$head" --limit 1 \
        --json status,conclusion --jq '.[0] | "\(.status) \(.conclusion)"' 2>/dev/null || true)"
case "$ci" in
  skipped)
    if [ -n "$BYPASS_CHECKS" ]; then warn "the CI workflow on ${head:0:12} was not checked (--bypass-checks)"
    else warn "the CI workflow on ${head:0:12} was not checked (no gh)"; fi ;;
  "completed success") ok "the CI workflow passed on ${head:0:12}" ;;
  "")                  die "no CI workflow run for ${head:0:12}: push and wait for CI" ;;
  completed*)          die "the CI workflow did not pass on ${head:0:12} ($ci)" ;;
  *)                   die "the CI workflow is still running on ${head:0:12} ($ci)" ;;
esac
for f in agent-vm.sh agent-vm.setup.sh runtime.example.sh release.sh tests/*.sh scripts/*; do
  bash -n "$f" || die "syntax error in $f"
done
sh -n www/public/install.sh || die "syntax error in www/public/install.sh"
ok "syntax checks pass here"

# --- confirmation --------------------------------------------------------------
echo
if [ -n "$DRY_RUN" ]; then
  echo "Dry run: everything checks out. A real run would do:"
elif [ -z "$ASSUME_YES" ]; then
  printf 'Tag %s at %s, push it and publish the release? [y/N] ' "$TAG" "${head:0:12}"
  reply=''
  IFS= read -r reply 2>/dev/null </dev/tty || reply=''
  case "$reply" in [Yy]*) ;; *) echo "Aborted, nothing was changed."; exit 1 ;; esac
fi

# --- 4-5. tag, push, build, release ----------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
printf '%s\n' "$NOTES" > "$WORK/notes.md"

if [ -z "$RESUME" ]; then
  run git tag -a "$TAG" -m "agent-vm $VERSION"
  run git push origin "refs/tags/$TAG"
elif [ -z "$(git ls-remote --tags origin "refs/tags/$TAG")" ]; then
  # Resumed from a tag that only exists here: `gh release create --verify-tag`
  # needs it on origin.
  run git push origin "refs/tags/$TAG"
elif ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  # Resumed from a tag that only exists on origin: the binaries are built from it.
  run git fetch --quiet origin "refs/tags/$TAG:refs/tags/$TAG"
fi
# Built from the tag, not the working tree, so the asset is what was tagged.
# It only writes into $WORK, so a dry run builds it too (from HEAD, which is
# what the tag points at, or would) to show the checksum.
ref="$TAG"
[ -z "$DRY_RUN" ] || ref="HEAD"
echo "Building the tarballs"
# shellcheck disable=SC2086
package "$ref" "$VERSION" "$WORK" $PLATFORMS
assets=()
: > "$WORK/SHA256SUMS"
for p in $PLATFORMS; do
  f="agent-vm-$VERSION-$p.tar.gz"
  sha="$(sha256_of "$WORK/$f")"
  printf '%s  %s\n' "$sha" "$f" >> "$WORK/SHA256SUMS"
  assets+=("$WORK/$f")
  ok "$f: $(du -h "$WORK/$f" | cut -f1), sha256 $sha"
done
latest=()
[ -z "$NOT_LATEST" ] || latest=(--latest=false)
run gh release create "$TAG" --verify-tag --title "agent-vm $VERSION" ${latest[@]+"${latest[@]}"} \
  --notes-file "$WORK/notes.md" "${assets[@]}" "$WORK/SHA256SUMS"

# --- 6. Homebrew -----------------------------------------------------------------
SLUG=""
[ -z "$GH" ] || SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || SLUG=""
# Else owner/repo from the origin URL, https or ssh.
[ -n "$SLUG" ] || SLUG="$(git remote get-url origin | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
BASE="https://github.com/$SLUG/releases/download/$TAG"
echo
echo "Homebrew formula, per platform (each tarball's agent-vm is the binary):"
while read -r sha f; do
  echo "  url \"$BASE/$f\""
  echo "  sha256 \"$sha\""
done < "$WORK/SHA256SUMS"

if [ -n "${AGENT_VM_TAP:-}" ]; then
  if [ -n "$NOT_LATEST" ]; then
    warn "$FORMULA is not updated (--not-latest): brew keeps the latest release"
  elif [ -n "$DRY_RUN" ]; then
    echo "Dry run: $FORMULA would be updated."
  else
    # Each url naming a platform's tarball gets this release's, and the
    # sha256 after it that tarball's. A `bottle do` block has sha256 lines
    # of its own, after no url: left alone.
    awk -v base="$BASE" -v version="$VERSION" -v sums="$WORK/SHA256SUMS" '
      BEGIN { while ((getline l < sums) > 0) { split(l, a, "  "); p = a[2]; sub(/^agent-vm-[0-9.]+-/, "", p); sub(/\.tar\.gz$/, "", p); sha[p] = a[1] } }
      /^[[:space:]]*url / {
        for (p in sha) if (index($0, "-" p ".tar.gz")) {
          sub(/url .*/, "url \"" base "/agent-vm-" version "-" p ".tar.gz\""); want = p
        }
      }
      want != "" && /^[[:space:]]*sha256 / { sub(/sha256 .*/, "sha256 \"" sha[want] "\""); want = "" }
      { print }' "$FORMULA" > "$WORK/formula.rb"
    mv "$WORK/formula.rb" "$FORMULA"
    ok "updated $FORMULA"
    echo "  Review and publish it:"
    echo "  git -C \"$AGENT_VM_TAP\" diff"
    echo "  git -C \"$AGENT_VM_TAP\" commit -am \"agent-vm $VERSION\" && git -C \"$AGENT_VM_TAP\" push"
  fi
fi

echo
[ -n "$DRY_RUN" ] && ok "dry run complete, nothing was changed" || ok "agent-vm $VERSION is released"
