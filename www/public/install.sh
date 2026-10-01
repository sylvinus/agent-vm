#!/bin/sh
#
# agent-vm installer, served at https://www.agent-vm.org/install.sh
#
#   curl -fsSL https://www.agent-vm.org/install.sh | sh
#   curl -fsSL https://www.agent-vm.org/install.sh | sh -s -- --git
#
# Options:
#   --version X.Y.Z   install that release instead of the latest one
#   --git             install a git clone of main instead of a release
#   --dir DIR         where agent-vm goes (default: ~/.local/share/agent-vm,
#                     or $XDG_DATA_HOME/agent-vm)
#
# A release is the tarball published on GitHub, checked against its SHA256SUMS.
# Running this again replaces it with the latest release. A clone is updated
# with `git pull`, or by running this again with --git.
#
# Then `agent-vm.sh install` links agent-vm into ~/.local/bin (AGENT_VM_BIN_DIR
# overrides). Nothing needs root.
#
# Everything is in functions and only the last line runs them, so a download
# cut short runs nothing.

set -eu

REPO="sylvinus/agent-vm"

say() { printf 'agent-vm: %s\n' "$*"; }
die() { printf 'agent-vm: error: %s\n' "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

usage() {
  echo "usage: install.sh [--version X.Y.Z] [--git] [--dir DIR]" >&2
  exit 2
}

# HTTPS only, redirects included: the release assets redirect to another host.
fetch() {
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 3 -o "$2" "$1"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else die "neither sha256sum nor shasum is installed"
  fi
}

cleanup() {
  [ -z "$TMP" ] || rm -rf "$TMP"
  [ -z "$LEFTOVER" ] || rm -rf "$LEFTOVER"
  # Stopped between the two renames: the previous version goes back.
  if [ -n "$ROLLBACK" ] && [ -e "$ROLLBACK" ] && [ ! -e "$DIR" ]; then
    mv "$ROLLBACK" "$DIR" && say "interrupted: the previous version is back in $DIR"
  fi
}

install_release() {
  need curl
  need tar
  if [ -e "$DIR/.git" ]; then
    die "$DIR is a git clone: update it with 'git -C \"$DIR\" pull', or run this with --git"
  fi
  if [ -e "$DIR" ] && [ ! -f "$DIR/agent-vm.sh" ]; then
    die "$DIR exists and is not an agent-vm install: move it, or pick another --dir"
  fi

  if [ -n "$WANT_VERSION" ]; then
    base="https://github.com/$REPO/releases/download/v$WANT_VERSION"
  else
    base="https://github.com/$REPO/releases/latest/download"
  fi
  fetch "$base/SHA256SUMS" "$TMP/SHA256SUMS" || die "could not download $base/SHA256SUMS"

  # One line per asset: "<sha256>  agent-vm-X.Y.Z.tar.gz".
  tarball="$(awk '$2 ~ /^agent-vm-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$/ { print $2; exit }' "$TMP/SHA256SUMS")"
  [ -n "$tarball" ] || die "SHA256SUMS lists no agent-vm tarball"
  expected="$(awk -v f="$tarball" '$2 == f { print $1; exit }' "$TMP/SHA256SUMS")"
  version="${tarball#agent-vm-}"
  version="${version%.tar.gz}"
  if [ -n "$WANT_VERSION" ] && [ "$version" != "$WANT_VERSION" ]; then
    die "asked for $WANT_VERSION, the release has $tarball"
  fi

  # From the tag, not from latest/: a release published in between would not
  # match the checksum read above.
  say "downloading agent-vm $version"
  fetch "https://github.com/$REPO/releases/download/v$version/$tarball" "$TMP/$tarball" \
    || die "could not download $tarball"
  actual="$(sha256_of "$TMP/$tarball")"
  [ "$actual" = "$expected" ] || die "checksum mismatch for $tarball (expected $expected, got $actual)"

  mkdir "$TMP/x"
  tar -xzf "$TMP/$tarball" -C "$TMP/x"
  src="$TMP/x/agent-vm-$version"
  [ -f "$src/agent-vm.sh" ] || die "$tarball has no agent-vm-$version/agent-vm.sh"

  # Staged next to $DIR so the swap is two renames on one filesystem. The
  # previous version is left in LEFTOVER, which cleanup removes, or put back
  # from ROLLBACK when the swap did not finish.
  mkdir -p "$(dirname "$DIR")"
  LEFTOVER="$DIR.new.$$"
  mv "$src" "$LEFTOVER"
  if [ -e "$DIR" ]; then
    ROLLBACK="$DIR.old.$$"
    mv "$DIR" "$ROLLBACK"
    mv "$LEFTOVER" "$DIR"
    LEFTOVER="$ROLLBACK"
    ROLLBACK=""
  else
    mv "$LEFTOVER" "$DIR"
    LEFTOVER=""
  fi
  say "agent-vm $version is in $DIR"
}

install_git() {
  need git
  if [ -e "$DIR/.git" ]; then
    say "updating the clone in $DIR"
    git -C "$DIR" pull --ff-only
  elif [ -e "$DIR" ]; then
    die "$DIR exists and is not a git clone: move it, or pick another --dir"
  else
    mkdir -p "$(dirname "$DIR")"
    git clone "https://github.com/$REPO.git" "$DIR"
  fi
}

main() {
  WANT_VERSION=""; USE_GIT=""; DIR=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || usage
        WANT_VERSION="$2"; shift ;;
      --version=*) WANT_VERSION="${1#*=}" ;;
      --git) USE_GIT=1 ;;
      --dir)
        [ $# -ge 2 ] || usage
        DIR="$2"; shift ;;
      --dir=*) DIR="${1#*=}" ;;
      -h|--help) usage ;;
      *) usage ;;
    esac
    shift
  done
  WANT_VERSION="${WANT_VERSION#v}"
  if [ -n "$WANT_VERSION" ]; then
    printf '%s\n' "$WANT_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
      || die "not a version: '$WANT_VERSION' (expected X.Y.Z)"
    [ -z "$USE_GIT" ] || die "--version installs a release: it does not go with --git"
  fi

  case "$(uname -s)" in
    Darwin|Linux|MINGW*|MSYS*|CYGWIN*) ;;
    *) die "agent-vm runs on macOS, Linux and Windows (Git Bash) only" ;;
  esac
  need bash

  [ -n "${HOME:-}" ] || die "HOME is not set"
  [ -n "$DIR" ] || DIR="${XDG_DATA_HOME:-$HOME/.local/share}/agent-vm"
  # C:/... and C:\... are absolute too, in Git Bash.
  case "$DIR" in
    /*|[A-Za-z]:/*|[A-Za-z]:\\*) ;;
    *) DIR="$(pwd)/$DIR" ;;
  esac
  DIR="${DIR%/}"

  TMP=""; LEFTOVER=""; ROLLBACK=""
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM
  TMP="$(mktemp -d 2>/dev/null || mktemp -d -t agent-vm)"

  if [ -n "$USE_GIT" ]; then install_git; else install_release; fi

  # `install` can go on to run `agent-vm setup`, whose brew and limactl calls
  # may read stdin: give them the terminal, not the rest of this pipe.
  if (exec </dev/tty) 2>/dev/null; then
    bash "$DIR/agent-vm.sh" install </dev/tty
  else
    bash "$DIR/agent-vm.sh" install </dev/null
  fi
}

main "$@"
