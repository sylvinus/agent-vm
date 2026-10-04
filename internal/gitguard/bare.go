package gitguard

import (
	"context"
	"os/exec"
	"strings"

	"github.com/sylvinus/agent-vm/internal/version"
)

// readonlyNames protects a name, and a bare repository has none: a folder
// with HEAD, objects/ and refs/ is a repository to git, found by the same
// upward search from the current directory as a .git. Its config then
// applies, and some of it names commands git runs (core.pager on `git log`).
// The VM can create such a folder anywhere in a share.
// safe.bareRepository=explicit (git 2.38+) makes git use one only when
// --git-dir or GIT_DIR names it.

// Bare-repository states.
const (
	BareOK    = "ok"
	BareUnset = "unset"
	BareOld   = "old" // git before 2.38, which ignores the setting
	BareNoGit = "nogit"
)

// BareState is whether git on this machine ignores bare repositories it is
// not told about. Read from /, outside any repository: git only honours the
// setting from the system and global config.
func BareState(ctx context.Context) string {
	if _, err := exec.LookPath("git"); err != nil {
		return BareNoGit
	}
	out, _ := exec.CommandContext(ctx, "git", "--version").Output()
	v := strings.TrimPrefix(strings.TrimSpace(string(out)), "git version ")
	v, _, _ = strings.Cut(v, " ")
	if !version.AtLeast(v, "2.38.0") {
		return BareOld
	}
	cmd := exec.CommandContext(ctx, "git", "config", "--get", "safe.bareRepository")
	cmd.Dir = "/"
	if out, _ := cmd.Output(); strings.TrimSpace(string(out)) == "explicit" {
		return BareOK
	}
	return BareUnset
}

// BareHint is why the setting matters and how to set it, one paragraph per
// line.
const BareHint = `Git treats any folder with HEAD, objects/ and refs/ as a repository, even without .git, and runs commands its config names (on ` + "`git log`" + `, for one). A VM could create one in your projects, and the .git protection does not cover it.

This makes git ignore such folders unless named with --git-dir:
  git config --global safe.bareRepository explicit
`
