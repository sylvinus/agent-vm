// Package env reads and writes agent-vm's env files, ~/.agent-vm/env and a
// project's .agent-vm.env, which the VM's shell sources: without ever running
// a shell on the host, since the VM can write the project's.
package env

import (
	"regexp"
	"strings"
)

// SQEscape makes s safe inside a single-quoted shell literal: ' becomes
// '"'"'.
func SQEscape(s string) string {
	return strings.ReplaceAll(s, "'", `'"'"'`)
}

// Status of a read.
const (
	Found    = 0
	NotFound = 1
	// Refused: the file uses syntax this reader does not interpret, and no
	// key can be answered.
	Refused = 3
)

// records splits content as awk reads lines: a last line without a newline
// is one too.
func records(content string) []string {
	if content == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(content, "\n"), "\n")
}

var (
	leadingBlank = regexp.MustCompile(`^[ \t]+`)
	exportPrefix = regexp.MustCompile(`^export[ \t]+`)
	assignment   = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=`)
	blankOrNote  = regexp.MustCompile(`^(#.*)?$`) // CRs already dropped (Lookup)
	restOK       = regexp.MustCompile(`^[ \t]+(#.*)?$`)
)

// Lookup is the value content assigns to key, as a shell sourcing it would,
// without a shell. Accepted: an optional `export `, then single-quoted parts
// (which may span lines, as Set writes a value with a newline), double-quoted
// parts with nothing to expand, and bare characters other than
// $ ` \ ; & | < > ( ) ~, then an optional `# comment`. The last assignment
// wins. One line refused, and no key is answered: a quote left open or a
// trailing backslash makes the shell read the next lines into that value,
// and other syntax can run anything, an assignment to any key included. A
// line that is not an assignment, a comment or blank counts as refused.
func Lookup(content, key string) (string, int) {
	// As the VM sources it: the CR ending each line dropped (StripCR),
	// inside a quoted value too.
	lines := records(StripCR(content))
	found := false
	val := ""
	for i := 0; i < len(lines); i++ {
		line := leadingBlank.ReplaceAllString(lines[i], "")
		if blankOrNote.MatchString(line) {
			continue
		}
		line = exportPrefix.ReplaceAllString(line, "")
		if !assignment.MatchString(line) {
			return "", Refused
		}
		eq := strings.IndexByte(line, '=')
		v, st, used := parseValue(line[eq+1:], lines[i+1:])
		i += used
		if st != Found {
			return "", Refused
		}
		if line[:eq] == key {
			found, val = true, v
		}
	}
	if !found {
		return "", NotFound
	}
	return val, Found
}

// parseValue reads the value s starts, taking from more the lines a
// single-quoted part goes on to; used is how many.
func parseValue(s string, more []string) (v string, st, used int) {
	for s != "" {
		switch c := s[0]; {
		case c == '\'':
			s = s[1:]
			for {
				e := strings.IndexByte(s, '\'')
				if e >= 0 {
					v += s[:e]
					s = s[e+1:]
					break
				}
				if used == len(more) {
					return v, Refused, used
				}
				v += s + "\n"
				s = more[used]
				used++
			}
		case c == '"':
			s = s[1:]
			e := strings.IndexByte(s, '"')
			if e < 0 || strings.ContainsAny(s[:e], "$`\\") {
				return v, Refused, used
			}
			v += s[:e]
			s = s[e+1:]
		case c == ' ' || c == '\t':
			if restOK.MatchString(s) {
				return v, Found, used
			}
			return v, Refused, used
		case strings.IndexByte("$`\\;&|<>()~\r", c) >= 0:
			return v, Refused, used
		default:
			v += s[:1] // the byte, not string(c), which would encode it as a rune
			s = s[1:]
		}
	}
	return v, Found, used
}

var nameAssign = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=`)

// Names is every name content assigns, once per assignment, in order.
func Names(content string) []string {
	var names []string
	walk(content, func(_ string, name string) { names = append(names, name) }, nil)
	return names
}

// Drop is content without key's assignments, whole: a value Set wrote over
// several lines goes with its first line. Each line keeps its newline.
func Drop(content, key string) string {
	var b strings.Builder
	walk(content, nil, func(line, name string) {
		if name != key {
			b.WriteString(line + "\n")
		}
	})
	return b.String()
}

// walk calls name for each assignment, and line for each line with the name
// of the assignment it belongs to ("" for none). A line inside a quoted value
// is never read as an assignment: it is data.
func walk(content string, name func(line, name string), line func(line, name string)) {
	q := byte(0) // the open quote: ', ", or $ for $'...'
	cur := ""
	scan := func(s string) {
		for i := 0; i < len(s); i++ {
			c := s[i]
			switch q {
			case '\'':
				if c == '\'' {
					q = 0
				}
				continue
			case '$':
				if c == '\\' {
					i++
				} else if c == '\'' {
					q = 0
				}
				continue
			case '"':
				if c == '\\' {
					i++
				} else if c == '"' {
					q = 0
				}
				continue
			}
			switch {
			case c == '\\':
				i++
			case c == '$' && i+1 < len(s) && s[i+1] == '\'':
				q = '$'
				i++
			case c == '\'' || c == '"':
				q = c
			case c == '#' && i > 0 && (s[i-1] == ' ' || s[i-1] == '\t'):
				return
			}
		}
	}
	for _, l := range records(content) {
		if q != 0 {
			scan(l)
			if line != nil {
				line(l, cur)
			}
			continue
		}
		cur = ""
		t := exportPrefix.ReplaceAllString(leadingBlank.ReplaceAllString(l, ""), "")
		if m := nameAssign.FindString(t); m != "" {
			cur = m[:len(m)-1]
			if name != nil {
				name(l, cur)
			}
			scan(t[len(m):])
		}
		if line != nil {
			line(l, cur)
		}
	}
}
