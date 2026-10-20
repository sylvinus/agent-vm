package engine

import (
	"os/exec"
	"strings"

	"github.com/sylvinus/agent-vm/internal/gitguard"
	"github.com/sylvinus/agent-vm/internal/guard"
	"github.com/sylvinus/agent-vm/internal/netguard"
	"github.com/sylvinus/agent-vm/internal/policy"
)

// promptsDisabledBy is what turned the security questions off, if something
// did: Spec.UnsafeNoPrompts. Never a file of the project, which the VM can
// write.
func (s *session) promptsDisabledBy() (string, bool) {
	if s.spec.UnsafeNoPrompts != "" {
		return s.spec.UnsafeNoPrompts, true
	}
	return "", false
}

// confirmUnsafe is the question after a security warning: true to go on. No
// by default, and when it cannot be asked; yes when the questions are off.
// topic says what the warning was about.
func (s *session) confirmUnsafe(topic string) bool {
	if by, ok := s.promptsDisabledBy(); ok {
		s.warnf("Continuing: %s.", by)
		return true
	}
	return s.canAsk() && s.ask(Question{Kind: QUnsafe, Title: topic, Prompt: "Continue anyway?"})
}

// writableGitWarning is told on every start with .git left writable.
func (s *session) writableGitWarning() {
	why := "AGENT_VM_UNSAFE_WRITABLE_GIT=1"
	if s.spec.UnsafeWritableGit {
		why = "--unsafe-writable-git"
	}
	s.warnf(`!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! WARNING: %s. The VM can write every .git.
!!
!! The agent can change .git/config and .git/hooks in the shared folders, and
!! git on this machine runs what they name: on your next commit, and whenever
!! your editor or shell prompt calls git. That is running commands on your
!! host, outside the VM. Without it, .git stays read-only.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!`, why)
}

// checks are the security checks of a start, before anything changes. A
// running VM that keeps running (s.vmUp) gets the warnings and nothing is
// asked. False when the start must stop.
func (s *session) checks() bool {
	s.protect, s.names, s.notes = false, nil, ""
	if !s.noShares {
		if s.writableGitOptOut() {
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
		scan := s.Scan(s.ctx, s.dir)
		var hooks []string
		for _, h := range scan.Hooks {
			rel, inRepo, _ := strings.Cut(h, "\t")
			if rel == "" {
				continue
			}
			name, ok := gitguard.HooksName(inRepo)
			if s.spec.ReadOnly {
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
				if !s.vmUp && !s.confirmUnsafe("hooks") {
					s.warnf("Aborted. Point core.hooksPath to a folder of the project (%s keeps it read-only), or outside it.", s.app)
					return false
				}
				continue
			}
			if _, off := s.promptsDisabledBy(); !strings.HasPrefix(name, ".") && !s.vmUp && !off && s.canAsk() &&
				!s.ask(Question{Kind: QHooks, Title: rel, Prompt: "Git runs hooks from " + rel + ". Make every '" + name + "' folder in the project read-only for the VM?", Default: true}) {
				s.warnf("Warning: '%s' stays writable, and git on this machine runs the hooks the agent puts in %s.", name, rel)
				if !s.confirmUnsafe("hooks") {
					s.warnf("Aborted. Answer yes to protect it, or point core.hooksPath outside the project.")
					return false
				}
				continue
			}
			hooks = append(hooks, name)
			s.notes += "Note: git runs hooks from " + rel + " (core.hooksPath): every '" + name + "' in the project is read-only for the VM too.\n"
		}
		s.names = gitguard.NamesWith(hooks)
		// What the names accepted keep read-only is no risk; a name declined
		// keeps nothing.
		if risks := scan.Risks(s.names); !s.spec.ReadOnly && len(risks) > 0 {
			s.warnf("Warning: git on this machine uses these, and the VM can write them:")
			for _, r := range risks {
				s.warnf("  %s", r)
			}
			if !s.vmUp && !s.confirmUnsafe("git-config") {
				s.warnf("Aborted. Move them out of the shared folders, or have them name commands outside them.")
				return false
			}
		}
	}
	// A repository not named .git, which no name protects: only a VM that
	// can write needs the setting.
	if !s.spec.ReadOnly && !s.noShares {
		return s.checkBareRepo()
	}
	return true
}

// writableGitOptOut: Options.UnsafeWritableGit, or Spec.UnsafeWritableGit
// for one start, leaves .git writable. Only the program that runs the engine
// can ask for it.
func (s *session) writableGitOptOut() bool {
	return s.spec.UnsafeWritableGit || s.opts.UnsafeWritableGit
}

// WritableGitOptOut reports whether .git is left writable by the options.
func (e *Engine) WritableGitOptOut(flag bool) bool { return flag || e.opts.UnsafeWritableGit }

// checkBareRepo offers to set safe.bareRepository=explicit when it can ask.
// Not set: a security question, no by default. With the questions off,
// nothing is offered: the global git config is not changed unasked. For a
// VM already running, a warning only.
func (s *session) checkBareRepo() bool {
	st := gitguard.BareState(s.ctx)
	if st == gitguard.BareOK || st == gitguard.BareNoGit {
		return true
	}
	if s.vmUp {
		s.warnf("Warning: git on this machine uses repositories a VM creates under another name than .git ('%s doctor' says more).", s.app)
		return true
	}
	if st == gitguard.BareOld {
		s.box("Git: repositories not named .git", gitguard.BareHint)
		out, _ := exec.CommandContext(s.ctx, "git", "--version").Output()
		s.warnf("Warning: %s is older than 2.38 and ignores that setting.", strings.TrimSpace(string(out)))
		if s.confirmUnsafe("bare-repo") {
			return true
		}
		s.warnf("Aborted. Upgrade git, then run the command above.")
		return false
	}
	q := Question{Kind: QBareRepo, Title: "Git: repositories not named .git", Detail: gitguard.BareHint, Prompt: "Run it now? It changes your global git config.", Default: true}
	if _, off := s.promptsDisabledBy(); !off && s.canAsk() {
		if s.ask(q) {
			err := exec.CommandContext(s.ctx, "git", "config", "--global", "safe.bareRepository", "explicit").Run()
			if err == nil && gitguard.BareState(s.ctx) == gitguard.BareOK {
				s.infof("Git on this machine now ignores repositories not named .git unless you name them.")
				return true
			}
			s.warnf("Warning: the setting did not take.")
		}
	} else {
		s.box(q.Title, q.Detail)
	}
	s.warnf("Warning: not set. Until it is, git on this machine can run what a VM writes.")
	if s.confirmUnsafe("bare-repo") {
		return true
	}
	s.warnf("Aborted. Run the command above, then run %s again.", s.app)
	return false
}

// box tells a boxed notice: the program decides how to show a title and a
// body together.
func (s *session) box(title, body string) {
	s.emit(Event{Level: Warning, VM: s.name, Title: title, Text: body})
}

// notePolicyChange says so when the running VM booted with other policies
// than the ones in force now. A VM with no record (booted by an agent-vm
// that kept none) is not said anything about.
func (s *session) notePolicyChange() {
	booted, err := policy.Read(s.state.Policy(s.name))
	if err != nil {
		return
	}
	now, err := s.policyNow()
	if err == nil && booted.Fingerprint() == now.Fingerprint() {
		return
	}
	s.warnf("Note: VM '%s' booted with other network or guarded-files settings than now (%s, %s, AGENT_VM_UNSAFE_OPEN_NETWORK, AGENT_VM_GUARDED_WRITES). The running VM keeps the old ones: '%s stop', then run again to apply them.",
		s.name, netguard.FileName, guard.FileName, s.app)
}

// warnDomains says, once per start, that the network policy's domains are
// experimental.
func (s *session) warnDomains() {
	if s.opts.Quiet {
		return
	}
	if pf, err := s.policyNow(); err == nil && len(pf.Network.Domains) > 0 {
		s.warnf("Warning: the 'domain' lines in %s are experimental: do not rely on them alone to confine a VM. AGENT_VM_QUIET=1 hides this.", s.state.Path(netguard.FileName))
	}
}
