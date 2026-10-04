// Package gitguard finds what git on this machine runs, or reads, from the
// folders a VM can write: hooks, and commands its config names. The VM can
// write the project and the writable volumes; git runs hooks and commands
// from paths anywhere, in the repository's own share, in another share
// (core.hooksPath into a volume), or from git's own config kept in one. Each
// path is followed through every symlink on the way, and checked against
// every share.
package gitguard

import (
	"bytes"
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/sylvinus/agent-vm/internal/gitx"
	"github.com/sylvinus/agent-vm/internal/mounts"
	"github.com/sylvinus/agent-vm/internal/paths"
)

// Spelling is dir as git spells it: the physical path, C:/... on Windows.
func Spelling(dir string) (string, bool) {
	p, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return "", false
	}
	if !filepath.IsAbs(p) {
		if p, err = filepath.Abs(p); err != nil {
			return "", false
		}
	}
	return filepath.ToSlash(p), true
}

// gitAbs is p made absolute against base (both in git's spelling), "." and
// ".." resolved in the text.
func gitAbs(p, base string) string {
	switch {
	case strings.HasPrefix(p, "/"):
		return paths.Join("/", p)
	case len(p) >= 3 && p[1] == ':' && p[2] == '/' && isLetter(p[0]):
		return paths.Join(p[:2], p[3:])
	}
	return paths.Join(base, p)
}

func isLetter(c byte) bool { return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' }

// isAbs: /... or C:/...
func isAbs(p string) bool {
	return strings.HasPrefix(p, "/") || len(p) >= 3 && p[1] == ':' && p[2] == '/' && isLetter(p[0])
}

// Shares are the folders the VM can write, in git's spelling, each once:
// the project first, then its writable volumes.
func Shares(project string, rwVolumes []string) []string {
	var out []string
	seen := map[string]bool{}
	for _, d := range append([]string{project}, rwVolumes...) {
		if d == "" {
			continue
		}
		if s, ok := Spelling(d); ok && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// scan is one run over the shares.
type scan struct {
	ctx    context.Context
	shares []string
	proj   string
	home   string
	hooks  []string // see Result
	risks  []risk
	seen   map[string]bool
}

// emit adds a hooks line, once.
func (s *scan) emit(line string) {
	if !s.seen[line] {
		s.seen[line] = true
		s.hooks = append(s.hooks, line)
	}
}

// inShare is the deepest share holding p, and p relative to it ("." for the
// share itself).
func (s *scan) inShare(p string) (share, rel string, ok bool) {
	for _, d := range s.shares {
		d = strings.TrimSuffix(d, "/")
		if d == "" {
			continue
		}
		if r, in := paths.In(p, d); in && len(d) > len(share) {
			share, rel, ok = d, r, true
		}
	}
	return
}

// hops is every path the file system goes through to reach p (absolute, in
// git's spelling): p; each symlink on the way, wherever it is in the path,
// as the link itself (the VM, able to write it, retargets it); and where it
// all leads, whether that exists or not (the VM can create it). Followed
// one component at a time, up to 40 links. A VM able to write any of them
// chooses what is found there.
func hops(p string) []string {
	out := []string{p}
	seen := map[string]bool{p: true}
	add := func(q string) {
		if !seen[q] {
			seen[q] = true
			out = append(out, q)
		}
	}
	root, rest := "/", strings.TrimPrefix(p, "/")
	if len(p) >= 3 && p[1] == ':' && p[2] == '/' {
		root, rest = p[:3], p[3:]
	}
	cur := strings.TrimSuffix(root, "/")
	links := 0
	for rest != "" {
		var comp string
		comp, rest, _ = strings.Cut(rest, "/")
		switch comp {
		case "", ".":
			continue
		case "..":
			cur = cur[:max(strings.LastIndexByte(cur, '/'), 0)]
			continue
		}
		next := cur + "/" + comp
		fi, err := os.Lstat(next)
		if err != nil {
			// Not there: what follows is where the VM could create it.
			cur = next
			if rest != "" {
				cur += "/" + strings.TrimSuffix(rest, "/")
			}
			rest = ""
			break
		}
		if fi.Mode()&fs.ModeSymlink == 0 {
			cur = next
			continue
		}
		add(next)
		if links++; links > 40 {
			return out
		}
		t, err := os.Readlink(next)
		if err != nil {
			return out
		}
		t = filepath.ToSlash(t)
		if isAbs(t) {
			r := "/"
			if t[0] != '/' {
				r = t[:3]
			}
			cur, t = strings.TrimSuffix(r, "/"), strings.TrimPrefix(t, r)
		}
		if rest != "" {
			t += "/" + rest
		}
		rest = t
	}
	if cur == "" {
		cur = "/"
	}
	add(cur)
	return out
}

// git runs git for the repository at of kind kind: W a work tree, B a bare
// repository (named explicitly, as safe.bareRepository=explicit allows), G
// none, for git's own global and system config.
func (s *scan) git(kind, at string, args ...string) ([]byte, error) {
	switch kind {
	case "W":
		args = append([]string{"-C", at}, args...)
	case "B":
		args = append([]string{"--git-dir=" + at}, args...)
	default:
		args = append([]string{"-C", "/"}, args...)
	}
	out, err := gitx.Untrusted(s.ctx, args...).Output()
	// As $(...): every trailing newline goes.
	return bytes.TrimRight(out, "\n"), err
}

// repo is a repository found in a share.
type repo struct{ kind, at string }

// repos are those git on this machine finds in the share dir: the one
// holding dir, then work trees and bare repositories up to two levels below
// it (node_modules skipped), 50 at most; an X entry when there are more.
func (s *scan) repos(dir string) []repo {
	var out []repo
	if _, err := s.git("W", dir, "rev-parse", "--git-dir"); err == nil {
		out = append(out, repo{"W", dir})
	}
	n := 0
	found := func(g string) bool {
		if n++; n > 50 {
			out = append(out, repo{"X", dir})
			return false
		}
		if _, err := os.Lstat(g + "/.git"); err == nil {
			out = append(out, repo{"W", g})
		} else {
			out = append(out, repo{"B", g})
		}
		return true
	}
	// As `find dir/ -mindepth 2 -maxdepth 3 ( -name node_modules -prune ) -o
	// ( -name .git -print -prune ) -o ( -name objects -type d -print -prune )`.
	var walk func(d string, depth int) bool
	walk = func(d string, depth int) bool {
		ents, err := os.ReadDir(d)
		if err != nil {
			return true
		}
		for _, e := range ents {
			p := d + "/" + e.Name()
			if depth+1 >= 2 {
				switch {
				case e.Name() == "node_modules":
					continue
				case e.Name() == ".git":
					if !found(d) {
						return false
					}
					continue
				case e.Name() == "objects" && e.IsDir():
					if isFile(d+"/HEAD") && isDir(d+"/refs") && !found(d) {
						return false
					}
					continue
				}
			}
			if depth+1 < 3 && e.IsDir() {
				if !walk(p, depth+1) {
					return false
				}
			}
		}
		return true
	}
	walk(strings.TrimSuffix(dir, "/"), 0)
	return out
}

func isFile(p string) bool { fi, err := os.Stat(p); return err == nil && fi.Mode().IsRegular() }
func isDir(p string) bool  { fi, err := os.Stat(p); return err == nil && fi.IsDir() }

// hooksDir is the hooks folder of the repository at of kind kind, absolute,
// in git's spelling, as git names it (symlinks not resolved), and the top
// of the work tree for W. For G, the absolute core.hooksPath git's own
// config sets for every repository.
func (s *scan) hooksDir(kind, at string) (top, hooks string, ok bool) {
	base := "/"
	switch kind {
	case "G":
		out, err := s.git("G", "/", "config", "--get", "core.hooksPath")
		if err != nil {
			return "", "", false
		}
		hooks = string(out)
		if strings.HasPrefix(hooks, "~/") {
			hooks = s.home + hooks[1:]
		}
		if !isAbs(hooks) {
			return "", "", false
		}
	case "W":
		out, err := s.git("W", at, "rev-parse", "--show-toplevel", "--git-path", "hooks")
		if err != nil {
			return "", "", false
		}
		t, h, two := strings.Cut(string(out), "\n")
		if !two {
			return "", "", false
		}
		top, hooks = t, h
		if base, ok = Spelling(at); !ok {
			return "", "", false
		}
	default:
		out, err := s.git(kind, at, "rev-parse", "--git-path", "hooks")
		if err != nil {
			return "", "", false
		}
		hooks = string(out)
	}
	if hooks == "" || strings.ContainsAny(hooks, "\n\t") || strings.Contains(top, "\t") {
		return "", "", false
	}
	return top, gitAbs(hooks, base), true
}

// hop is a path the VM can write on the way to something git runs: shown
// relative to the project when it is there, and relative to its share,
// where the read-only names apply.
type hop struct{ shown, rel string }

// hits are the paths on the way to p (see hops) in a share and outside the
// names always listed, in order. Which of them a hooks name keeps read-only
// is only known once the user answered (see Result.Risks).
func (s *scan) hits(p string) []hop {
	if p == "" {
		return nil
	}
	var out []hop
	for _, h := range hops(p) {
		_, rel, ok := s.inShare(h)
		if !ok || mounts.UnderName(rel, nil) {
			continue
		}
		out = append(out, hop{s.shown(h), rel})
	}
	return out
}

// shown is p relative to the project when it is there, a writable volume
// inside it included, else p.
func (s *scan) shown(p string) string {
	if r, ok := paths.In(p, s.proj); ok {
		return r
	}
	return p
}

// risk is a risk to accept: text, or prefix and the first of hops no name
// protects. A risk with prefix and no hops is no risk.
type risk struct {
	prefix, text string
	hops         []hop
}

func (s *scan) risk(r risk) {
	if r.prefix != "" && len(r.hops) == 0 {
		return
	}
	s.risks = append(s.risks, r)
}

func visible(t string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return '?'
		}
		return r
	}, t)
}

// The settings that hold a command git runs (section and key names
// lowercased, as `git config --list` prints them).
var commandKey = regexp.MustCompile(`^(core\.(fsmonitor|sshcommand|editor|pager|askpass|gitproxy|alternaterefscommand)|sequence\.editor|gpg\.program|gpg\..*\.program|gpg\.ssh\.defaultkeycommand|diff\.external|diff\..*\.(command|textconv)|(difftool|mergetool|browser|man)\..*\.(cmd|path)|guitool\..*\.cmd|merge\..*\.driver|filter\..*\.(clean|smudge|process)|credential\.helper|credential\..*\.helper|pager\..*|alias\..*|interactive\.difffilter|uploadpack\.packobjectshook|web\.browser|instaweb\.httpd|trailer\..*\.(cmd|command)|submodule\..*\.update|remote\..*\.(uploadpack|receivepack)|tar\..*\.command|sendemail\.(.*\.)?(smtpserver|sendmailcmd|tocmd|cccmd|headercmd))$`)

var includeKey = regexp.MustCompile(`^includeif\..*\.path$`)

// config reports the risks of the config git reads for the repository at of
// kind kind, whose work tree is cmdBase: config files in a share (included
// ones whether they exist yet or not: git skips a missing one, and the VM
// can create it), and settings whose command a share holds, a path in their
// value taken from the top of the repository, where git runs most of them.
func (s *scan) config(kind, at, cmdBase string) {
	base := "/"
	switch kind {
	case "W":
		var ok bool
		if base, ok = Spelling(at); !ok {
			return
		}
	case "B":
		cmdBase = at
	}
	// -z: each entry is its origin, a NUL, the key, a newline, the value, a
	// NUL. Origins come unquoted, whatever their characters.
	out, _ := s.git(kind, at, "config", "--list", "--show-origin", "--includes", "-z")
	fields := strings.Split(string(out), "\x00")
	seenFile := map[string]bool{}
	for i := 0; i+1 < len(fields); i += 2 {
		origin, kv := fields[i], fields[i+1]
		f, _ := strings.CutPrefix(origin, "file:")
		if !strings.HasPrefix(origin, "file:") {
			f = ""
		}
		if f != "" && !seenFile[f] {
			seenFile[f] = true
			s.risk(risk{prefix: "config file ", hops: s.hits(gitAbs(filepath.ToSlash(f), base))})
		}
		key, val, _ := strings.Cut(kv, "\n")
		lk := strings.ToLower(key)
		if lk == "include.path" || includeKey.MatchString(lk) {
			if f == "" {
				continue
			}
			// Relative to the file holding it, as git takes it.
			if strings.HasPrefix(val, "~/") {
				val = s.home + val[1:]
			}
			a := gitAbs(filepath.ToSlash(f), base)
			s.risk(risk{prefix: "config file ", hops: s.hits(gitAbs(val, a[:strings.LastIndexByte(a, '/')]))})
			continue
		}
		if !commandKey.MatchString(lk) || strings.HasPrefix(lk, "alias.") && !strings.HasPrefix(val, "!") {
			continue
		}
		// One risk for the setting, with the paths of every word: the first
		// no name protects is the one that counts.
		r := risk{text: key + " = " + val}
		for i, w := range strings.FieldsFunc(strings.TrimPrefix(val, "!"), func(r rune) bool { return r == ' ' || r == '\t' }) {
			// One quote of either kind off each end.
			if w[0] == '"' || w[0] == '\'' {
				w = w[1:]
			}
			if n := len(w); n > 0 && (w[n-1] == '"' || w[n-1] == '\'') {
				w = w[:n-1]
			}
			// Not an option, an assignment or a URL: a path.
			if w == "" || strings.HasPrefix(w, "-") || strings.Contains(w, "=") || strings.Contains(w, "://") {
				continue
			}
			// Without a /, the command is found on PATH; an argument is a
			// file from where git runs it (bash build.sh) when there is one
			// there: not every word (git log) is taken for one.
			if !strings.Contains(w, "/") {
				if i == 0 || cmdBase == "" {
					continue
				}
				if _, err := os.Lstat(gitAbs(w, cmdBase)); err != nil {
					continue
				}
			}
			if strings.HasPrefix(w, "~/") {
				w = s.home + w[1:]
			}
			if !isAbs(w) && cmdBase == "" {
				continue
			}
			r.hops = append(r.hops, s.hits(gitAbs(w, cmdBase))...)
		}
		if len(r.hops) > 0 {
			s.risk(r)
		}
	}
}

// Result is what git on this machine runs, or reads, from the shares.
type Result struct {
	// Hooks are the hooks folders, or links on the way to them, in a share
	// and outside the names always listed, each once: where (relative to
	// the project when it is there, else absolute), a tab, then what names
	// it (see HooksName): relative to the top of its repository when that
	// is in a share, else to the share; "." when no name covers it (a share
	// itself, or a name at or above the root of the share holding it),
	// empty for a name no share can carry.
	Hooks []string
	risks []risk
}

// Risks are the risks to accept, as text, each once, when the shares get
// names (the names always listed, and the hooks names accepted): a config
// file in a share, a setting whose command is in one, a hook linked to a
// file in one, a share with more repositories than are checked. What a
// name keeps read-only is no risk; a declined hooks name keeps nothing.
func (r *Result) Risks(names []string) []string {
	var out []string
	seen := map[string]bool{}
	for _, k := range r.risks {
		t := k.text
		if len(k.hops) > 0 {
			t = ""
			for _, h := range k.hops {
				if !mounts.UnderName(h.rel, names) {
					t = k.text
					if t == "" {
						t = k.prefix + h.shown
					}
					break
				}
			}
		}
		if t = visible(t); t != "" && !seen[t] {
			seen[t] = true
			out = append(out, t)
		}
	}
	return out
}

// Names are the names always listed, then those keeping every hooks folder
// read-only, each once: the names when every one is accepted.
func (r *Result) Names() []string {
	var hooks []string
	for _, h := range r.Hooks {
		_, inRepo, _ := strings.Cut(h, "\t")
		if n, ok := HooksName(inRepo); ok {
			hooks = append(hooks, n)
		}
	}
	return NamesWith(hooks)
}

// NamesWith is the names always listed, then hooks, each once.
func NamesWith(hooks []string) []string {
	out := append([]string(nil), mounts.BaseNames...)
	for _, n := range hooks {
		if !slices.Contains(out, n) {
			out = append(out, n)
		}
	}
	return out
}

// Lines are the hooks folders and the risks, every hooks name accepted, as
// 0.2 printed them: "H\t" or "R\t" and the rest.
func (r *Result) Lines() []string {
	var out []string
	for _, h := range r.Hooks {
		out = append(out, "H\t"+h)
	}
	for _, t := range r.Risks(r.Names()) {
		out = append(out, "R\t"+t)
	}
	return out
}

// Scan is what git on this machine runs, or reads, from the shares (see
// Shares; the project first). home is the user's home folder.
func Scan(ctx context.Context, shares []string, home string) *Result {
	if !gitx.Have() || len(shares) == 0 {
		return &Result{}
	}
	s := &scan{ctx: ctx, shares: shares, proj: shares[0], home: filepath.ToSlash(home), seen: map[string]bool{}}
	var all []repo
	for _, sh := range shares {
		all = append(all, s.repos(sh)...)
	}
	all = append(all, repo{"G", "/"})
	var rs []repo
	for _, r := range all {
		if r.kind != "X" {
			rs = append(rs, r)
			continue
		}
		shown := r.at
		if share, rel, ok := s.inShare(r.at); ok && share == s.proj {
			shown = rel
			if rel == "." {
				shown = "the project"
			}
		}
		s.risk(risk{text: "more than 50 repositories in " + shown + ": those after the 50th are not checked"})
	}
	// The hooks folders first: their names keep what is under them read-only.
	hookss := make([]string, len(rs))
	tops := make([]string, len(rs))
	for i, r := range rs {
		top, hooks, ok := s.hooksDir(r.kind, r.at)
		if !ok && r.kind == "W" {
			if out, err := s.git("W", r.at, "rev-parse", "--show-toplevel"); err == nil {
				top = string(out)
			}
		}
		hookss[i], tops[i] = hooks, top
		if hooks == "" {
			continue
		}
		topIn := false
		if top != "" {
			_, _, topIn = s.inShare(top)
		}
		for _, hp := range hops(hooks) {
			_, rel, ok := s.inShare(hp)
			if !ok || rel != "." && mounts.UnderName(rel, nil) {
				continue
			}
			// Named from the top of the repository, even across a writable
			// volume inside it: husky's .husky/_ calls .husky/<hook>.
			inRepo := rel
			if topIn {
				if r, ok := paths.In(hp, top); ok {
					inRepo = r
				}
			}
			// A name only covers what is below it in the share the VM
			// writes through.
			if n, ok := HooksName(inRepo); ok && !mounts.UnderName(rel, []string{n}) {
				inRepo = "."
			}
			if strings.IndexFunc(inRepo, unicode.IsControl) >= 0 {
				inRepo = ""
			}
			shown := s.shown(hp)
			s.emit(visible(shown) + "\t" + inRepo)
		}
	}
	for i, r := range rs {
		s.config(r.kind, r.at, tops[i])
		// A hook linked to a file a share holds: git runs that file, which
		// may be outside every name.
		if hookss[i] == "" {
			continue
		}
		hp, ok := Spelling(hookss[i])
		if !ok {
			continue
		}
		// As the shell's "$hp"/*: no dotfiles.
		ents, _ := os.ReadDir(hp)
		for _, e := range ents {
			f := hp + "/" + e.Name()
			if strings.HasPrefix(e.Name(), ".") || e.Type()&fs.ModeSymlink == 0 || strings.HasSuffix(f, ".sample") {
				continue
			}
			t, err := os.Readlink(f)
			if err != nil {
				continue
			}
			s.risk(risk{prefix: "hook " + e.Name() + " runs ", hops: s.hits(gitAbs(filepath.ToSlash(t), hp))})
		}
	}
	return &Result{Hooks: s.hooks, risks: s.risks}
}

// HooksName is the name that keeps the hooks folder rel read-only: its
// first component, which covers the folder and what it calls next to it
// (husky's hooks call .husky/<hook>). False for the project itself, and for
// a name the shares cannot carry.
func HooksName(rel string) (string, bool) {
	name, _, _ := strings.Cut(rel, "/")
	// Nothing JSON would escape on its way into Lima's config either.
	if rel == "." || name == "" || strings.ContainsAny(name, "\"\\\u2028\u2029") || strings.IndexFunc(name, unicode.IsControl) >= 0 || !utf8.ValidString(name) {
		return "", false
	}
	return name, true
}
