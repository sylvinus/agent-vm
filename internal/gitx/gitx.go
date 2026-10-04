// Package gitx runs git on this machine in folders the VM can write.
package gitx

import (
	"context"
	"os/exec"
)

// Untrusted is git for agent-vm's own calls in a folder the VM can write.
// The VM may have planted a repository there: a bare one, whatever the
// user's safe.bareRepository, or a .git where it cannot be protected.
// Command-line config is trusted where a repository's own is not:
// safe.bareRepository=explicit refuses the bare one, core.fsmonitor=false
// stops the command a repository's config names from running on commands
// that read the index, and --no-pager the pager its config would start.
func Untrusted(ctx context.Context, args ...string) *exec.Cmd {
	return exec.CommandContext(ctx, "git", append([]string{"--no-pager", "-c", "safe.bareRepository=explicit", "-c", "core.fsmonitor=false"}, args...)...)
}

// Have reports whether git is installed.
func Have() bool {
	_, err := exec.LookPath("git")
	return err == nil
}
