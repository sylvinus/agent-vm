// Package bashref gives the results of the bash implementation (0.2's
// agent-vm.sh and lib/), for tests that compare the Go code with it. They
// were recorded, before the bash version was removed, in each calling
// package's testdata/bashref: a test's calls must stay the ones recorded.
package bashref

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
)

// Root is the repository's root, where agent-vm.sh was.
func Root() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(file), "..", "..")
}

// Result of a bash function. Files holds the content of each file asked
// for that exists afterwards.
type Result struct {
	Stdout, Stderr string
	Code           int
	Files          map[string]string `json:",omitempty"`
}

// Cmd is a bash snippet, run after agent-vm.sh is sourced, with Args as
// "$@", from Dir (the repository's root when empty), with HOME in a
// temporary folder and Env added. Files are read once it has run.
type Cmd struct {
	Dir     string   `json:",omitempty"`
	Env     []string `json:",omitempty"`
	Stdin   string   `json:",omitempty"`
	Snippet string
	Args    []string `json:",omitempty"`
	Files   []string `json:",omitempty"`
}

// Run runs fn with args (see Cmd).
func Run(t testing.TB, dir string, env []string, fn string, args ...string) Result {
	t.Helper()
	return Exec(t, Cmd{Dir: dir, Env: env, Snippet: `"$@"`, Args: append([]string{fn}, args...)})
}

// Script runs snippet with args (see Cmd).
func Script(t testing.TB, dir string, env []string, snippet string, args ...string) Result {
	t.Helper()
	return Exec(t, Cmd{Dir: dir, Env: env, Snippet: snippet, Args: args})
}

// Exec gives c's result as recorded. Skipped on Windows, never compared
// there.
func Exec(t testing.TB, c Cmd) Result {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the bash reference is not compared on Windows")
	}
	if c.Dir == "" {
		c.Dir = Root()
	}
	c.Env = append([]string{"HOME=" + t.TempDir()}, c.Env...)
	return replay(t, c)
}

// A recorded call, its paths made portable (see paths).
type entry struct {
	Cmd    Cmd
	Result Result
}

// The JSON of an entry: strings that are not UTF-8 (JSON would replace
// their bytes) in base64.
type entryJSON struct {
	Dir, Stdin, Snippet str
	Env, Args, Files    []str
	Stdout, Stderr      str
	Code                int
	Out                 map[string]str `json:",omitempty"`
}

type str string

func (s *str) UnmarshalJSON(b []byte) error {
	var raw map[string][]byte
	if json.Unmarshal(b, &raw) == nil {
		*s = str(raw["base64"])
		return nil
	}
	return json.Unmarshal(b, (*string)(s))
}

func strs(in []str) []string {
	var out []string
	for _, s := range in {
		out = append(out, string(s))
	}
	return out
}

func (e *entry) UnmarshalJSON(b []byte) error {
	var j entryJSON
	if err := json.Unmarshal(b, &j); err != nil {
		return err
	}
	*e = entry{Cmd: Cmd{Dir: string(j.Dir), Stdin: string(j.Stdin), Snippet: string(j.Snippet),
		Env: strs(j.Env), Args: strs(j.Args), Files: strs(j.Files)},
		Result: Result{Stdout: string(j.Stdout), Stderr: string(j.Stderr), Code: j.Code}}
	for k, v := range j.Out {
		if e.Result.Files == nil {
			e.Result.Files = map[string]string{}
		}
		e.Result.Files[k] = string(v)
	}
	return nil
}

var (
	mu    sync.Mutex
	files = map[string]map[string][]entry{} // file, test name: calls
	calls = map[testing.TB]int{}
	// The package's folder: tests change theirs.
	pkgDir, _ = os.Getwd()
)

// fileOf is where t's calls are kept: one file per top-level test.
func fileOf(t testing.TB) string {
	top, _, _ := strings.Cut(t.Name(), "/")
	return filepath.Join(pkgDir, "testdata", "bashref", top+".json")
}

func load(path string) map[string][]entry {
	if m, ok := files[path]; ok {
		return m
	}
	m := map[string][]entry{}
	if b, err := os.ReadFile(path); err == nil {
		if err := json.Unmarshal(b, &m); err != nil {
			panic(fmt.Sprintf("%s: %v", path, err))
		}
	}
	files[path] = m
	return m
}

func replay(t testing.TB, c Cmd) Result {
	t.Helper()
	mu.Lock()
	path := fileOf(t)
	recorded := load(path)[t.Name()]
	n, seen := calls[t]
	if !seen {
		t.Cleanup(func() {
			mu.Lock()
			delete(calls, t)
			mu.Unlock()
		})
	}
	calls[t] = n + 1
	mu.Unlock()
	if n >= len(recorded) {
		t.Fatalf("%s: no bash result recorded for call %d of %s", path, n+1, t.Name())
	}
	p := newPaths()
	if now := p.cmd(c); !reflect.DeepEqual(now, recorded[n].Cmd) {
		t.Fatalf("%s: call %d of %s is not the recorded one:\n now:      %+v\n recorded: %+v", path, n+1, t.Name(), now, recorded[n].Cmd)
	}
	return p.result(recorded[n].Result)
}

// paths makes a call's paths portable: the repository is {ROOT}, a test's
// temporary folder {Ti}, i in order of appearance in the call, read back as
// the call spells it (macOS's /var or /private/var). The machine's PATH is
// left out. The output was recorded with the call's folders only: others
// under /tmp are not the test's (the guest's /tmp/...).
type paths struct {
	re    *regexp.Regexp
	dirs  []string // the folder's name under the temporary root
	spell []string // the root it has in the call
}

func newPaths() *paths {
	p := &paths{}
	var alts []string
	for _, r := range []string{os.TempDir(), evalOr(os.TempDir())} {
		if r = strings.TrimSuffix(r, "/"); !slices.Contains(alts, r) {
			alts = append(alts, r)
		}
	}
	slices.SortFunc(alts, func(a, b string) int { return len(b) - len(a) })
	for i := range alts {
		alts[i] = regexp.QuoteMeta(alts[i])
	}
	p.re = regexp.MustCompile(`(` + strings.Join(alts, "|") + `)/([^/\s'"=:,;\]\[{}]+)`)
	return p
}

func evalOr(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return p
}

// out makes s portable.
func (p *paths) out(s string) string {
	s = strings.ReplaceAll(s, Root(), "{ROOT}")
	return p.re.ReplaceAllStringFunc(s, func(m string) string {
		sub := p.re.FindStringSubmatch(m)
		i := slices.Index(p.dirs, sub[2])
		if i < 0 {
			i = len(p.dirs)
			p.dirs = append(p.dirs, sub[2])
			p.spell = append(p.spell, sub[1])
		}
		return fmt.Sprintf("{T%d}", i)
	})
}

var placeholder = regexp.MustCompile(`\{T\d+\}`)

// in is out undone, for this call's folders.
func (p *paths) in(s string) string {
	s = placeholder.ReplaceAllStringFunc(s, func(m string) string {
		var i int
		fmt.Sscanf(m, "{T%d}", &i)
		if i >= len(p.dirs) {
			return m
		}
		return p.spell[i] + "/" + p.dirs[i]
	})
	return strings.ReplaceAll(s, "{ROOT}", Root())
}

func (p *paths) cmd(c Cmd) Cmd {
	o := Cmd{Dir: p.out(c.Dir), Stdin: p.out(c.Stdin), Snippet: p.out(c.Snippet)}
	for _, e := range c.Env {
		if k, v, ok := strings.Cut(e, "="); ok && k == "PATH" {
			e = "PATH=" + strings.TrimSuffix(strings.TrimSuffix(v, os.Getenv("PATH")), ":")
		}
		o.Env = append(o.Env, p.out(e))
	}
	for _, a := range c.Args {
		o.Args = append(o.Args, p.out(a))
	}
	for _, f := range c.Files {
		o.Files = append(o.Files, p.out(f))
	}
	return o
}

// result is a recorded result, with this call's paths.
func (p *paths) result(r Result) Result {
	o := Result{Stdout: p.in(r.Stdout), Stderr: p.in(r.Stderr), Code: r.Code}
	for k, v := range r.Files {
		if o.Files == nil {
			o.Files = map[string]string{}
		}
		o.Files[p.in(k)] = p.in(v)
	}
	return o
}
