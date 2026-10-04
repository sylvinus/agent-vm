package cli

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/sylvinus/agent-vm/internal/gitguard"
	"github.com/sylvinus/agent-vm/internal/mounts"
	"github.com/sylvinus/agent-vm/internal/vm"
)

// promptsDisabledBy is what turned the security questions off, if
// something did: --unsafe-disable-security-prompts, or
// AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1 in the shell. Never a file of
// the project, which the VM can write.
func (s *start) promptsDisabledBy() (string, bool) {
	switch {
	case s.opts.UnsafeNoPrompts:
		return "--unsafe-disable-security-prompts", true
	case os.Getenv("AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS") == "1":
		return "AGENT_VM_UNSAFE_DISABLE_SECURITY_PROMPTS=1", true
	}
	return "", false
}

// confirmUnsafe is the question after a security warning: true to go on.
// No by default, and when it cannot be asked; yes when the questions are
// off.
func (s *start) confirmUnsafe() bool {
	if by, ok := s.promptsDisabledBy(); ok {
		fmt.Fprintf(s.io.Stderr, "Continuing: %s.\n", by)
		return true
	}
	return s.ui.CanAsk() && s.ui.AskYN("Continue anyway?", false)
}

func (s *start) warnf(format string, a ...any) {
	fmt.Fprintf(s.io.Stderr, format+"\n", a...)
}

// writableGitWarning is printed on every start with .git left writable.
func (s *start) writableGitWarning() {
	why := "AGENT_VM_UNSAFE_WRITABLE_GIT=1"
	if s.opts.UnsafeWritableGit {
		why = "--unsafe-writable-git"
	}
	fmt.Fprintf(s.io.Stderr, `!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! WARNING: %s. The VM can write every .git.
!!
!! The agent can change .git/config and .git/hooks in the shared folders, and
!! git on this machine runs what they name: on your next commit, and whenever
!! your editor or shell prompt calls git. That is running commands on your
!! host, outside the VM. Without it, .git stays read-only.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
`, why)
}

// checks are the security checks of a start, before anything changes. A
// running VM that keeps running (s.vmUp) gets the warnings and nothing is
// asked. False when the start must stop.
func (s *start) checks() bool {
	s.protect, s.names, s.notes = false, nil, ""
	if !s.opts.Scratch {
		if writableGitOptOut(s.opts.UnsafeWritableGit) {
			s.writableGitWarning()
		} else {
			s.protect = true
		}
	}
	if s.protect {
		// The names the shares need: those always listed, and one per hooks
		// folder git runs from in a share, its first component. A dot-name
		// (.husky, .githooks) is taken as is; any other is read-only in
		// every folder of every share, so it is asked first (yes by
		// default, and when no one can answer). A folder that cannot be
		// protected, or one declined, is a risk to accept. So are the
		// scan's risks. Under --readonly the VM writes none of them.
		scan := s.scan(s.ctx, s.dir)
		var hooks []string
		for _, h := range scan.Hooks {
			rel, inRepo, _ := strings.Cut(h, "\t")
			if rel == "" {
				continue
			}
			name, ok := gitguard.HooksName(inRepo)
			if s.opts.ReadOnly {
				if ok {
					hooks = append(hooks, name)
				}
				continue
			}
			if !ok {
				switch {
				case rel == ".":
					s.warnf("Warning: git's core.hooksPath is the project directory itself, which the VM can write: git on this machine runs the hooks the agent puts there.")
				case inRepo == ".":
					s.warnf("Warning: git's core.hooksPath is '%s', which the VM can write, and no read-only name covers it (the top of a repository, or in a writable volume): git on this machine runs the hooks the agent puts there.", rel)
				default:
					s.warnf("Warning: git's core.hooksPath is '%s', which the VM can write, and its name cannot be made read-only: git on this machine runs the hooks the agent puts there.", rel)
				}
				if !s.vmUp && !s.confirmUnsafe() {
					s.warnf("Aborted. Point core.hooksPath to a folder of the project (agent-vm keeps it read-only), or outside it.")
					return false
				}
				continue
			}
			if _, off := s.promptsDisabledBy(); !strings.HasPrefix(name, ".") && !s.vmUp && !off && s.ui.CanAsk() &&
				!s.ui.AskYN(fmt.Sprintf("Git runs hooks from %s. Make every '%s' folder in the project read-only for the VM?", rel, name), true) {
				s.warnf("Warning: '%s' stays writable, and git on this machine runs the hooks the agent puts in %s.", name, rel)
				if !s.confirmUnsafe() {
					s.warnf("Aborted. Answer yes to protect it, or point core.hooksPath outside the project.")
					return false
				}
				continue
			}
			hooks = append(hooks, name)
			s.notes += fmt.Sprintf("Note: git runs hooks from %s (core.hooksPath): every '%s' in the project is read-only for the VM too.\n", rel, name)
		}
		s.names = gitguard.NamesWith(hooks)
		// What the names accepted keep read-only is no risk; a name declined
		// keeps nothing.
		if risks := scan.Risks(s.names); !s.opts.ReadOnly && len(risks) > 0 {
			s.warnf("Warning: git on this machine uses these, and the VM can write them:")
			for _, r := range risks {
				s.warnf("  %s", r)
			}
			if !s.vmUp && !s.confirmUnsafe() {
				s.warnf("Aborted. Move them out of the shared folders, or have them name commands outside them.")
				return false
			}
		}
	}
	// A repository not named .git, which no name protects: only a VM that
	// can write needs the setting.
	if !s.opts.ReadOnly && !s.opts.Scratch {
		return s.checkBareRepo()
	}
	return true
}

// checkBareRepo offers to set safe.bareRepository=explicit when it can ask.
// Not set: a security question, no by default. With the questions off,
// nothing is offered: the global git config is not changed unasked. For a
// VM already running, a warning only.
func (s *start) checkBareRepo() bool {
	st := gitguard.BareState(s.ctx)
	if st == gitguard.BareOK || st == gitguard.BareNoGit {
		return true
	}
	if s.vmUp {
		s.warnf("Warning: git on this machine uses repositories a VM creates under another name than .git ('agent-vm doctor' says more).")
		return true
	}
	s.ui.Box("Git: repositories not named .git", gitguard.BareHint)
	if st == gitguard.BareOld {
		out, _ := exec.CommandContext(s.ctx, "git", "--version").Output()
		s.warnf("Warning: %s is older than 2.38 and ignores that setting.", strings.TrimSpace(string(out)))
		if s.confirmUnsafe() {
			return true
		}
		s.warnf("Aborted. Upgrade git, then run the command above.")
		return false
	}
	if _, off := s.promptsDisabledBy(); !off && s.ui.CanAsk() && s.ui.AskYN("Run it now? It changes your global git config.", true) {
		err := exec.CommandContext(s.ctx, "git", "config", "--global", "safe.bareRepository", "explicit").Run()
		if err == nil && gitguard.BareState(s.ctx) == gitguard.BareOK {
			fmt.Fprintln(s.io.Stdout, "Git on this machine now ignores repositories not named .git unless you name them.")
			return true
		}
		s.warnf("Warning: the setting did not take.")
	}
	s.warnf("Warning: not set. Until it is, git on this machine can run what a VM writes.")
	if s.confirmUnsafe() {
		return true
	}
	s.warnf("Aborted. Run the command above, then run agent-vm again.")
	return false
}

// start is one start of a project's VM.
type start struct {
	*app
	ctx  context.Context
	opts VMOpts
	name string // the VM
	dir  string // the project, as the shell spells it

	vmUp    bool     // running when the start began, and not reset
	protect bool     // every .git read-only
	names   []string // the read-only names, when protect
	notes   string   // hooks notes, printed once the names apply

	built      []vm.Mount // see shares
	builtFiles []mounts.FileMount
	builtKey   string
}
