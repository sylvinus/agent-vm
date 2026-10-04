package mounts

import (
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/sylvinus/agent-vm/internal/env"
	"github.com/sylvinus/agent-vm/internal/paths"
)

// Entry is a usable line of ~/.agent-vm/volumes.
type Entry struct {
	Src  string // ~ expanded, existing
	Dst  string // absolute and normalized, relative as written, or "" for Src's own path
	Mode string // "ro" or "rw"
	Line string // source:destination:mode, for messages
}

// Entries are the entries of the volumes file for the project dir:
// source[:destination][:ro|rw[:project]], ro by default. One that cannot be
// used is skipped, with a warning on warn. Nothing is created here.
func Entries(file, dir, home string, refs []Ref, warn io.Writer) []Entry {
	b, err := os.ReadFile(file)
	if err != nil {
		return nil
	}
	w := func(format string, a ...any) { fmt.Fprintf(warn, "Warning: "+format+"\n", a...) }
	// Mount points are guest paths: the project's is its own path, as
	// paths.Guest spells it (/c/Users/me/proj on Windows).
	guestDir := paths.Guest(dir)
	projMP := paths.Join("/", guestDir)
	seen := map[string]bool{}
	var out []Entry
	content := string(b)
	for _, raw := range strings.Split(strings.TrimSuffix(content, "\n"), "\n") {
		if content == "" {
			break
		}
		line, _, _ := strings.Cut(raw, "#")
		line = strings.TrimFunc(line, isSpace)
		if line == "" {
			continue
		}
		// A control character is invalid unescaped in the mounts; the CR of a
		// CRLF file went with the trim above.
		if strings.IndexFunc(line, unicode.IsControl) >= 0 {
			w("Mount entry '%s' (from ~/.agent-vm/volumes) contains a control character, skipping.", raw)
			continue
		}
		line = hideDrives(line)
		// After an explicit mode, a 4th field limits the entry to the
		// projects it matches. An empty one is refused, not read as "no
		// filter": an entry meant for one project would go in every one.
		if before := line[:max(strings.LastIndexByte(line, ':'), 0)]; strings.Contains(line, ":") && (strings.HasSuffix(before, ":ro") || strings.HasSuffix(before, ":rw")) {
			filter := showDrives(line[strings.LastIndexByte(line, ':')+1:])
			line = before
			if filter == "" {
				w("Mount entry '%s' (from ~/.agent-vm/volumes) has an empty project filter; refusing to mount it in every project. Skipping.", raw)
				continue
			}
			if !Matches(filter, dir, home, warn) {
				continue
			}
		}
		src, dst, mode, entry := line, "", "ro", showDrives(line)
		if strings.HasSuffix(line, ":ro") || strings.HasSuffix(line, ":rw") {
			mode = line[len(line)-2:]
			line = line[:len(line)-3]
		}
		if s, d, ok := strings.Cut(line, ":"); ok {
			src, dst = s, d
		} else {
			src = line
		}
		// On Windows: C:\x as C:/x, and 0.2's Git Bash spelling, /c/x, as C:/x.
		src, dst = paths.FromGitBash(paths.Host(showDrives(src))), showDrives(dst)
		// A ':' left in the destination is a field out of place: read as a
		// destination, the entry would go in every project, its filter lost.
		if strings.Contains(dst, ":") {
			w("Mount entry '%s' (from ~/.agent-vm/volumes) does not read as source:destination:mode:project (the mode goes before the project, and is needed with one). Skipping.", raw)
			continue
		}
		if strings.HasPrefix(src, "~") {
			src = home + src[1:]
		}
		if strings.ContainsAny(src, "\"\\\n|") || strings.ContainsAny(dst, "\"\\\n|") {
			w("Mount entry '%s' (from ~/.agent-vm/volumes) contains invalid characters (quote/backslash/newline/pipe), skipping.", raw)
			continue
		}
		if why, bad := Unwritable(src + dst); bad {
			w("Mount entry '%s' (from ~/.agent-vm/volumes) %s, skipping.", raw, why)
			continue
		}
		if _, err := os.Stat(src); err != nil {
			w("Mount path '%s' (from ~/.agent-vm/volumes) does not exist, skipping.", src)
			continue
		}
		// Refused as a project, refused as a volume; a repository's own
		// folder only when the VM could write it.
		why, bad := UnsafeLocation(src, refs)
		if !bad && mode == "rw" && isDir(src) {
			why, bad = GitDirShare(src)
		}
		if bad {
			w("Mount path '%s' (from ~/.agent-vm/volumes) %s, skipping.", src, why)
			continue
		}
		// Where the VM sees it. At the project or above it, it would hide
		// the project; at another entry's place, Lima would merge the two
		// into one share, with the second one's mode.
		mp := dst
		if mp == "" {
			mp = paths.Guest(src)
		}
		if !strings.HasPrefix(mp, "/") {
			mp = guestDir + "/" + mp
		}
		mp = paths.Join("/", mp)
		if strings.HasPrefix(dst, "/") {
			dst = mp
		}
		if strings.HasPrefix(strings.TrimSuffix(projMP, "/")+"/", strings.TrimSuffix(mp, "/")+"/") {
			w("Mount entry '%s' (from ~/.agent-vm/volumes) would be mounted at %s, which covers the project, skipping.", entry, mp)
			continue
		}
		if seen[mp] {
			w("Mount entry '%s' (from ~/.agent-vm/volumes) would be mounted at %s, as an entry before it, skipping.", entry, mp)
			continue
		}
		seen[mp] = true
		out = append(out, Entry{Src: src, Dst: dst, Mode: mode, Line: entry})
	}
	return out
}

// driveColon stands for a drive's colon (C:/) while a line is cut at its
// other colons: control characters are refused before.
const driveColon = "\x01"

// hideDrives is line with, on Windows, the colon of each field starting
// with a drive (C:/x, C:\x) made driveColon; line as is elsewhere.
func hideDrives(line string) string {
	if !paths.Windows() {
		return line
	}
	var b strings.Builder
	for i := 0; i < len(line); i++ {
		if line[i] == ':' && i >= 1 && ('a' <= line[i-1]|0x20 && line[i-1]|0x20 <= 'z') && (i == 1 || line[i-2] == ':') &&
			i+1 < len(line) && (line[i+1] == '/' || line[i+1] == '\\') {
			b.WriteString(driveColon)
			continue
		}
		b.WriteByte(line[i])
	}
	return b.String()
}

// showDrives undoes hideDrives.
func showDrives(s string) string { return strings.ReplaceAll(s, driveColon, ":") }

// RWDirs are the folders of entries the VM can write besides the project:
// shares that are rw and directories.
func RWDirs(entries []Entry) []string {
	var out []string
	for _, e := range entries {
		if e.Mode == "rw" && isDir(e.Src) {
			out = append(out, e.Src)
		}
	}
	return out
}

// isSpace is what the shell's [[:space:]] trims.
func isSpace(r rune) bool {
	return r == ' ' || r == '\t' || r == '\n' || r == '\r' || r == '\v' || r == '\f'
}

// Matches reports whether the project dir matches filter, the 4th field of
// a volumes entry: a path, ~ expanded, where * matches anything, / included
// (and ? and [...] as the shell has them). A filter that is not absolute
// matches nothing, with a warning; ~user is not expanded.
func Matches(filter, dir, home string, warn io.Writer) bool {
	orig := filter
	if filter == "~" || strings.HasPrefix(filter, "~/") {
		filter = home + filter[1:]
	}
	// On Windows, C:\x as C:/x (a backslash is no escape there), and 0.2's
	// /c/x as C:/x.
	filter = paths.FromGitBash(paths.Host(filter))
	if filter != paths.Root(filter) {
		filter = strings.TrimSuffix(filter, "/")
	}
	if !paths.IsAbs(filter) {
		fmt.Fprintf(warn, "Warning: Project filter '%s' (from ~/.agent-vm/volumes) is not an absolute path, skipping the entry.\n", orig)
		return false
	}
	re, err := globRe(filter)
	return err == nil && re.MatchString(dir)
}

// literal writes the first character of s, quoted, and says how many bytes
// it took: the whole character, as string(byte) would not (é is two).
// regexp reads an invalid byte as U+FFFD, in the pattern as in the path.
func literal(b *strings.Builder, s string) int {
	r, n := utf8.DecodeRuneInString(s)
	if r == utf8.RuneError && n == 1 {
		b.WriteString(`\x{FFFD}`)
	} else {
		b.WriteString(regexp.QuoteMeta(s[:n]))
	}
	return n
}

// globRe is a shell pattern as a regexp: * anything, / included, ? one
// character, [...] a class ([!...] or [^...] negated).
func globRe(p string) (*regexp.Regexp, error) {
	var b strings.Builder
	b.WriteString(`^`)
	for i := 0; i < len(p); i++ {
		switch c := p[i]; c {
		case '*':
			b.WriteString(`.*`)
		case '?':
			b.WriteString(`.`)
		case '[':
			j := i + 1
			if j < len(p) && (p[j] == '!' || p[j] == '^') {
				j++
			}
			if j < len(p) && p[j] == ']' {
				j++
			}
			for j < len(p) && p[j] != ']' {
				j++
			}
			if j >= len(p) {
				b.WriteString(`\[`)
				continue
			}
			class := p[i+1 : j]
			if class[0] == '!' {
				class = "^" + class[1:]
			}
			b.WriteString("[" + strings.ReplaceAll(class, `\`, `\\`) + "]")
			i = j
		case '\\':
			if i+1 < len(p) {
				i += literal(&b, p[i+1:])
			} else {
				b.WriteString(`\\`)
			}
		default:
			i += literal(&b, p[i:]) - 1
		}
	}
	b.WriteString(`$`)
	return regexp.Compile(b.String())
}

// ProjectMountpoint makes, on the host, the mount point of a relative
// destination rel, inside the project dir: a folder, or an empty file for a
// file source src. virtiofs and 9p make mount points before the project is
// mounted, and --readonly refuses the guest's write. No component may be
// ".." or a symlink: the agent can write the project. Made without following
// links (env.MkdirIn), since the VM could swap one in after the check.
func ProjectMountpoint(dir, rel, src string, warn io.Writer) (string, bool) {
	w := func(format string, a ...any) { fmt.Fprintf(warn, "Warning: "+format+"\n", a...) }
	p, norm := dir, ""
	for _, comp := range strings.Split(rel, "/") {
		if comp == "" || comp == "." {
			continue
		}
		if comp == ".." {
			w("Mount destination '%s' (from ~/.agent-vm/volumes) goes out of the project with '..', skipping.", rel)
			return "", false
		}
		p += "/" + comp
		if norm != "" {
			norm += "/"
		}
		norm += comp
		if fi, err := os.Lstat(p); err == nil && fi.Mode()&os.ModeSymlink != 0 {
			w("Mount destination '%s' (from ~/.agent-vm/volumes) goes through a symlink in the project (%s), skipping.", rel, p)
			return "", false
		}
	}
	if p == dir {
		w("Mount destination '%s' (from ~/.agent-vm/volumes) is the project itself, skipping.", rel)
		return "", false
	}
	kind, err := "file", error(nil)
	if isDir(src) {
		kind, err = "directory", env.MkdirIn(dir, norm)
	} else {
		err = env.TouchIn(dir, norm)
	}
	switch {
	case err == nil:
		return p, true
	case err == env.ErrUnsafe:
		w("Mount destination '%s' (from ~/.agent-vm/volumes) goes through a symlink in the project, or is not a %s there, skipping.", rel, kind)
	default:
		w("Cannot create the mount point '%s' (from ~/.agent-vm/volumes), skipping.", p)
	}
	return "", false
}
