#!/usr/bin/env bash
#
# Cut an agent-vm release.
#
#   ./release.sh X.Y.Z             check, then tag, push and publish
#   ./release.sh X.Y.Z --dry-run   run every check, change nothing
#   ./release.sh X.Y.Z --yes       no confirmation prompt
#   ./release.sh notes X.Y.Z       print that version's CHANGELOG.md section
#
# It bumps and commits nothing. First, in an ordinary commit on main: set
# AGENT_VM_VERSION in agent-vm.sh and add a "## X.Y.Z" section to CHANGELOG.md.
# Push it and let CI pass. This script then checks that commit and publishes it:
#
#   1. clean tree, on main, level with origin/main, tag vX.Y.Z not taken (or
#      already on this commit with no release: a failed run, resumed at 5)
#   2. agent-vm.sh reports X.Y.Z, CHANGELOG.md has a non-empty X.Y.Z section
#   3. the test workflow passed on this commit, and ./test.sh passes here
#   4. annotated tag vX.Y.Z, pushed
#   5. GitHub release: the CHANGELOG section as notes, plus a tarball made by
#      `git archive` (without www/ and the tests) and its SHA256SUMS. The tarball is built here, so its
#      checksum does not depend on how GitHub generates archives.
#   6. the url and sha256 lines for the Homebrew formula. With
#      AGENT_VM_TAP=<path to a homebrew-tap clone>, Formula/agent-vm.rb there
#      is updated too, and the commands to commit it are printed.
#
# Needs git, gh (logged in) and shasum or sha256sum.

set -euo pipefail

REPO_DIR="$(CDPATH= cd -P -- "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null && pwd)"
BRANCH="${RELEASE_BRANCH:-main}"

c_g=''; c_y=''; c_r=''; c_0=''
if [ -t 1 ]; then c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_0=$'\033[0m'; fi
ok()   { printf '%s✓%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s!%s %s\n' "$c_y" "$c_0" "$*"; }
die()  { printf '%s✗%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }

usage() {
  sed -n '5,8p' "$0" | sed 's/^# \{0,1\}//' >&2
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
DRY_RUN=""; ASSUME_YES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes)     ASSUME_YES=1 ;;
    *)         usage ;;
  esac
  shift
done

cd "$REPO_DIR"
for tool in git gh; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

# --- 1. the repository ---------------------------------------------------------
echo "Checking the repository"
dirty="$(git status --porcelain)"
[ -z "$dirty" ] || die "the working tree is not clean:
$dirty"
ok "working tree is clean"

current="$(git rev-parse --abbrev-ref HEAD)"
[ "$current" = "$BRANCH" ] || die "on branch '$current', not '$BRANCH' (RELEASE_BRANCH overrides)"
ok "on $BRANCH"

git fetch --quiet --tags origin "$BRANCH"
head="$(git rev-parse HEAD)"
[ "$head" = "$(git rev-parse "origin/$BRANCH")" ] \
  || die "HEAD is not origin/$BRANCH: push or pull first"
ok "level with origin/$BRANCH (${head:0:12})"

# A tag already at HEAD with no release behind it is a previous run that
# pushed the tag and then failed: pick up from the release.
RESUME=""
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
   || [ -n "$(git ls-remote --tags origin "refs/tags/$TAG")" ]; then
  git fetch --quiet origin "refs/tags/$TAG:refs/tags/$TAG" 2>/dev/null || true
  if [ "$(git rev-parse -q --verify "refs/tags/$TAG^{commit}")" = "$head" ] \
     && ! gh release view "$TAG" >/dev/null 2>&1; then
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
reported="$(bash ./agent-vm.sh version)"
[ "$reported" = "$VERSION" ] \
  || die "agent-vm.sh reports $reported: set AGENT_VM_VERSION=\"$VERSION\" and commit"
ok "agent-vm.sh reports $VERSION"

NOTES="$(changelog_notes "$VERSION")"
[ -n "$NOTES" ] || die "CHANGELOG.md has no '## $VERSION' section, or it is empty"
ok "CHANGELOG.md has a $VERSION section ($(printf '%s\n' "$NOTES" | wc -l | tr -d ' ') lines)"

# --- 3. tests ------------------------------------------------------------------
# CI is the authority: it runs bash 3.2 and zsh, which this machine may lack.
echo "Checking the tests"
ci="$(gh run list --workflow test.yml --commit "$head" --limit 1 \
        --json status,conclusion --jq '.[0] | "\(.status) \(.conclusion)"' 2>/dev/null || true)"
case "$ci" in
  "completed success") ok "the test workflow passed on ${head:0:12}" ;;
  "")                  die "no test workflow run for ${head:0:12}: push and wait for CI" ;;
  completed*)          die "the test workflow did not pass on ${head:0:12} ($ci)" ;;
  *)                   die "the test workflow is still running on ${head:0:12} ($ci)" ;;
esac
for f in agent-vm.sh lib/*.sh agent-vm.setup.sh install.sh runtime.example.sh test.sh tests/*.sh test-e2e.sh release.sh; do
  bash -n "$f" || die "syntax error in $f"
done
sh -n www/public/install.sh || die "syntax error in www/public/install.sh"
./test.sh >/dev/null 2>&1 || die "./test.sh fails here: run it to see why"
ok "./test.sh passes here"

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

# --- 4-5. tag, push, release ---------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
printf '%s\n' "$NOTES" > "$WORK/notes.md"
TARBALL="agent-vm-$VERSION.tar.gz"

if [ -z "$RESUME" ]; then
  run git tag -a "$TAG" -m "agent-vm $VERSION"
  run git push origin "refs/tags/$TAG"
fi
# Built from the tag, not the working tree, so the asset is what was tagged.
# It only writes into $WORK, so a dry run builds it too (from HEAD, which is
# what the tag would point at) to show the checksum. www/ and the tests are
# left out by export-ignore in .gitattributes.
ref="$TAG"
[ -z "$DRY_RUN" ] || [ -n "$RESUME" ] || ref="HEAD"
git archive --format=tar.gz --prefix="agent-vm-$VERSION/" -o "$WORK/$TARBALL" "$ref"
SHA="$(sha256_of "$WORK/$TARBALL")"
printf '%s  %s\n' "$SHA" "$TARBALL" > "$WORK/SHA256SUMS"
run gh release create "$TAG" --verify-tag --title "agent-vm $VERSION" \
  --notes-file "$WORK/notes.md" "$WORK/$TARBALL" "$WORK/SHA256SUMS"

# --- 6. Homebrew -----------------------------------------------------------------
SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
URL="https://github.com/$SLUG/releases/download/$TAG/$TARBALL"
echo
echo "Homebrew formula:"
echo "  url \"$URL\""
echo "  sha256 \"$SHA\""

if [ -n "${AGENT_VM_TAP:-}" ]; then
  formula="$AGENT_VM_TAP/Formula/agent-vm.rb"
  [ -f "$formula" ] || die "no formula at $formula"
  if [ -n "$DRY_RUN" ]; then
    echo "Dry run: $formula would be updated."
  else
    sed -e "s|^\\([[:space:]]*url \\).*|\\1\"$URL\"|" \
        -e "s|^\\([[:space:]]*sha256 \\).*|\\1\"$SHA\"|" "$formula" > "$WORK/formula.rb"
    mv "$WORK/formula.rb" "$formula"
    ok "updated $formula"
    echo "  Review and publish it:"
    echo "  git -C \"$AGENT_VM_TAP\" diff"
    echo "  git -C \"$AGENT_VM_TAP\" commit -am \"agent-vm $VERSION\" && git -C \"$AGENT_VM_TAP\" push"
  fi
fi

echo
[ -n "$DRY_RUN" ] && ok "dry run complete, nothing was changed" || ok "agent-vm $VERSION is released"
