package cli

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/bashref"
	"github.com/sylvinus/agent-vm/internal/state"
)

// Each sequence of env and project-env commands gives the same output,
// status and files as 0.2, run each in its own project and state folder.
func TestEnvBash(t *testing.T) {
	type step struct {
		args  []string
		stdin string
	}
	seqs := [][]step{
		{{[]string{"env", "list"}, ""}, {[]string{"env", "get", "A"}, ""}, {[]string{"env", "has", "A"}, ""}},
		{{[]string{"env", "set", "A", "O'Brien"}, ""}, {[]string{"env", "get", "A"}, ""}, {[]string{"env"}, ""}},
		{{[]string{"env", "set", "A"}, "piped\n"}, {[]string{"env", "set", "B"}, "multi\nline\n"}, {[]string{"env", "get", "B"}, ""},
			{[]string{"env", "set", "A", "again"}, ""}, {[]string{"env", "list"}, ""}, {[]string{"env", "unset", "A"}, ""}, {[]string{"env", "list"}, ""}},
		{{[]string{"env", "set", "A"}, ""}, {[]string{"env", "set", "1A", "x"}, ""}, {[]string{"env", "set"}, ""}, {[]string{"env", "set", "A", "b", "c"}, ""},
			{[]string{"env", "frob"}, ""}, {[]string{"env", "get", "A", "B"}, ""}, {[]string{"env", "list", "x"}, ""}, {[]string{"env", "unset", "NOPE"}, ""}},
		{{[]string{"project-env", "set", "K", "v"}, ""}, {[]string{"project-env", "get", "K"}, ""}, {[]string{"project-env", "list"}, ""}},
	}
	for i, seq := range seqs {
		gproj, bproj := t.TempDir(), t.TempDir()
		gst, bst := t.TempDir(), t.TempDir()
		bfiles := []string{filepath.Join(bst, "env"), filepath.Join(bproj, ".agent-vm.env")}
		var want bashref.Result
		for _, s := range seq {
			te := newTestEnv(t, nil)
			te.state = state.Dir(gst)
			te.io.Stdin = strings.NewReader(s.stdin)
			t.Chdir(gproj)
			t.Setenv("PWD", gproj)
			code := te.main(context.Background(), s.args)
			got := bashref.Result{Stdout: te.stdout.String(), Stderr: te.stderr.String(), Code: code}

			want = bashStdin(t, bproj, []string{"AGENT_VM_STATE_DIR=" + bst}, s.stdin, bfiles, s.args...)
			got.Stderr = strings.ReplaceAll(got.Stderr, gst, "STATE")
			want.Stderr = strings.ReplaceAll(want.Stderr, bst, "STATE")
			got.Stderr = strings.ReplaceAll(got.Stderr, gproj, "PROJ")
			want.Stderr = strings.ReplaceAll(want.Stderr, bproj, "PROJ")
			if got.Stdout != want.Stdout || got.Stderr != want.Stderr || got.Code != want.Code {
				t.Errorf("seq %d, %q:\n go:   %+v\n bash: %+v", i, s.args, got, want)
			}
		}
		for j, f := range []string{filepath.Join(gst, "env"), filepath.Join(gproj, ".agent-vm.env")} {
			gb, gerr := os.ReadFile(f)
			bb, bok := want.Files[bfiles[j]]
			if string(gb) != bb || (gerr == nil) != bok {
				t.Errorf("seq %d: %s: go %q, bash %q", i, filepath.Base(f), gb, bb)
			}
			if gerr == nil {
				if fi, _ := os.Stat(f); fi.Mode().Perm() != 0o600 {
					t.Errorf("seq %d: %s mode %v", i, f, fi.Mode())
				}
			}
		}
	}
}

func bashStdin(t *testing.T, dir string, envs []string, stdin string, files []string, args ...string) bashref.Result {
	t.Helper()
	return bashref.Exec(t, bashref.Cmd{Dir: dir, Env: append([]string{"PWD=" + dir}, envs...), Stdin: stdin,
		Snippet: `agent-vm "$@"`, Args: args, Files: files})
}

// After a set, the same warnings as 0.2 when git would commit the file.
func TestProjectEnvGitBash(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	for _, tracked := range []bool{false, true} {
		gproj, bproj := t.TempDir(), t.TempDir()
		for _, p := range []string{gproj, bproj} {
			sub := filepath.Join(p, "sub")
			os.MkdirAll(sub, 0o755)
			exec.Command("git", "-C", p, "init", "-q").Run()
			if tracked {
				os.WriteFile(filepath.Join(sub, ".agent-vm.env"), []byte("X=1\n"), 0o600)
				exec.Command("git", "-C", p, "add", "sub/.agent-vm.env").Run()
			}
		}
		te := newTestEnv(t, nil)
		t.Chdir(filepath.Join(gproj, "sub"))
		t.Setenv("PWD", filepath.Join(gproj, "sub"))
		code := te.main(context.Background(), []string{"project-env", "set", "K", "v"})
		want := bashStdin(t, filepath.Join(bproj, "sub"), []string{"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1"}, "", nil, "project-env", "set", "K", "v")
		got := strings.ReplaceAll(te.stderr.String(), gproj, "PROJ")
		if code != want.Code || got != strings.ReplaceAll(want.Stderr, bproj, "PROJ") || got == "" {
			t.Errorf("tracked %v:\n go:   %d %q\n bash: %d %q", tracked, code, got, want.Code, want.Stderr)
		}
	}
}

// A repository the VM planted in the project (a bare one made a work tree,
// its config naming a command): the warning after a set runs nothing of it,
// whatever the user's safe.bareRepository.
func TestProjectEnvPlantedRepo(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	proj, marker := t.TempDir(), filepath.Join(t.TempDir(), "ran")
	cmd := filepath.Join(t.TempDir(), "fsm.sh")
	os.WriteFile(cmd, []byte("#!/bin/sh\necho ran >> "+marker+"\n"), 0o755)
	exec.Command("git", "init", "-q", "--bare", proj).Run()
	for _, kv := range [][2]string{{"core.bare", "false"}, {"core.worktree", proj}, {"core.fsmonitor", cmd}, {"core.pager", cmd}} {
		exec.Command("git", "-C", proj, "config", kv[0], kv[1]).Run()
	}
	te := newTestEnv(t, nil)
	t.Chdir(proj)
	t.Setenv("PWD", proj)
	if code := te.main(context.Background(), []string{"project-env", "set", "K", "v"}); code != 0 {
		t.Fatalf("set: %d %s", code, te.out())
	}
	if _, err := os.Stat(marker); err == nil {
		t.Error("ran the planted repository's command")
	}
}

// A project env file that is a symlink is never followed.
func TestProjectEnvSymlink(t *testing.T) {
	proj := t.TempDir()
	secret := filepath.Join(t.TempDir(), "secret")
	os.WriteFile(secret, []byte("TOPSECRET=1\n"), 0o600)
	os.Symlink(secret, filepath.Join(proj, ".agent-vm.env"))
	t.Chdir(proj)
	t.Setenv("PWD", proj)
	for _, args := range [][]string{{"project-env", "get", "TOPSECRET"}, {"project-env", "list"}, {"project-env", "set", "K", "v"}, {"project-env", "unset", "TOPSECRET"}} {
		te := newTestEnv(t, nil)
		if code := te.main(context.Background(), args); code != 2 || !strings.Contains(te.stderr.String(), "is a symlink") || strings.Contains(te.stdout.String(), "TOPSECRET") {
			t.Errorf("%q: %d %s %s", args, code, te.stdout.String(), te.stderr.String())
		}
	}
	if b, _ := os.ReadFile(secret); string(b) != "TOPSECRET=1\n" {
		t.Error("the target changed")
	}
}
