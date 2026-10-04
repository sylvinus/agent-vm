package cli

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"time"

	limaversion "github.com/lima-vm/lima/v2/pkg/version"

	"github.com/sylvinus/agent-vm/internal/env"
	"github.com/sylvinus/agent-vm/internal/gitguard"
	"github.com/sylvinus/agent-vm/internal/guard"
	"github.com/sylvinus/agent-vm/internal/host"
	"github.com/sylvinus/agent-vm/internal/mounts"
	"github.com/sylvinus/agent-vm/internal/netguard"
	"github.com/sylvinus/agent-vm/internal/runscript"
	"github.com/sylvinus/agent-vm/internal/state"
	"github.com/sylvinus/agent-vm/internal/version"
	"github.com/sylvinus/agent-vm/internal/vm"
	"github.com/sylvinus/agent-vm/internal/vmname"
)

// doctor counts what it finds.
type doctor struct {
	e          *app
	warn, fail int
}

// line prints one finding: level ok, warn, fail or info, then hints.
func (d *doctor) line(level, msg string, hints ...string) {
	w := d.e.io.Stdout
	switch level {
	case "ok":
		fmt.Fprintf(w, "  ok    %s\n", msg)
	case "warn":
		fmt.Fprintf(w, "  warn  %s\n", msg)
		d.warn++
	case "fail":
		fmt.Fprintf(w, "  FAIL  %s\n", msg)
		d.fail++
	default:
		fmt.Fprintf(w, "  -     %s\n", msg)
	}
	for _, h := range hints {
		fmt.Fprintf(w, "        %s\n", h)
	}
}

func (d *doctor) section(name string) { fmt.Fprintf(d.e.io.Stdout, "\n%s\n", name) }

// `doctor`: checks the host, Lima, the base template and the current
// directory, and says what to do about each problem. Read-only: it never
// creates, starts or stops a VM, so it is safe to run first and to paste
// into an issue (names, no secret values). 1 when a check failed.
func (e *app) doctorCmd(ctx context.Context, args []string) int {
	if len(args) > 0 {
		fmt.Fprintln(e.io.Stderr, "Usage: agent-vm doctor")
		return 2
	}
	d := &doctor{e: e}
	w := e.io.Stdout
	fmt.Fprintln(w, "agent-vm doctor")
	d.section("agent-vm")
	exe, _ := os.Executable()
	d.line("info", fmt.Sprintf("version %s, from %s", version.Version, exe))

	d.section("Host")
	d.line("info", runtime.GOOS+" "+runtime.GOARCH)
	cpus, mem := host.CPUs(), host.MemGiB()
	if cpus > 0 && mem > 0 {
		div := os.Getenv("AGENT_VM_HOST_SHARE")
		if div == "" {
			div = "2"
		}
		var discard bytes.Buffer
		d.line("info", fmt.Sprintf("%d CPUs, %d GiB RAM; a VM gets at most %d CPUs and %d GiB (AGENT_VM_HOST_SHARE=%s)",
			cpus, mem, host.Cap("cpus", cpus, &discard), host.Cap("memory", mem, &discard), div))
	} else {
		d.line("warn", "could not read the host's CPU or RAM: --cpus and --memory are not clamped")
	}
	dir := LimaHome(e.state)
	if _, err := os.Stat(dir); err != nil {
		dir, _ = os.UserHomeDir()
	}
	switch free, ok := host.FreeGiB(dir); {
	case !ok:
		d.line("warn", "could not read the free disk space")
	case free < 10:
		d.line("warn", fmt.Sprintf("%d GiB free for the VMs", free), "A default VM disk is 10 GiB (sparse).")
	default:
		d.line("ok", fmt.Sprintf("%d GiB free for the VMs", free))
	}

	d.section("Lima")
	d.line("info", fmt.Sprintf("Lima %s, built in; its VMs in %s", strings.TrimPrefix(limaversion.Version, "v"), LimaHome(e.state)))
	for _, f := range vm.LimaOverrides(LimaHome(e.state)) {
		d.line("fail", f+" adds to every VM's config: agent-vm makes and starts no VM while it is there", "Move it out of the way.")
	}
	protects := !writableGitOptOut(false)
	if protects {
		d.line("ok", "every .git is read-only for the VMs (sshfs.readonlyNames)")
	} else {
		d.line("warn", "AGENT_VM_UNSAFE_WRITABLE_GIT=1: the VMs can write .git, and git on this machine runs what .git/config and hooks name",
			"Unset it to keep .git read-only.")
	}
	var prereqs bytes.Buffer
	switch runtime.GOOS {
	case "linux":
		if host.LinuxPrereqs(&prereqs) {
			d.line("ok", "QEMU and /dev/kvm are usable")
		} else {
			d.line("fail", "QEMU or KVM is not usable", strings.Split(strings.TrimSuffix(prereqs.String(), "\n"), "\n")...)
		}
	case "windows":
		if host.WindowsPrereqs(&prereqs, &prereqs) {
			d.line("ok", "QEMU is installed")
		} else {
			d.line("fail", "QEMU is not usable", strings.Split(strings.TrimSuffix(prereqs.String(), "\n"), "\n")...)
		}
		d.line("info", "QEMU also needs the 'Windows Hypervisor Platform' feature, which only an administrator can check or turn on",
			"Without it, VMs fail to start with a WHPX error. An administrator runs, once, then reboots:", host.WHPXOn)
	}

	// A bare repository is not named .git, so the names do not cover one the
	// VM plants in a project.
	if st := gitguard.BareState(ctx); st != gitguard.BareNoGit {
		d.section("Git on this machine")
		switch st {
		case gitguard.BareOK:
			d.line("ok", "safe.bareRepository = explicit")
		case gitguard.BareOld:
			out, _ := exec.CommandContext(ctx, "git", "--version").Output()
			d.line("warn", strings.TrimSpace(string(out))+" is older than 2.38: it would use a repository a VM creates under another name than .git, and run what its config names",
				"Upgrade git, then: git config --global safe.bareRepository explicit")
		default:
			d.line("warn", "safe.bareRepository is not 'explicit': git would use a repository a VM creates under another name than .git, and run what its config names",
				"git config --global safe.bareRepository explicit")
		}
	}

	d.section("Base template")
	b, berr := e.readOnlyBackend()
	if old := oldLimaHome(); !e.migrated() {
		if vms, _ := vm.FindOld(old, vmname.OldPrefix); len(vms) > 0 {
			d.line("info", fmt.Sprintf("%d VM(s) of agent-vm 0.2 in %s, not moved yet", len(vms), old),
				"The next agent-vm command that uses VMs ('agent-vm list', for one) offers to move them.")
		}
	}
	getVM := func(name string) (*vm.Instance, error) {
		if berr != nil {
			return nil, berr
		}
		inst, err := b.Get(ctx, name)
		if errors.Is(err, vm.ErrNotFound) {
			return nil, nil
		}
		return inst, err
	}
	base, err := getVM(vmname.Template)
	_, merr := os.Stat(e.state.Path(state.BaseVersion))
	switch {
	case err != nil:
		d.line("warn", "could not query Lima")
	case base != nil && merr == nil:
		if built, perr := strconv.ParseInt(e.state.Read(e.state.Path(state.BaseVersion)), 10, 64); perr == nil {
			d.line("ok", fmt.Sprintf("%s is ready, built %s", vmname.Template, time.Unix(built, 0).Format("2006-01-02")))
			if time.Since(time.Unix(built, 0)) > 90*24*time.Hour {
				d.line("warn", "the base template is over 90 days old", "Its agents and packages are as old. 'agent-vm setup' rebuilds it.")
			}
		} else {
			d.line("ok", vmname.Template+" is ready")
		}
		if _, err := os.Stat(e.state.Path(state.BaseBuiltBy)); err != nil {
			d.line("warn", "the base template was built by agent-vm 0.1.0, without what the shares that keep .git read-only need",
				"'agent-vm setup' rebuilds it, then '--reset' the VMs made from it.")
		}
	case base != nil:
		d.line("fail", vmname.Template+" exists but its setup did not complete", "Run 'agent-vm setup' again.")
	default:
		d.line("fail", "no base template yet", "Run 'agent-vm setup'.")
	}

	d.section(fmt.Sprintf("Settings (%s)", e.state))
	if content, err := os.ReadFile(e.state.Path("env")); err == nil {
		keys := len(unique(env.Names(string(content))))
		fi, serr := os.Stat(e.state.Path("env"))
		switch {
		case runtime.GOOS == "windows":
			// Permission bits mean little there: the file's ACL protects it.
			d.line("info", fmt.Sprintf("env: %d key(s)", keys))
		case serr == nil && fi.Mode().Perm()&0o077 == 0:
			d.line("ok", fmt.Sprintf("env: %d key(s), private to you (mode %o)", keys, fi.Mode().Perm()))
		case serr == nil:
			d.line("warn", fmt.Sprintf("env is readable by other users on this machine (mode %o)", fi.Mode().Perm()), fmt.Sprintf("chmod 600 '%s'", e.state.Path("env")))
		default:
			d.line("warn", "env permissions could not be checked", fmt.Sprintf("chmod 600 '%s'", e.state.Path("env")))
		}
	} else {
		d.line("info", "env: none (agent-vm env set KEY VALUE)")
	}
	for _, f := range []string{"volumes", "setup.sh", "runtime.sh", guard.FileName} {
		if _, err := os.Stat(e.state.Path(f)); err == nil {
			d.line("info", f+": present")
		}
	}
	switch pol, err := netguard.Load(string(e.state)); {
	case err != nil:
		d.line("fail", err.Error(), "No VM starts until it is fixed.")
	case pol.Open:
		d.line("warn", "network isolation off (AGENT_VM_UNSAFE_OPEN_NETWORK=1): the VMs reach this machine and its networks")
	case len(pol.Allow) > 0 || len(pol.Domains) > 0:
		d.line("info", netguard.FileName+": present")
	}

	wd, _ := vmname.AbsDir("")
	d.section(fmt.Sprintf("This directory (%s)", wd))
	d.directory(ctx, wd, protects, getVM)

	d.section("All VMs")
	if vms, err := e.agentVMs(ctx); err == nil {
		n, c, m := 0, 0, 0
		for _, v := range vms {
			if v.Status == vm.Running {
				n, c, m = n+1, c+v.CPUs, m+int(v.Memory>>30)
			}
		}
		switch {
		case n == 0:
			d.line("info", "none running")
		case mem > 0 && m > mem:
			d.line("warn", fmt.Sprintf("%d running, %d CPUs and %d GiB in total: more memory than the host has", n, c, m),
				"'agent-vm list' lists them; 'agent-vm stop <name>' frees one.")
		default:
			d.line("info", fmt.Sprintf("%d running, %d CPUs and %d GiB in total", n, c, m))
		}
	}
	for _, left := range e.scratchLeftovers() {
		d.line("warn", "scratch VM "+left+" was left by a run that did not finish", "The next --scratch run deletes it, or: agent-vm rm "+left)
	}

	fmt.Fprintln(w)
	if d.fail > 0 {
		fmt.Fprintf(w, "%d problem(s), %d warning(s).\n", d.fail, d.warn)
		return 1
	}
	fmt.Fprintf(w, "No problems found, %d warning(s).\n", d.warn)
	return 0
}

func unique(s []string) []string {
	var out []string
	for _, x := range s {
		if !slices.Contains(out, x) {
			out = append(out, x)
		}
	}
	return out
}

// directory checks the project dir: its path, its VM and what protects it,
// the hooks and config git runs from its shares, its runtime and env files.
func (d *doctor) directory(ctx context.Context, dir string, protects bool, getVM func(string) (*vm.Instance, error)) {
	e := d.e
	if why, bad := mounts.Unmountable(dir); bad {
		d.line("fail", "the path "+why, "agent-vm refuses to mount it. Rename the directory.")
	}
	if why, bad := mounts.UnsafeProject(dir, e.refs()); bad {
		d.line("fail", "this directory "+why, "agent-vm refuses to share it with a VM. Run it from a project directory.")
	}
	scan := e.scan(ctx, dir)
	names := scan.Names()
	name := vmname.Name(dir)
	inst, err := getVM(name)
	switch {
	case err != nil:
		d.line("warn", "could not query Lima")
	case inst == nil:
		d.line("info", name+" will be created on the first agent-vm command here")
	case inst.ConfigErr != nil:
		d.line("fail", "Lima cannot read the config of "+name, inst.ConfigErr.Error(), "'agent-vm --reset <command>' re-clones it.")
	default:
		if e.staleState(name) == "1" {
			d.line("warn", name+" was cloned from an older base template", "'agent-vm --reset <command>' re-clones it.")
		} else {
			d.line("ok", name+" exists")
		}
		confined := vm.Confined(inst)
		switch {
		case inst.Status == vm.Running && confined == nil:
			d.line("ok", "running; the project share is enforced on the host (--readonly works)")
		case inst.Status == vm.Running:
			d.line("warn", "running with a share the host does not confine: "+confined.Error(),
				"The next start (after 'agent-vm stop') sets its shares back.")
		default:
			d.line("info", "stopped")
		}
		protected := len(inst.Mounts) > 0 && unprotected(inst, nil) == ""
		current := unprotected(inst, names) == ""
		switch {
		case protected && !current:
			d.line("warn", "its shares keep .git read-only, but not all of "+strings.Join(names, ", "),
				"The next start (after 'agent-vm stop' if it runs) fixes that.")
		case protected:
			d.line("ok", "its shares keep every .git read-only")
		case !protects:
			d.line("warn", "its shares leave .git writable (AGENT_VM_UNSAFE_WRITABLE_GIT=1)")
		default:
			d.line("warn", "its shares leave .git writable", "The next start (after 'agent-vm stop' if it runs) fixes that.")
		}
	}
	for _, h := range scan.Hooks {
		rel, inRepo, _ := strings.Cut(h, "\t")
		if rel == "" {
			continue
		}
		what := "git runs hooks from " + rel + " (core.hooksPath)"
		switch {
		case rel == ".":
			what = "git runs hooks from the project directory itself (core.hooksPath)"
		case inRepo == ".":
			what = "git runs hooks from " + rel + ", which no read-only name covers (core.hooksPath)"
		}
		hn, ok := gitguard.HooksName(inRepo)
		current := false
		if inst != nil {
			current = unprotected(inst, names) == ""
		}
		switch {
		case !ok:
			d.line("warn", what+", which the VM can write",
				"agent-vm can only keep a folder inside a share read-only, by a name without quotes or backslashes: point core.hooksPath to one.")
		case !protects:
			d.line("warn", what+", which the VM can write", "agent-vm keeps it read-only when it keeps .git read-only (see above).")
		case inst == nil:
			d.line("info", fmt.Sprintf("%s: every '%s' in the project will be read-only for the VM", what, hn))
		case current:
			d.line("ok", fmt.Sprintf("%s: every '%s' in the project is read-only for the VM", what, hn))
		default:
			d.line("warn", what+", which the VM can still write",
				fmt.Sprintf("The next start (after 'agent-vm stop' if it runs) makes every '%s' in the project read-only.", hn))
		}
	}
	if risks := scan.Risks(names); len(risks) > 0 {
		d.line("warn", "git on this machine uses these, and the VM can write them:",
			append(risks, "Move them out of the shared folders, or have them name commands outside them.")...)
	}
	rt := runscript.ProjectPath(dir)
	if rel, ok := env.ProjectRel(dir, rt); ok {
		// Not by its path: the VM can make it a symlink.
		if b, err := env.ReadIn(dir, rel); err == nil {
			d.line("info", fmt.Sprintf("project runtime: %s (%s)", rt, runscript.Interpreter(string(b))))
		}
	} else if b, err := os.ReadFile(rt); err == nil {
		d.line("info", fmt.Sprintf("project runtime: %s (%s)", rt, runscript.Interpreter(string(b))))
	}
	pe := env.ProjectEnvFile(dir)
	if _, err := os.Stat(pe); err == nil {
		var warn bytes.Buffer
		saved := e.io.Stderr
		e.io.Stderr = &warn
		e.warnUnignored(ctx, pe)
		e.io.Stderr = saved
		if warn.Len() > 0 {
			var hints []string
			for _, l := range strings.Split(strings.TrimSuffix(warn.String(), "\n"), "\n") {
				hints = append(hints, strings.TrimLeft(l, " "))
			}
			d.line("warn", "project env: "+pe, hints...)
		} else {
			d.line("ok", "project env: "+pe)
		}
	}
}
