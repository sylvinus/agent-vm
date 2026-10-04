package env

import (
	"os"
	"strings"

	"github.com/sylvinus/agent-vm/internal/paths"
)

// ProjectPath is a project file's path: p relative to the project dir
// unless absolute. An integrator moves the env file and the runtime script
// into a folder of its own (".mytool/env") with AGENT_VM_PROJECT_ENV and
// AGENT_VM_PROJECT_RUNTIME.
func ProjectPath(dir, p string) string {
	return paths.Abs(dir, p)
}

// ProjectEnvFile is the project dir's env file: in the project, so it
// follows a clone, a move and a delete.
func ProjectEnvFile(dir string) string {
	p := os.Getenv("AGENT_VM_PROJECT_ENV")
	if p == "" {
		p = ".agent-vm.env"
	}
	return ProjectPath(dir, p)
}

// ProjectRel is target relative to the project dir, when it is inside it,
// where the VM can write. The host must not read such a file by its path:
// the VM can make it a symlink, and the host would follow it to any file of
// the user's and hand the content over. It is read in the VM, or with
// NoFollow.
//
// Inside by its spelling, or by where it leads: the project reached through
// a link of the user's, the other spelling of a linked folder (/tmp and
// /private/tmp on macOS), another case where the file system ignores it. So
// target is resolved one component at a time, links followed one hop at a
// time, and the first step that reaches the project decides, before
// anything in it is followed. Before that point, every link is outside the
// project, where the VM cannot change it.
func ProjectRel(dir, target string) (string, bool) {
	dir = strings.TrimSuffix(dir, "/")
	if rest, ok := strings.CutPrefix(target, dir+"/"); ok {
		return rest, true
	}
	pdir, err := paths.Real(dir)
	if err != nil || pdir == "" {
		return "", false
	}
	// From the root: "", or the drive on Windows ("C:").
	root := paths.Root(target)
	cur, hops := strings.TrimSuffix(root, "/"), 0
	rest := strings.TrimPrefix(target, root) + "/"
	for rest != "" {
		var comp string
		comp, rest, _ = strings.Cut(rest, "/")
		switch comp {
		case "", ".":
			continue
		case "..":
			if i := strings.LastIndexByte(cur, '/'); i >= 0 {
				cur = cur[:i]
			}
			continue
		}
		next := cur + "/" + comp
		if inside, ok := paths.In(next, pdir); ok {
			r := strings.TrimSuffix(rest, "/")
			if inside != "." {
				r = inside + "/" + r
			}
			return strings.TrimSuffix(strings.TrimPrefix(r, "/"), "/"), true
		}
		if fi, err := os.Lstat(next); err == nil && fi.Mode()&os.ModeSymlink != 0 {
			if hops++; hops > 40 {
				return "", false
			}
			t, err := os.Readlink(next)
			if err != nil {
				return "", false
			}
			if t = paths.Host(t); paths.IsAbs(t) {
				r := paths.Root(t)
				cur, t = strings.TrimSuffix(r, "/"), t[len(r):]
			}
			rest = strings.TrimPrefix(t, "/") + "/" + rest
			continue
		}
		cur = next
	}
	return "", false
}

// InProject reports whether target is inside the project dir (see
// ProjectRel).
func InProject(dir, target string) bool {
	_, ok := ProjectRel(dir, target)
	return ok
}

// StripCR is content with a CR ending a line removed, each line ending with
// a newline: a CRLF file (Windows) would put a CR at the end of every value
// in the guest.
func StripCR(content string) string {
	var b strings.Builder
	for _, l := range records(content) {
		b.WriteString(strings.TrimSuffix(l, "\r") + "\n")
	}
	return b.String()
}

// Payload is what is pushed into the VM of the project dir: the shared file
// first, the project's next, so the project's value wins (the guest sources
// it). The project's file is only in here when AGENT_VM_PROJECT_ENV puts it
// outside the project; inside, the VM reads it itself (see ProjectRel).
func Payload(shared, dir string) string {
	var b strings.Builder
	if s, ok := readRegular(shared); ok {
		// The newline keeps a shared file without one from gluing its last
		// line to the project's first.
		b.WriteString(StripCR(s) + "\n")
	}
	if pf := ProjectEnvFile(dir); !InProject(dir, pf) {
		if p, ok := readRegular(pf); ok {
			b.WriteString(StripCR(p))
		}
	}
	return b.String()
}

// readRegular is the content of p, a regular file once links are followed:
// one of the user's own, outside the project.
func readRegular(p string) (string, bool) {
	if fi, err := os.Stat(p); err != nil || !fi.Mode().IsRegular() {
		return "", false
	}
	b, err := os.ReadFile(p)
	return string(b), err == nil
}
