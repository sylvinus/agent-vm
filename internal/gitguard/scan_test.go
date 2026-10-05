package gitguard

import (
	"context"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/bashref"
	"github.com/sylvinus/agent-vm/internal/mounts"
	"github.com/sylvinus/agent-vm/internal/paths"
)

type box struct {
	t                    *testing.T
	root, home, proj, sb string
	state, volumes, xdg  string
}

func newBox(t *testing.T) *box {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	root, _ := filepath.EvalSymlinks(t.TempDir())
	// Host-spelled, as the callers pass their folders: mixed separators
	// never compare on Windows.
	root = paths.Host(root)
	b := &box{t: t, root: root, home: root + "/home", proj: root + "/home/proj", sb: root + "/sb"}
	b.state = b.home + "/.agent-vm"
	b.volumes = b.state + "/volumes"
	for _, d := range []string{b.proj, b.state, b.sb} {
		os.MkdirAll(d, 0o755)
	}
	b.git(b.proj, "init", "-q")
	return b
}

func (b *box) env() []string {
	e := []string{"HOME=" + b.home, "GIT_CONFIG_NOSYSTEM=1", "AGENT_VM_STATE_DIR=" + b.state}
	if b.xdg != "" {
		e = append(e, "XDG_CONFIG_HOME="+b.xdg)
	}
	return e
}

func (b *box) git(dir string, args ...string) {
	b.t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append([]string{"PATH=" + os.Getenv("PATH")}, b.env()...)
	if out, err := cmd.CombinedOutput(); err != nil {
		b.t.Fatalf("git %q: %v %s", args, err, out)
	}
}

func (b *box) write(p, content string) {
	os.MkdirAll(filepath.Dir(p), 0o755)
	os.WriteFile(p, []byte(content), 0o755)
}

func (b *box) vol(lines ...string) { b.write(b.volumes, strings.Join(lines, "\n")+"\n") }

// compare runs both scans of the project and wants the same lines.
func (b *box) compare(name string) []string {
	b.t.Helper()
	for _, kv := range b.env() {
		k, v, _ := strings.Cut(kv, "=")
		b.t.Setenv(k, v)
	}
	// git's global config from the sandbox's HOME, or its XDG folder.
	b.t.Setenv("GIT_CONFIG_GLOBAL", "")
	os.Unsetenv("GIT_CONFIG_GLOBAL")
	if b.xdg == "" {
		b.t.Setenv("XDG_CONFIG_HOME", "")
		os.Unsetenv("XDG_CONFIG_HOME")
	}
	refs := mounts.Refs(b.home, bashref.Root(), b.state, b.home+"/.lima")
	shares := Shares(b.proj, mounts.RWDirs(mounts.Entries(b.volumes, b.proj, b.home, refs, io.Discard)))
	got := Scan(context.Background(), shares, b.home).Lines()
	r := bashref.Run(b.t, "", b.env(), "_agent_vm_git_scan", b.proj)
	// 0.2 named the project ".".
	r.Stdout = strings.ReplaceAll(r.Stdout, "repositories in .:", "repositories in the project:")
	want := strings.Split(strings.TrimSuffix(r.Stdout, "\n"), "\n")
	if r.Stdout == "" {
		want = nil
	}
	g := append([]string(nil), got...)
	sort.Strings(g)
	sort.Strings(want)
	if name == "other capitals" && paths.NoCase() {
		// Where case is ignored the uppercased path names the hooks
		// folder, which the Linux oracle cannot see. The table below
		// checks Go's lines.
		return got
	}
	if strings.Join(g, "\n") != strings.Join(want, "\n") {
		b.t.Errorf("%s:\n go:\n  %s\n bash:\n  %s", name, strings.Join(g, "\n  "), strings.Join(want, "\n  "))
	}
	return got
}

// A hooks name keeps a risk under it read-only only when accepted.
func TestRisksUnderDeclinedName(t *testing.T) {
	b := newBox(t)
	b.git(b.proj, "config", "core.hooksPath", "tools/hooks")
	b.git(b.proj, "config", "core.fsmonitor", "tools/fsmon.sh")
	// A command reached through a link: protected at its first hop, not at
	// the second.
	os.MkdirAll(b.proj+"/tools", 0o755)
	os.MkdirAll(b.proj+"/scripts", 0o755)
	os.Symlink("../scripts/real.sh", b.proj+"/tools/relay.sh")
	b.git(b.proj, "config", "core.pager", "tools/relay.sh")
	b.compare("declined")
	r := Scan(context.Background(), Shares(b.proj, nil), b.home)
	accepted := r.Risks([]string{".git", ".hg", "tools"})
	if strings.Join(accepted, "\n") != "core.pager = tools/relay.sh" {
		t.Errorf("tools accepted: %q", accepted)
	}
	declined := strings.Join(r.Risks(mounts.BaseNames), "\n")
	if !strings.Contains(declined, "core.fsmonitor = tools/fsmon.sh") || !strings.Contains(declined, "core.pager = tools/relay.sh") {
		t.Errorf("tools declined: %q", declined)
	}
}

// A link in the project halfway along a path outside it: the VM can
// retarget it, so it counts. (0.2 resolved the folder in one step and missed
// it.)
func TestScanMiddleLink(t *testing.T) {
	b := newBox(t)
	os.MkdirAll(b.sb+"/outside", 0o755)
	os.MkdirAll(b.sb+"/other/b", 0o755)
	os.Symlink(b.proj+"/lnk", b.sb+"/outside/a")
	os.Symlink(b.sb+"/other", b.proj+"/lnk")
	b.git(b.proj, "config", "core.hooksPath", b.sb+"/outside/a/b")
	b.git(b.proj, "config", "core.fsmonitor", b.sb+"/outside/a/mon.sh")
	r := Scan(context.Background(), Shares(b.proj, nil), b.home)
	if strings.Join(r.Hooks, "\n") != "lnk\tlnk" {
		t.Errorf("hooks: %q", r.Hooks)
	}
	if risks := r.Risks(mounts.BaseNames); len(risks) != 1 || risks[0] != "core.fsmonitor = "+b.sb+"/outside/a/mon.sh" {
		t.Errorf("risks: %q", risks)
	}
	// With "lnk" read-only, the link cannot be retargeted: no risk.
	if risks := r.Risks(r.Names()); len(risks) != 0 {
		t.Errorf("risks with the names: %q", risks)
	}
}

// A hooks folder in a writable volume inside the repository: named from the
// top of the repository, and the volume's root is that name, which covers
// nothing in the volume. (0.2 named it "_", leaving .husky/pre-commit
// writable.)
func TestScanHooksInVolume(t *testing.T) {
	b := newBox(t)
	os.MkdirAll(b.proj+"/.husky/_", 0o755)
	b.git(b.proj, "config", "core.hooksPath", ".husky/_")
	r := Scan(context.Background(), Shares(b.proj, []string{b.proj + "/.husky"}), b.home)
	if strings.Join(r.Hooks, "\n") != ".husky/_\t." {
		t.Errorf("hooks: %q", r.Hooks)
	}
	// Without the volume, the name is .husky.
	r = Scan(context.Background(), Shares(b.proj, nil), b.home)
	if strings.Join(r.Hooks, "\n") != ".husky/_\t.husky/_" {
		t.Errorf("hooks without the volume: %q", r.Hooks)
	}
}

// Settings git runs a command from, each checked against git 2.47 (0.2
// missed them).
func TestScanCommandKeys(t *testing.T) {
	b := newBox(t)
	keys := []string{
		"mergetool.vimdiff.path", "difftool.vimdiff.path", "browser.firefox.path", "man.konqueror.path",
		"guitool.lint.cmd", "trailer.sign.cmd", "trailer.x.command", "submodule.s.update",
		"remote.o.uploadpack", "remote.o.receivepack", "tar.tgz.command", "instaweb.httpd",
		"sendemail.smtpServer", "sendemail.sendmailCmd", "sendemail.toCmd", "sendemail.ccCmd",
		"sendemail.headerCmd", "sendemail.work.toCmd", "gpg.ssh.defaultKeyCommand",
	}
	for _, k := range keys {
		v := "tools/run.sh"
		if k == "submodule.s.update" {
			v = "!" + v
		}
		b.git(b.proj, "config", k, v)
	}
	// A host name: no path, no risk.
	b.git(b.proj, "config", "sendemail.work.smtpServer", "smtp.example.com")
	risks := Scan(context.Background(), Shares(b.proj, nil), b.home).Risks(mounts.BaseNames)
	if len(risks) != len(keys) {
		t.Errorf("%d risks for %d keys:\n%s", len(risks), len(keys), strings.Join(risks, "\n"))
	}
	// As git prints them: section and key lowercased.
	all := strings.ToLower(strings.Join(risks, "\n"))
	for _, k := range keys {
		if !strings.Contains(all, strings.ToLower(k)+" = ") {
			t.Errorf("missing %s", k)
		}
	}
}

// A command's argument without a /, a file at the top of the repository,
// where git runs it: a risk, as with ./build.sh (0.2 missed it). A word
// that names no file there is no path.
func TestScanBareArgument(t *testing.T) {
	b := newBox(t)
	b.write(b.proj+"/build.sh", "#!/bin/sh\n")
	b.git(b.proj, "config", "alias.b", "!bash build.sh")
	b.git(b.proj, "config", "alias.lg", "!git log --graph")
	b.git(b.proj, "config", "core.fsmonitor", "fsmon.sh")
	risks := strings.Join(Scan(context.Background(), Shares(b.proj, nil), b.home).Risks(mounts.BaseNames), "\n")
	if risks != "alias.b = !bash build.sh" {
		t.Errorf("risks:\n%s", risks)
	}
}

// A config file in a folder with non-ASCII characters, which git quotes in
// its origins without -z: found all the same. (0.2 missed it.)
func TestScanNonASCII(t *testing.T) {
	b := newBox(t)
	dir := b.proj + "/été/cfg"
	os.MkdirAll(dir, 0o755)
	b.write(dir+"/first.gitconfig", "[include]\n\tpath = second.gitconfig\n")
	b.write(dir+"/second.gitconfig", "[core]\n\teditor = vi\n")
	b.git(b.proj, "config", "include.path", "../été/cfg/first.gitconfig")
	risks := strings.Join(Scan(context.Background(), Shares(b.proj, nil), b.home).Risks(mounts.BaseNames), "\n")
	for _, want := range []string{"config file été/cfg/first.gitconfig", "config file été/cfg/second.gitconfig"} {
		if !strings.Contains(risks, want) {
			t.Errorf("missing %q in:\n%s", want, risks)
		}
	}
}

func TestScanBash(t *testing.T) {
	cases := map[string]func(b *box){
		"nothing":  func(b *box) {},
		"husky":    func(b *box) { b.git(b.proj, "config", "core.hooksPath", ".husky/_") },
		"absolute": func(b *box) { b.git(b.proj, "config", "core.hooksPath", b.proj+"/.githooks") },
		"other capitals": func(b *box) {
			b.git(b.proj, "config", "core.hooksPath", strings.ToUpper(b.proj)+"/.husky/_")
		},
		"nested": func(b *box) {
			os.MkdirAll(b.proj+"/lib/inner", 0o755)
			b.git(b.proj+"/lib/inner", "init", "-q")
			b.git(b.proj+"/lib/inner", "config", "core.hooksPath", ".githooks")
		},
		"project itself": func(b *box) { b.git(b.proj, "config", "core.hooksPath", ".") },
		"dot-dot":        func(b *box) { b.git(b.proj, "config", "core.hooksPath", "tools/../.githooks") },
		"under .Git":     func(b *box) { b.git(b.proj, "config", "core.hooksPath", ".Git/hooks") },
		"outside":        func(b *box) { b.git(b.proj, "config", "core.hooksPath", b.sb+"/hooks") },
		"project in a repository": func(b *box) {
			os.RemoveAll(b.proj + "/.git")
			b.git(b.home, "init", "-q")
			b.git(b.home, "config", "core.hooksPath", "proj/hooks")
		},
		"hooks above the project": func(b *box) {
			os.RemoveAll(b.proj + "/.git")
			b.git(b.home, "init", "-q")
			b.git(b.home, "config", "core.hooksPath", ".githooks")
		},
		"bad name": func(b *box) { b.git(b.proj, "config", "core.hooksPath", `a"b/x`) },
		"hooks dir linked": func(b *box) {
			os.MkdirAll(b.proj+"/scripts/hooks", 0o755)
			os.RemoveAll(b.proj + "/.git/hooks")
			os.Symlink("../scripts/hooks", b.proj+"/.git/hooks")
		},
		"hooksPath linked": func(b *box) {
			os.MkdirAll(b.proj+"/scripts/hooks", 0o755)
			os.Symlink("scripts/hooks", b.proj+"/.githooks")
			b.git(b.proj, "config", "core.hooksPath", ".githooks")
		},
		"hook links": func(b *box) {
			b.write(b.proj+"/scripts/pre-commit", "#!/bin/sh\n")
			b.write(b.sb+"/elsewhere-hook", "#!/bin/sh\n")
			os.Symlink("../../scripts/pre-commit", b.proj+"/.git/hooks/pre-commit")
			os.Symlink(b.sb+"/elsewhere-hook", b.proj+"/.git/hooks/post-commit")
			os.Symlink("../../later/pre-push", b.proj+"/.git/hooks/pre-push")
			os.Symlink(b.sb+"/elsewhere-hook", b.proj+"/scripts/relay")
			os.Symlink("../../scripts/relay", b.proj+"/.git/hooks/post-merge")
			os.Symlink(b.proj+"/scripts/pre-commit", b.sb+"/back-link")
			os.Symlink(b.sb+"/back-link", b.proj+"/.git/hooks/pre-rebase")
			os.Symlink("../../scripts/pre-commit", b.proj+"/.git/hooks/.hidden")
		},
		"hooks dir not there yet": func(b *box) {
			os.RemoveAll(b.proj + "/.git/hooks")
			os.Symlink("../tools/hooks", b.proj+"/.git/hooks")
		},
		"hooks dir through a relay": func(b *box) {
			os.MkdirAll(b.sb+"/shared-hooks", 0o755)
			os.MkdirAll(b.proj+"/scripts", 0o755)
			os.Symlink(b.sb+"/shared-hooks", b.proj+"/scripts/hooks-relay")
			os.RemoveAll(b.proj + "/.git/hooks")
			os.Symlink("../scripts/hooks-relay", b.proj+"/.git/hooks")
		},
		"protected folder link and control characters": func(b *box) {
			b.write(b.proj+"/.githooks/post-merge", "#!/bin/sh\n")
			os.Symlink("post-merge", b.proj+"/.githooks/post-rewrite")
			b.write(b.proj+"/scripts/pre-commit", "#!/bin/sh\n")
			os.Symlink("../scripts/pre-commit", b.proj+"/.githooks/a\033]0;x\007b")
			b.git(b.proj, "config", "core.hooksPath", ".githooks")
		},
		"volume repo": func(b *box) {
			os.MkdirAll(b.sb+"/vrepo", 0o755)
			b.git(b.sb+"/vrepo", "init", "-q")
			b.git(b.sb+"/vrepo", "config", "core.hooksPath", "tools/hooks")
			b.git(b.sb+"/vrepo", "config", "core.fsmonitor", "./fsmon.sh")
			b.vol(b.sb + "/vrepo:/mnt/vrepo:rw")
		},
		"read-only volume repo": func(b *box) {
			os.MkdirAll(b.sb+"/vrepo", 0o755)
			b.git(b.sb+"/vrepo", "init", "-q")
			b.git(b.sb+"/vrepo", "config", "core.hooksPath", "tools/hooks")
			b.vol(b.sb + "/vrepo:/mnt/vrepo:ro")
		},
		"across shares": func(b *box) {
			os.MkdirAll(b.sb+"/teamtools/hooks", 0o755)
			b.vol(b.sb + "/teamtools:/mnt/teamtools:rw")
			b.git(b.proj, "config", "core.fsmonitor", b.sb+"/teamtools/fsmon.sh")
			b.git(b.proj, "config", "include.path", b.sb+"/teamtools/gitconfig")
		},
		"hooks in a volume": func(b *box) {
			os.MkdirAll(b.sb+"/teamtools/hooks", 0o755)
			b.vol(b.sb + "/teamtools:/mnt/teamtools:rw")
			b.git(b.proj, "config", "core.hooksPath", b.sb+"/teamtools/hooks")
		},
		"git's own config in a volume": func(b *box) {
			b.write(b.sb+"/teamtools/git/config", "[core]\n\tfsmonitor = "+b.sb+"/teamtools/fsmon.sh\n")
			b.vol(b.sb + "/teamtools:/mnt/teamtools:rw")
			b.xdg = b.sb + "/teamtools"
		},
		"volume through a symlink": func(b *box) {
			os.MkdirAll(b.sb+"/data/code/app", 0o755)
			os.Symlink(b.sb+"/data/code", b.sb+"/code-link")
			b.git(b.sb+"/data/code/app", "init", "-q")
			b.git(b.sb+"/data/code/app", "config", "core.hooksPath", ".husky/_")
			b.vol(b.sb + "/code-link:/mnt/code:rw")
		},
		"bare repository in a volume": func(b *box) {
			os.MkdirAll(b.sb+"/remotes", 0o755)
			exec.Command("git", "init", "-q", "--bare", b.sb+"/remotes/proj.git").Run()
			b.vol(b.sb + "/remotes:/mnt/remotes:rw")
		},
		"config": func(b *box) {
			b.git(b.proj, "config", "core.pager", "less")
			b.git(b.proj, "config", "core.sshCommand", "ssh -o ProxyCommand=/usr/bin/nc")
			b.git(b.proj, "config", "alias.st", "status")
			b.write(b.proj+"/.gitconfig", "[core]\n\tfsmonitor = ./watch.sh\n")
			b.git(b.proj, "config", "include.path", "../.gitconfig")
			b.git(b.proj, "config", "filter.x.clean", "scripts/clean.sh %f")
			b.git(b.proj, "config", "alias.t", "!./t.sh")
			b.git(b.proj, "config", "alias.q", `!"./q.sh" x`)
			b.git(b.proj, "config", "credential.helper", "'tools/cred' --x=y")
		},
		"includes": func(b *box) {
			b.git(b.proj, "config", "includeIf.gitdir:/.path", "../later.gitconfig")
			b.git(b.proj, "config", "--add", "include.path", "../.git/x.gitconfig")
			b.git(b.proj, "config", "--add", "include.path", b.sb+"/outside.gitconfig")
			b.git(b.proj, "config", "--add", "include.path", "~/proj/home.gitconfig")
		},
		"other scopes": func(b *box) {
			b.write(b.home+"/.gitconfig", "[alias]\n\tg = !./g.sh\n")
			b.git(b.proj, "config", "extensions.worktreeConfig", "true")
			b.git(b.proj, "config", "--worktree", "core.editor", "./ed.sh")
		},
		"global hooksPath into the project": func(b *box) {
			b.write(b.home+"/.gitconfig", "[core]\n\thooksPath = ~/proj/hooks\n")
		},
		"many repositories": func(b *box) {
			for i := 0; i < 52; i++ {
				d := b.proj + "/r/" + strconv.Itoa(i)
				os.MkdirAll(d+"/.git", 0o755)
			}
		},
		"node_modules": func(b *box) {
			os.MkdirAll(b.proj+"/node_modules/pkg/.git", 0o755)
			os.MkdirAll(b.proj+"/a/node_modules/.git", 0o755)
			os.MkdirAll(b.proj+"/a/b/.git", 0o755)
			os.MkdirAll(b.proj+"/a/b/c/.git", 0o755)
		},
	}
	// What each scan must say, bash or not ("" for nothing).
	expect := map[string]string{
		"nothing":                   "",
		"husky":                     "H\t.husky/_\t.husky/_",
		"absolute":                  "H\t.githooks\t.githooks",
		"other capitals":            "",
		"nested":                    "H\tlib/inner/.githooks\t.githooks",
		"project itself":            "H\t.\t.",
		"dot-dot":                   "H\t.githooks\t.githooks",
		"under .Git":                "",
		"outside":                   "",
		"project in a repository":   "H\thooks\thooks",
		"hooks above the project":   "",
		"bad name":                  "H\ta\"b/x\ta\"b/x",
		"hooks dir linked":          "H\tscripts/hooks\tscripts/hooks",
		"hooksPath linked":          "H\tscripts/hooks\tscripts/hooks",
		"hook links":                "R\thook pre-rebase runs scripts/pre-commit",
		"hooks dir not there yet":   "H\ttools/hooks\ttools/hooks",
		"hooks dir through a relay": "H\tscripts/hooks-relay\tscripts/hooks-relay",
		"protected folder link and control characters": "R\thook a?]0;x?b runs scripts/pre-commit",
		"volume repo":                       "R\tcore.fsmonitor = ./fsmon.sh",
		"read-only volume repo":             "",
		"across shares":                     "/teamtools/gitconfig",
		"hooks in a volume":                 "/teamtools/hooks\thooks",
		"git's own config in a volume":      "/teamtools/git/config",
		"volume through a symlink":          "/data/code/app/.husky/_\t.husky/_",
		"bare repository in a volume":       "/remotes/proj.git/hooks\tproj.git/hooks",
		"config":                            "R\tfilter.x.clean = scripts/clean.sh %f",
		"includes":                          "R\tconfig file later.gitconfig",
		"other scopes":                      "R\tcore.editor = ./ed.sh",
		"global hooksPath into the project": "H\thooks\thooks",
		"many repositories":                 "R\tmore than 50 repositories in the project:",
		"node_modules":                      "",
	}
	// Where case is ignored, the path in other capitals is the project's.
	if paths.NoCase() {
		expect["other capitals"] = "H\t.husky/_\t.husky/_"
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			b := newBox(t)
			setup(b)
			got := strings.Join(b.compare(name), "\n")
			want, ok := expect[name]
			switch {
			case !ok:
				t.Errorf("no expectation for %q", name)
			case want == "" && name != "node_modules" && got != "":
				t.Errorf("expected nothing, got:\n%s", got)
			case want != "" && !strings.Contains(got, want):
				t.Errorf("expected %q in:\n%s", want, got)
			}
		})
	}
}
