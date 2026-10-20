package state

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// 0.3.0 kept its VMs in lima/<name> and a marker file per VM and fact in the
// state folder, named as 0.2 named them. MigrateLayout moves them to
// vms/<name>; 0.2's own migration still names its markers so.
const (
	legacyVersionOf    = ".agent-vm-version-"     // the base's build time it was cloned from
	legacyBuiltByOf    = ".agent-vm-built-by-"    // the agent-vm version that built that base
	legacySSHFSOf      = ".agent-vm-sshfs-"       // 0.1 migration done
	legacyTermOf       = ".agent-vm-term-"        // the $TERM whose terminfo it has
	legacyFileMountsOf = ".agent-vm-file-mounts-" // single files of ~/.agent-vm/volumes
	legacyMountsOf     = ".agent-vm-mounts-"      // 0.2's record of its shares
	legacyCacheOf      = ".agent-vm-sshfs-cache-" // 0.2's record of sshfs's cache
	legacyScratchOf    = ".agent-vm-scratch-"     // a --scratch run, with its pid
	legacyPolicyOf     = ".agent-vm-policy-"      // fingerprint of the policies it booted with
	legacyBaseVersion  = ".agent-vm-base-version"
	legacyBaseBuiltBy  = ".agent-vm-base-built-by"
)

// legacyKinds, longest first: sshfs-cache- is also sshfs- followed by a name.
var legacyKinds = []string{
	legacyCacheOf, legacyFileMountsOf, legacyVersionOf, legacyBuiltByOf, legacyScratchOf,
	legacyMountsOf, legacyPolicyOf, legacySSHFSOf, legacyTermOf,
}

// LegacyRename moves the 0.3.0-layout markers and staged files of the VM
// from to its new name to: for 0.2's migration, which runs before
// MigrateLayout. Its shares are set again before it next boots, from where
// they now are.
func (d Dir) LegacyRename(from, to string) error {
	var last error
	for _, kind := range legacyKinds {
		if err := os.Rename(d.Path(kind+from), d.Path(kind+to)); err != nil && !os.IsNotExist(err) {
			last = err
		}
	}
	if err := os.Rename(d.Path(filepath.Join("file-mounts", from)), d.Path(filepath.Join("file-mounts", to))); err != nil && !os.IsNotExist(err) {
		last = err
	}
	return last
}

// LayoutOps are what MigrateLayout asks of the caller.
type LayoutOps struct {
	// Home is the Lima home the VMs are in: lima/ of the state folder, or
	// where AGENT_VM_LIMA_HOME put it.
	Home string
	// Template is the base template's VM name.
	Template string
	// Running reports whether the VM name, still in lima/, runs. Its
	// hostagent holds sockets in its folder: it cannot move.
	Running func(name string) bool
	// Stop stops the VM name in lima/.
	Stop func(name string) error
	// Ask asks whether to stop the running VMs, which cuts their sessions.
	// Nil when there is no one to ask: they are left for next time.
	Ask func(running []string) bool
	// Log gets what was done and what was not.
	Log io.Writer
}

// LegacyVMs are the VMs still in the Lima home home, those with a lima.yaml.
func (d Dir) LegacyVMs(home string) []string {
	ents, _ := os.ReadDir(home)
	var out []string
	for _, e := range ents {
		if !e.IsDir() || strings.HasPrefix(e.Name(), ".") || strings.HasPrefix(e.Name(), "_") {
			continue
		}
		if _, err := os.Stat(filepath.Join(home, e.Name(), "lima.yaml")); err == nil {
			out = append(out, e.Name())
		}
	}
	return out
}

// legacyMarkers are the markers in the state folder, by VM name, each a
// kind and its file. Those of the base template are under template.
func (d Dir) legacyMarkers(template string, known func(string) bool) map[string]map[string]string {
	ents, _ := os.ReadDir(string(d))
	out := map[string]map[string]string{}
	add := func(vm, kind, file string) {
		if out[vm] == nil {
			out[vm] = map[string]string{}
		}
		out[vm][kind] = file
	}
	for _, e := range ents {
		n := e.Name()
		switch {
		case n == legacyBaseVersion || n == legacyBaseBuiltBy:
			add(template, n, n)
			continue
		case !strings.HasPrefix(n, ".agent-vm-") || e.IsDir():
			continue
		}
		for _, k := range legacyKinds {
			vm, ok := strings.CutPrefix(n, k)
			if !ok || vm == "" {
				continue
			}
			// sshfs-cache-x is the cache record of x, unless a VM is named
			// cache-x: then it is the sshfs record of that one.
			if k == legacyCacheOf && known("cache-"+vm) && !known(vm) {
				k, vm = legacySSHFSOf, "cache-"+vm
			}
			add(vm, k, n)
			break
		}
	}
	return out
}

// PendingLayout reports whether MigrateLayout has anything to move: VMs in
// the Lima home home, or markers of the old layout.
func (d Dir) PendingLayout(home string) bool {
	if len(d.LegacyVMs(home)) > 0 {
		return true
	}
	ents, _ := os.ReadDir(string(d))
	for _, e := range ents {
		n := e.Name()
		if n == legacyBaseVersion || n == legacyBaseBuiltBy {
			return true
		}
		for _, k := range legacyKinds {
			if strings.HasPrefix(n, k) && !e.IsDir() {
				return true
			}
		}
	}
	_, err := os.Stat(d.Path(FileMountsDir))
	return err == nil
}

// MigrateLayout moves 0.3.0's VMs to vms/<name>/lima, builds each one's
// metadata.json from its markers, moves its staged files, and removes the
// markers. A VM still running cannot move: it is asked to stop when Ask
// says so, else left, with its markers, for next time. The folders are
// renamed: a copy would break the disk blocks shared with the base. Run
// under the lock of the migration; interrupted, it picks up where it
// stopped.
func (d Dir) MigrateLayout(ops LayoutOps) error {
	logf := func(format string, a ...any) {
		if ops.Log != nil {
			fmt.Fprintf(ops.Log, format+"\n", a...)
		}
	}
	pending := d.LegacyVMs(ops.Home)
	var running []string
	for _, name := range pending {
		if ops.Running != nil && ops.Running(name) {
			running = append(running, name)
		}
	}
	left := map[string]bool{}
	if len(running) > 0 {
		if ops.Ask != nil && ops.Ask(running) {
			for _, name := range running {
				if err := ops.Stop(name); err != nil {
					logf("Could not stop %s: %v. It stays where it is, for next time.", name, err)
					left[name] = true
				}
			}
		} else {
			for _, name := range running {
				logf("%s is running and stays where it is: stop it, or run agent-vm in a terminal to be asked. It moves next time.", name)
				left[name] = true
			}
		}
	}
	var failed []string
	for _, name := range pending {
		if left[name] {
			continue
		}
		src, dst := filepath.Join(ops.Home, name), d.Lima(name)
		if _, err := os.Lstat(dst); err == nil {
			logf("Error: %s exists already: the VM in %s is not moved. Remove one of them.", dst, src)
			failed = append(failed, name)
			left[name] = true
			continue
		}
		if err := os.MkdirAll(d.VM(name), 0o755); err != nil {
			return err
		}
		if err := os.Rename(src, dst); err != nil {
			var le *os.LinkError
			if errors.As(err, &le) && errors.Is(le.Err, syscall.EXDEV) {
				return fmt.Errorf("cannot move %s to %s: they are on different file systems (the Lima home %s and the state folder must be on one), and a copy would not share the disk blocks of the base template", src, dst, ops.Home)
			}
			return fmt.Errorf("moving %s to %s: %w", src, dst, err)
		}
		logf("Moved %s.", name)
	}
	// The markers: a VM in vms/ gets its metadata from them, one that is
	// nowhere loses them. The VMs left behind keep theirs.
	known := func(n string) bool { return d.HasLima(n) || slicesContains(pending, n) }
	for vm, files := range d.legacyMarkers(ops.Template, known) {
		if left[vm] {
			continue
		}
		if !d.HasLima(vm) {
			for _, f := range files {
				os.Remove(d.Path(f))
			}
			continue
		}
		if err := d.migrateMarkers(vm, ops.Template, files); err != nil {
			logf("Error: could not write the metadata of %s: %v", vm, err)
			failed = append(failed, vm)
			continue
		}
		for _, f := range files {
			if err := os.Remove(d.Path(f)); err != nil && !os.IsNotExist(err) {
				logf("Warning: could not remove %s: %v", d.Path(f), err)
			}
		}
	}
	// Staged files: of the VMs there are, the rest is gone with their VM.
	if ents, err := os.ReadDir(d.Path(FileMountsDir)); err == nil {
		for _, e := range ents {
			src := filepath.Join(d.Path(FileMountsDir), e.Name())
			if left[e.Name()] || slicesContains(failed, e.Name()) {
				continue
			}
			if !d.HasLima(e.Name()) {
				os.RemoveAll(src)
				continue
			}
			if _, err := os.Lstat(d.FileMounts(e.Name())); err == nil {
				os.RemoveAll(src)
			} else if err := os.Rename(src, d.FileMounts(e.Name())); err != nil {
				return fmt.Errorf("moving %s to %s: %w", src, d.FileMounts(e.Name()), err)
			}
		}
		os.Remove(d.Path(FileMountsDir)) // when empty
	}
	if len(failed) > 0 {
		return fmt.Errorf("could not move: %s", strings.Join(failed, ", "))
	}
	return nil
}

func slicesContains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// migrateMarkers writes vm's metadata from its markers.
func (d Dir) migrateMarkers(vm, template string, files map[string]string) error {
	read := func(kind string) (string, bool) {
		f, ok := files[kind]
		if !ok {
			return "", false
		}
		b, err := os.ReadFile(d.Path(f))
		return strings.TrimSpace(string(b)), err == nil
	}
	var m Metadata
	var base Base
	haveBase := false
	if v, ok := read(legacyBaseVersion); ok {
		haveBase = true
		base.Name = template
		base.Built = parseBuilt(v)
		if by, ok := read(legacyBaseBuiltBy); ok && builtByRe.MatchString(by) {
			base.BuiltBy = by
		}
	}
	if v, ok := read(legacyVersionOf); ok {
		haveBase = true
		base.Name = template
		base.Built = parseBuilt(v)
	}
	if by, ok := read(legacyBuiltByOf); ok && builtByRe.MatchString(by) {
		haveBase = true
		base.Name = template
		base.BuiltBy = by
	}
	if _, ok := read(legacySSHFSOf); ok && base.BuiltBy == "" && vm != template {
		haveBase = true
		base.Name = template
		base.BuiltBy = "0.1.0"
	}
	if haveBase {
		m.Base = &base
	}
	if t, ok := read(legacyTermOf); ok {
		m.Term = t
	}
	if p, ok := read(legacyScratchOf); ok {
		// A record without a process number is kept as one: the run it
		// belonged to is not known.
		if n, err := strconv.Atoi(p); err == nil && n > 0 {
			m.ScratchPID = n
		} else {
			m.ScratchPID = -1
		}
	}
	if f, ok := read(legacyFileMountsOf); ok {
		for _, line := range strings.Split(f, "\n") {
			if line != "" {
				m.FileMounts = append(m.FileMounts, line)
			}
		}
	}
	return d.UpdateMeta(vm, func(cur *Metadata) { *cur = m })
}

// parseBuilt is a build time in Unix seconds. A record that is there but
// unreadable still says the base was built: 1.
func parseBuilt(s string) int64 {
	if n, err := strconv.ParseInt(s, 10, 64); err == nil && n > 0 && strings.Trim(s, "0123456789") == "" {
		return n
	}
	return 1
}
