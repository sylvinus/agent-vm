#!/usr/bin/env bash
#
# Checks of release.sh, in dry runs against a throwaway repository whose
# origin is a bare one, with a stub gh and a stub make (nothing is built,
# tagged on GitHub or published). Run by TestRelease (setup_script_test.go),
# or alone:
#
#   tests/release.sh

set -uo pipefail

SELF_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]:-$0}")/.." >/dev/null && pwd)"

FAIL=0
PASSED=0
pass() { PASSED=$((PASSED + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() {
  if [ "$2" = "$3" ]; then pass "$1"
  else fail "$1"; printf '         expected: %s\n         actual:   %s\n' "$3" "$2"; fi
}

SB="$(mktemp -d)"
SB="$(CDPATH= cd -P -- "$SB" >/dev/null && pwd)"
trap 'rm -rf "$SB"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
V=9.9.9

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

echo "release.sh"

# notes, on a changelog of our own: the section stops at the next heading
# and loses its surrounding blank lines.
mkdir -p "$SB/notes"
cp "$SELF_DIR/release.sh" "$SB/notes/"
printf '# Changelog\n\n## 2.0.0\n\n- two\n\n## 1.0.0\n\n- one\n' > "$SB/notes/CHANGELOG.md"
check "notes: only that version's section" "$("$SB/notes/release.sh" notes 2.0.0)" "- two"
check "notes: the last section too" "$("$SB/notes/release.sh" notes 1.0.0)" "- one"
"$SB/notes/release.sh" notes 3.0.0 >/dev/null 2>&1
check "notes: an absent version fails" "$?" "1"
"$SELF_DIR/release.sh" 1.2 >/dev/null 2>&1
check "a malformed version is refused before anything else" "$?" "1"
"$SELF_DIR/release.sh" >/dev/null 2>&1
check "no argument prints the usage (exit 2)" "$?" "2"

# The repository: what release.sh reads, NEXT_VERSION and a changelog
# section set to $V, committed and pushed.
RR="$SB/repo"; RO="$SB/origin.git"; RB="$SB/bin"
mkdir -p "$RR/www/public" "$RB"
cp -R "$SELF_DIR/release.sh" "$SELF_DIR/agent-vm.sh" "$SELF_DIR/agent-vm.setup.sh" "$SELF_DIR/runtime.example.sh" \
  "$SELF_DIR/LICENSE" "$SELF_DIR/README.md" "$SELF_DIR/tests" "$SELF_DIR/scripts" "$RR/"
cp "$SELF_DIR/www/public/install.sh" "$RR/www/public/"
printf 'NEXT_VERSION := %s\n' "$V" > "$RR/Makefile"
printf '# Changelog\n\n## %s\n\n- notes\n' "$V" > "$RR/CHANGELOG.md"
# gh: a release's assets are copied to $SB/assets.
cat > "$RB/gh" <<STUB
#!/bin/sh
case "\$1 \$2" in
  "auth status") exit 0 ;;
  "run list") echo "\${REL_CI:-completed success}" ;;
  "release view") [ -e "$SB/released" ] ;;
  "repo view") echo "o/r" ;;
  "release create")
    echo "\$*" > "$SB/gh-create.log"
    mkdir -p "$SB/assets"
    for a in "\$@"; do case "\$a" in *.tar.gz|*SHA256SUMS) cp "\$a" "$SB/assets/" ;; esac; done ;;
esac
STUB
# What signs the Windows binaries, when there is: a real executable for
# them (osslsigncode signs only one), and a self-signed certificate.
SIGN=""
if command -v osslsigncode >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 && command -v go >/dev/null 2>&1; then
  mkdir -p "$SB/hello"
  printf 'package main\nfunc main() {}\n' > "$SB/hello/main.go"
  if (cd "$SB/hello" && GOWORK=off GOOS=windows GOARCH=amd64 go build -o "$SB/hello.exe" main.go) >/dev/null 2>&1 &&
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$SB/key.pem" -out "$SB/cert.pem" -subj /CN=agent-vm-test -days 1 >/dev/null 2>&1 &&
    openssl pkcs12 -export -out "$SB/cert.pfx" -inkey "$SB/key.pem" -in "$SB/cert.pem" -passout pass:secret >/dev/null 2>&1; then
    SIGN=1
  fi
fi
# make builds a stub binary naming its platform (agent-vm.exe for Windows,
# the real executable when it is to be signed), and says what it was asked.
cat > "$RB/make" <<STUB
#!/bin/sh
echo "make \$*" >> "$SB/make.log"
case "\$*" in
  *" agent-vm "*)
    for a in "\$@"; do case "\$a" in GOOS=*) os="\${a#GOOS=}" ;; GOARCH=*) arch="\${a#GOARCH=}" ;; esac; done
    mkdir -p "\$2/_output/bin"
    if [ "\$os" != windows ]; then echo "\$os-\$arch" > "\$2/_output/bin/agent-vm"
    elif [ -n "$SIGN" ]; then cp "$SB/hello.exe" "\$2/_output/bin/agent-vm.exe"
    else echo "\$os-\$arch" > "\$2/_output/bin/agent-vm.exe"; fi ;;
esac
STUB
chmod +x "$RB/gh" "$RB/make"
( cd "$RR" && git init -q -b main && git add -A && git commit -qm r \
    && git init -q --bare "$RO" && git remote add origin "$RO" && git push -q origin main ) >/dev/null 2>&1

relrun() { ( cd "$RR" && PATH="$RB:$PATH" bash ./release.sh "$V" --dry-run "$@" ) 2>&1; }

: > "$SB/make.log"
out="$(relrun)"; rc=$?
case "$rc:$out" in
  0:*"tag v$V is free"*"NEXT_VERSION is $V"*"CI workflow passed"*'$ git tag -a'*"agent-vm-$V-linux-amd64.tar.gz: "*"sha256"*'url "https://github.com/o/r/releases/download/v'$V'/agent-vm-'$V'-linux-amd64.tar.gz"'*"dry run complete"*)
    pass "dry run: every step, each tarball's checksum and the formula lines" ;;
  *) fail "dry run: $out" ;;
esac
if [ "$(uname -s)" = Darwin ]; then
  want="darwin-arm64 darwin-amd64 linux-arm64 linux-amd64 windows-arm64 windows-amd64"
else
  want="linux-arm64 linux-amd64 windows-arm64 windows-amd64"
fi
check "dry run: each platform built, the Makefile choosing cgo" \
  "$(sed -n 's/.* agent-vm GOOS=\([a-z]*\) GOARCH=\([a-z0-9]*\) VERSION='$V'$/\1-\2/p' "$SB/make.log" | tr '\n' ' ')" "$want "
check "dry run: nothing tagged or published" "$(git -C "$RR" tag)$(ls "$SB/assets" 2>/dev/null)" ""
if [ "$(uname -s)" != Darwin ]; then
  out="$( cd "$RR" && PATH="$RB:$PATH" bash ./release.sh "$V" --yes 2>&1 )"; rc=$?
  case "$rc:$out" in 1:*"built on macOS"*) pass "not on macOS: a real release is refused" ;; *) fail "not on macOS: $out" ;; esac
fi

# The version the binaries would report must be the Makefile's.
( cd "$RR" && printf 'NEXT_VERSION := 9.9.8\n' > Makefile && git commit -qam v && git push -q origin main ) >/dev/null 2>&1
out="$(relrun)"; rc=$?
case "$rc:$out" in 1:*"NEXT_VERSION is '9.9.8'"*) pass "a Makefile on another version is refused" ;; *) fail "other version: $out" ;; esac
( cd "$RR" && printf 'NEXT_VERSION := %s\n' "$V" > Makefile && git commit -qam v && git push -q origin main ) >/dev/null 2>&1

# A missing formula stops the run before it tags or publishes anything.
out="$(AGENT_VM_TAP="$SB/no-tap" relrun)"; rc=$?
case "$rc:$out" in
  1:*"no formula at $SB/no-tap/Formula/agent-vm.rb"*)
    case "$out" in *"Checking the repository"*) fail "the formula is checked after the repository" ;; *) pass "a missing formula stops it first" ;; esac ;;
  *) fail "missing formula: $out" ;;
esac

# A failed workflow stops the run; --bypass-checks goes on, saying so.
out="$(REL_CI="completed failure" relrun)"; rc=$?
case "$rc:$out" in 1:*"did not pass"*) pass "a failed CI workflow stops it" ;; *) fail "failed workflow: $out" ;; esac
out="$(REL_CI="completed failure" relrun --bypass-checks)"; rc=$?
case "$rc:$out" in
  0:*"not checked (--bypass-checks)"*"dry run complete"*) pass "--bypass-checks: the workflow is skipped, with a warning" ;;
  *) fail "--bypass-checks: $out" ;;
esac

# A run that pushed the tag and then failed to publish is picked up again,
# rather than stuck on "tag already exists".
( cd "$RR" && git tag -a "v$V" -m t && git push -q origin "v$V" ) >/dev/null 2>&1
out="$(relrun)"
case "$out" in
  *"with no release: resuming"*"dry run complete"*) pass "a tag with no release is resumed" ;;
  *) fail "resume: $out" ;;
esac
case "$out" in *'$ git tag'*|*'$ git push'*) fail "resume: tags or pushes again" ;; *) pass "resume: neither tags nor pushes again" ;; esac
touch "$SB/released"
case "$(relrun)" in *"tag v$V already exists"*) pass "a released tag is still refused" ;; *) fail "a released tag was not refused" ;; esac
rm -f "$SB/released"

# The tag made here but never pushed: resumed too, and pushed before the
# release, which `gh release create --verify-tag` needs on origin.
git -C "$RR" push -q origin ":refs/tags/v$V" >/dev/null 2>&1
out="$(relrun)"
case "$out" in
  *"resuming"*"\$ git push origin refs/tags/v$V"*"\$ gh release create"*) pass "resume: a tag only made here is pushed first" ;;
  *) fail "resume, local tag: $out" ;;
esac
case "$out" in *'$ git tag'*) fail "resume: tags again" ;; *) pass "resume: and not tagged again" ;; esac

# A real run, with the Linux platforms only: tagged, pushed, published, and
# the formula's per-platform urls and checksums updated.
git -C "$RR" tag -d "v$V" >/dev/null
mkdir -p "$SB/tap/Formula"
cat > "$SB/tap/Formula/agent-vm.rb" <<'EOF'
class AgentVm < Formula
  on_linux do
    on_arm do
      url "https://github.com/o/r/releases/download/v1.0.0/agent-vm-1.0.0-linux-arm64.tar.gz"
      sha256 "old-arm"
    end
    on_intel do
      url "https://github.com/o/r/releases/download/v1.0.0/agent-vm-1.0.0-linux-amd64.tar.gz"
      sha256 "old-intel"
    end
  end
  bottle do
    sha256 "bottle"
  end
end
EOF
# --not-latest: GitHub keeps its latest release, and brew its formula.
out="$(AGENT_VM_TAP="$SB/tap" relrun --not-latest)"; rc=$?
case "$rc:$out" in
  0:*'$ gh release create v'$V' --verify-tag --title agent-vm '$V' --latest=false'*"not updated (--not-latest)"*"dry run complete"*)
    pass "--not-latest: not the latest release, the formula left alone" ;;
  *) fail "--not-latest: $out" ;;
esac
check "--not-latest: the formula unchanged" "$(grep -c 'v1.0.0' "$SB/tap/Formula/agent-vm.rb")" "2"

sign_env=()
[ -z "$SIGN" ] || sign_env=(AGENT_VM_WINDOWS_PFX="$SB/cert.pfx" AGENT_VM_WINDOWS_PFX_PASS=secret AGENT_VM_WINDOWS_TIMESTAMP=)
out="$( cd "$RR" && env ${sign_env[@]+"${sign_env[@]}"} AGENT_VM_TAP="$SB/tap" AGENT_VM_RELEASE_TEST_NO_MACOS=1 PATH="$RB:$PATH" bash ./release.sh "$V" --yes 2>&1 )"; rc=$?
case "$rc:$out" in 0:*"agent-vm $V is released"*) pass "real run: released" ;; *) fail "real run: $out" ;; esac
check "real run: the tag is on origin" "$(git -C "$RO" tag)" "v$V"
check "real run: the latest release (no --latest=false)" "$(grep -c -- '--latest=false' "$SB/gh-create.log")" "0"
# Byte order (LC_ALL=C): macOS sorts these differently in its locale.
check "real run: one tarball per platform, and their sums" "$(LC_ALL=C ls "$SB/assets" | tr '\n' ' ')" \
  "SHA256SUMS agent-vm-$V-linux-amd64.tar.gz agent-vm-$V-linux-arm64.tar.gz agent-vm-$V-windows-amd64.tar.gz agent-vm-$V-windows-arm64.tar.gz "
check "real run: Windows's is agent-vm.exe" \
  "$(tar -tzf "$SB/assets/agent-vm-$V-windows-arm64.tar.gz" | grep -c "^agent-vm-$V/agent-vm.exe$")" "1"
if [ -n "$SIGN" ]; then
  tar -xzOf "$SB/assets/agent-vm-$V-windows-amd64.tar.gz" "agent-vm-$V/agent-vm.exe" > "$SB/signed.exe"
  case "$(osslsigncode verify -CAfile "$SB/cert.pem" -in "$SB/signed.exe" 2>&1)" in
    *"Signature verification: ok"*) pass "real run: the Windows binary is signed, with that certificate" ;;
    *) fail "real run: signature: $(osslsigncode verify -CAfile "$SB/cert.pem" -in "$SB/signed.exe" 2>&1 | tail -5)" ;;
  esac
  case "$out" in *secret*) fail "real run: the password was printed" ;; *) pass "real run: the password is never printed" ;; esac
else
  printf '  skip signing (needs osslsigncode, openssl and go)\n'
fi
sums_ok=1
while read -r sum f; do
  [ "$(sha256_of "$SB/assets/$f")" = "$sum" ] || sums_ok=0
done < "$SB/assets/SHA256SUMS"
check "real run: SHA256SUMS matches the tarballs" "$sums_ok" "1"
check "real run: each tarball has its platform's binary, agent-vm.sh and the docs" \
  "$(tar -tzf "$SB/assets/agent-vm-$V-linux-arm64.tar.gz" | LC_ALL=C sort | tr '\n' ' ')$(tar -xzOf "$SB/assets/agent-vm-$V-linux-arm64.tar.gz" "agent-vm-$V/agent-vm")" \
  "agent-vm-$V/ agent-vm-$V/CHANGELOG.md agent-vm-$V/LICENSE agent-vm-$V/README.md agent-vm-$V/agent-vm agent-vm-$V/agent-vm.sh agent-vm-$V/runtime.example.sh linux-arm64"
arm="$(awk '$2 ~ /linux-arm64/ { print $1 }' "$SB/assets/SHA256SUMS")"
intel="$(awk '$2 ~ /linux-amd64/ { print $1 }' "$SB/assets/SHA256SUMS")"
check "real run: the formula's urls and checksums, per platform; the bottle's left" \
  "$(grep -E 'url|sha256' "$SB/tap/Formula/agent-vm.rb" | tr -s ' ' | tr '\n' '|')" \
  " url \"https://github.com/o/r/releases/download/v$V/agent-vm-$V-linux-arm64.tar.gz\"| sha256 \"$arm\"| url \"https://github.com/o/r/releases/download/v$V/agent-vm-$V-linux-amd64.tar.gz\"| sha256 \"$intel\"| sha256 \"bottle\"|"

printf '\n%s passed, %s failed\n' "$PASSED" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
