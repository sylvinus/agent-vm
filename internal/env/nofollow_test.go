//go:build !windows

package env

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"

	"github.com/sylvinus/agent-vm/internal/bashref"
)

func code(err error) int {
	switch {
	case err == nil:
		return 0
	case errors.Is(err, ErrNoFile):
		return 1
	case errors.Is(err, ErrUnsafe):
		return 3
	}
	return 2
}

// layout makes a project with every kind of thing NoFollow meets, and a
// secret outside it.
func layout(t *testing.T) (top, secret string) {
	t.Helper()
	root := t.TempDir()
	top = filepath.Join(root, "proj")
	secret = filepath.Join(root, "secret")
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(top, "d/e"), 0o755))
	must(os.WriteFile(secret, []byte("SECRET\n"), 0o600))
	must(os.MkdirAll(filepath.Join(root, "outdir"), 0o755))
	must(os.WriteFile(filepath.Join(top, "plain"), []byte("A=1\n"), 0o644))
	must(os.WriteFile(filepath.Join(top, "d/e/f"), []byte("deep\n"), 0o644))
	must(os.Symlink(secret, filepath.Join(top, "link")))
	must(os.Symlink(filepath.Join(root, "outdir"), filepath.Join(top, "dirlink")))
	must(os.Symlink("plain", filepath.Join(top, "innerlink")))
	must(syscall.Mkfifo(filepath.Join(top, "fifo"), 0o644))
	return top, secret
}

var rels = []string{"plain", "d/e/f", "missing", "new/dir/file", "link", "dirlink/x", "innerlink", "fifo", "d", "d/e", "../secret", "", "./plain", "d//e/./f"}

func TestNoFollowBash(t *testing.T) {
	if _, err := os.Stat("/usr/bin/perl"); err != nil {
		t.Skip("no perl for the bash reference")
	}
	for _, op := range []string{"read", "write", "mkdir", "touch"} {
		for _, rel := range rels {
			gtop, gsecret := layout(t)
			btop, bsecret := layout(t)
			var got []byte
			var err error
			switch op {
			case "read":
				got, err = ReadIn(gtop, rel)
			case "write":
				err = WriteIn(gtop, rel, []byte("NEW\n"))
			case "mkdir":
				err = MkdirIn(gtop, rel)
			case "touch":
				err = TouchIn(gtop, rel)
			}
			r := bashref.Script(t, "", nil, `printf 'NEW\n' | _agent_vm_nofollow "$@"`, op, btop, rel)
			if code(err) != r.Code {
				t.Errorf("%s %q: go %d (%v), bash %d %s", op, rel, code(err), err, r.Code, r.Stderr)
			}
			if op == "read" && err == nil && string(got) != r.Stdout {
				t.Errorf("read %q: go %q, bash %q", rel, got, r.Stdout)
			}
			if b, _ := os.ReadFile(gsecret); string(b) != "SECRET\n" {
				t.Errorf("%s %q changed the secret outside the project", op, rel)
			}
			if b, _ := os.ReadFile(bsecret); string(b) != "SECRET\n" {
				t.Errorf("bash %s %q changed the secret", op, rel)
			}
			if _, err := os.Stat(filepath.Join(filepath.Dir(gtop), "outdir", "x")); err == nil {
				t.Errorf("%s %q wrote through a linked folder", op, rel)
			}
			if op == "write" && err == nil {
				if b, _ := os.ReadFile(filepath.Join(gtop, rel)); string(b) != "NEW\n" {
					t.Errorf("write %q: %q", rel, b)
				}
				fi, _ := os.Lstat(filepath.Join(gtop, rel))
				if fi.Mode().Perm() != 0o600 || !fi.Mode().IsRegular() {
					t.Errorf("write %q: mode %v", rel, fi.Mode())
				}
			}
		}
	}
}

func TestProjectRelBash(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "proj")
	os.MkdirAll(filepath.Join(proj, "sub"), 0o755)
	os.MkdirAll(filepath.Join(root, "else"), 0o755)
	os.Symlink(proj, filepath.Join(root, "projlink"))
	os.Symlink(filepath.Join(root, "else"), filepath.Join(root, "elselink"))
	os.Symlink(filepath.Join(proj, "sub"), filepath.Join(root, "else", "into"))
	os.Symlink("../proj/sub", filepath.Join(root, "rellink"))
	loop := filepath.Join(root, "loop")
	os.Symlink(loop, loop)
	for _, target := range []string{
		proj + "/.agent-vm.env", proj + "/sub/x", root + "/projlink/x", root + "/elselink/x", root + "/else/into/y",
		root + "/rellink/z", root + "/proj", root + "/other/x", loop + "/x", "/etc/passwd", proj + "/../proj/x",
		root + "/elselink/../proj/x",
	} {
		r := bashref.Run(t, "", nil, "_agent_vm_project_rel", proj, target)
		rel, ok := ProjectRel(proj, target)
		want := r.Stdout
		if len(want) > 0 {
			want = want[:len(want)-1]
		}
		if ok != (r.Code == 0) || (ok && rel != want) {
			t.Errorf("ProjectRel(%q) = %q %v, bash %q %d", target, rel, ok, want, r.Code)
		}
	}
}

func TestPayloadBash(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "proj")
	os.MkdirAll(proj, 0o755)
	st := filepath.Join(root, "state")
	os.MkdirAll(st, 0o755)
	for i, c := range []struct{ shared, projEnv, projFile string }{
		{"A=1\r\nB=2", "", ""},
		{"A=1\n", "../outside.env", "P=1\r\n"},
		{"", ".agent-vm.env", "P=1\n"},
		{"A=1", "", ""},
	} {
		os.Remove(filepath.Join(st, "env"))
		if c.shared != "" {
			os.WriteFile(filepath.Join(st, "env"), []byte(c.shared), 0o600)
		}
		envs := []string{"AGENT_VM_STATE_DIR=" + st}
		if c.projEnv != "" {
			envs = append(envs, "AGENT_VM_PROJECT_ENV="+c.projEnv)
			t.Setenv("AGENT_VM_PROJECT_ENV", c.projEnv)
			os.WriteFile(ProjectPath(proj, c.projEnv), []byte(c.projFile), 0o600)
		} else {
			t.Setenv("AGENT_VM_PROJECT_ENV", "")
		}
		r := bashref.Run(t, "", envs, "_agent_vm_env_payload", proj)
		if got := Payload(filepath.Join(st, "env"), proj); got != r.Stdout {
			t.Errorf("case %s: Payload = %q, bash %q", strconv.Itoa(i), got, r.Stdout)
		}
	}
}
