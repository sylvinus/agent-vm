//go:build linux || darwin || windows

package reversesshfs

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"
)

var sameNameSeeds = [][2]string{
	{".git", ".GIT"},
	{".git", ".g" + zwnj + "it"},
	{".git", bom + ".git"},
	{"café", "café"},
	{"glass", "glaß"},
	{"k", "K"},
	{"hooks", "HOOKS"},
	{".husky", ".Husky"},
	{"tools", "toòls"},
}

// Whatever the host's file system takes as the same entry, sameName must
// too: otherwise the client writes a read-only name under another spelling.
// The file system decides: on a case-sensitive one, only identical names
// meet; on macOS and Windows, case, normalization and ignored code points.
func FuzzSameNameFS(f *testing.F) {
	for _, s := range sameNameSeeds {
		f.Add(s[0], s[1])
	}
	dir := f.TempDir()
	f.Fuzz(func(t *testing.T, name, other string) {
		if !utf8.ValidString(name) || !utf8.ValidString(other) || !plainName(name) || !plainName(other) {
			return
		}
		d, err := os.MkdirTemp(dir, "")
		if err != nil {
			t.Fatal(err)
		}
		defer os.RemoveAll(d)
		if err := os.Mkdir(filepath.Join(d, name), 0o755); err != nil {
			return // a name this file system refuses
		}
		a, err := os.Stat(filepath.Join(d, name))
		if err != nil {
			t.Fatal(err)
		}
		b, err := os.Stat(filepath.Join(d, other))
		if err != nil || !os.SameFile(a, b) {
			return
		}
		if !sameName(other, name) {
			t.Errorf("%q opens %q on this file system, and sameName says it does not", other, name)
		}
	})
}

// A name in one path component, which the file system takes as itself.
func plainName(s string) bool {
	return s != "" && s != "." && s != ".." && len(s) < 200 && !strings.ContainsAny(s, "/\\:\x00") &&
		!strings.HasSuffix(s, ".") && !strings.HasSuffix(s, " ")
}

// FuzzRootedOps plays a hostile client: any sequence of requests, on paths
// made of "..", symlinks, absolute paths and spellings of .git. Whatever it
// sends, nothing outside the root changes or is read, and .git stays as it
// was.
func FuzzRootedOps(f *testing.F) {
	for _, seed := range [][]byte{
		{0, 3, 1, 2, 5}, // write .git/config
		{5, 9, 0, 4, 7, 2, 6, 0},
		{6, 2, 2, 3, 1, 0, 0, 9, 3},
		{7, 8, 10, 0, 12, 1, 1, 0},
		{3, 9, 2, 0, 0, 11, 10, 0, 0, 13},
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, ops []byte) {
		if len(ops) > 64 {
			return
		}
		c, root := setupRooted(t, false)
		secretDir := filepath.Join(filepath.Dir(root), "secret-dir")
		if err := os.MkdirAll(secretDir, 0o755); err != nil {
			t.Fatal(err)
		}
		// Told apart by its size: the client writes 3 bytes at a time.
		secret := strings.Repeat("SECRET", 200)[:1000]
		if err := os.WriteFile(filepath.Join(secretDir, "s"), []byte(secret), 0o644); err != nil {
			t.Fatal(err)
		}
		comps := []string{"", ".", "..", ".git", ".GIT", ".g" + zwnj + "it", "hooks", "config", "src", "gitlink", "configlink", "outside", "secret-dir", "s", "x"}
		bases := []string{"", root + "/", "/", filepath.Dir(root) + "/"}
		next := func() byte {
			if len(ops) == 0 {
				return 0
			}
			b := ops[0]
			ops = ops[1:]
			return b
		}
		pathOf := func() string {
			b := next()
			p := bases[int(b>>4)%len(bases)]
			for i := 0; i <= int(b&3); i++ {
				if i > 0 {
					p += "/"
				}
				p += comps[int(next())%len(comps)]
			}
			if p == "" {
				p = "."
			}
			return p
		}
		seen := func(b []byte) {
			if strings.Contains(string(b), "SECRET") {
				t.Fatalf("read a file outside the root: %q", b)
			}
		}
		for len(ops) > 0 {
			switch next() % 13 {
			case 0:
				if fh, err := c.OpenFile(pathOf(), os.O_WRONLY|os.O_CREATE|os.O_TRUNC); err == nil {
					fh.Write([]byte("PWN"))
					fh.Close()
				}
			case 1:
				if fh, err := c.OpenFile(pathOf(), os.O_WRONLY|os.O_APPEND); err == nil {
					fh.Write([]byte("PWN"))
					fh.Close()
				}
			case 2:
				if fh, err := c.Open(pathOf()); err == nil {
					b, _ := io.ReadAll(fh)
					fh.Close()
					seen(b)
				}
			case 3:
				c.Mkdir(pathOf())
			case 4:
				c.Remove(pathOf())
			case 5:
				c.PosixRename(pathOf(), pathOf())
			case 6:
				c.Rename(pathOf(), pathOf())
			case 7:
				c.Symlink(pathOf(), pathOf())
			case 8:
				c.Link(pathOf(), pathOf())
			case 9:
				c.Chmod(pathOf(), 0o777)
			case 10:
				c.Truncate(pathOf(), 0)
			case 11:
				if ents, err := c.ReadDir(pathOf()); err == nil {
					for _, e := range ents {
						if e.Size() == int64(len(secret)) {
							t.Fatalf("listed a folder outside the root")
						}
					}
				}
			case 12:
				if l, err := c.ReadLink(pathOf()); err == nil {
					seen([]byte(l))
				}
			}
		}
		assertUnchanged(t, root)
		if b, err := os.ReadFile(filepath.Join(secretDir, "s")); err != nil || string(b) != secret {
			t.Fatalf("secret-dir/s changed: %q, %v", b, err)
		}
		if ents, err := os.ReadDir(secretDir); err != nil || len(ents) != 1 {
			t.Fatalf("secret-dir changed: %v, %v", ents, err)
		}
	})
}

// agent-vm decides which names to give from strings.EqualFold: every name it
// takes as the same, the server must take as the same too.
func FuzzSameNameEqualFold(f *testing.F) {
	for _, s := range sameNameSeeds {
		f.Add(s[0], s[1])
	}
	f.Fuzz(func(t *testing.T, a, b string) {
		if strings.EqualFold(a, b) && !sameName(a, b) {
			t.Errorf("EqualFold(%q, %q), and sameName says they differ", a, b)
		}
		if sameName(a, b) != sameName(b, a) {
			t.Errorf("sameName(%q, %q) is not symmetric", a, b)
		}
	})
}
