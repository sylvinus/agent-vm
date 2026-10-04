package env

import (
	"math/rand"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/bashref"
)

var corpus = []string{
	"",
	"A=1\n",
	"A=1",
	"export A=1\nB=2\n",
	"  export   A='x y'\n",
	"A='multi\nline\nB=inside'\nB=2\n",
	"A='open\nB=2\n",
	"A=\"plain\"\nB=\"$HOME\"\n",
	"A=x # comment\nB=y#notcomment\n",
	"A=x;rm -rf /\n",
	"A=$(id)\n",
	"A=$HOME\n",
	"B=1\nA=x$y\n",
	"A=~/x\n",
	"# just a comment\n\n   \nA=1\r\nB='crlf'\r\n",
	"A=1\nA=2\n",
	"A='it'\"'\"'s'\n",
	"not an assignment\nA=1\n",
	"A=x\\\ny\n",
	"A= 1\n",
	"A=\tB\n",
	"1A=x\n",
	"A=x y\n",
	"A='x' # c\n",
	"A=$'esc\\'aped'\nB=after\n",
	"A=\"dq \\\" esc\"\nB=after\n",
	"A='a'\"b\"c\n",
	"export\tA=1\nexport B\n",
	"A=x # ' not a quote\nB=1\n",
	"A='x # not a comment'\nB=1\n",
	"A=café\nB='naïve'\n",
	"A=\x92\xff\n",
}

func bashRead(t *testing.T, content, key string) (string, int) {
	r := bashref.Script(t, "", nil, `printf '%s' "$1" | _agent_vm_env_read - "$2"`, content, key)
	return r.Stdout, r.Code
}

func TestReadBash(t *testing.T) {
	for _, c := range corpus {
		for _, k := range []string{"A", "B", "C"} {
			v, st := Lookup(c, k)
			bv, bst := bashRead(t, c, k)
			if v != bv || st != bst {
				t.Errorf("Read(%q, %s) = %q %d, bash %q %d", c, k, v, st, bv, bst)
			}
		}
	}
}

func TestNamesDropBash(t *testing.T) {
	for _, c := range corpus {
		r := bashref.Script(t, "", nil, `printf '%s' "$1" | _agent_vm_env_lines list -`, c)
		if got := strings.Join(Names(c), "\n"); got != strings.TrimSuffix(r.Stdout, "\n") {
			t.Errorf("Names(%q) = %q, bash %q", c, got, r.Stdout)
		}
		for _, k := range []string{"A", "B"} {
			r := bashref.Script(t, "", nil, `printf '%s' "$1" | _agent_vm_env_lines drop - "$2"`, c, k)
			if got := Drop(c, k); got != r.Stdout {
				t.Errorf("Drop(%q, %s) = %q, bash %q", c, k, got, r.Stdout)
			}
		}
	}
}

// Random files of the characters that matter, against bash.
func TestReadBashRandom(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}
	alphabet := []string{"A=", "B=", "export ", "'", "\"", "$", "\\", "#", " ", "\t", "\n", "x", ";", "\r", "~", "$'", "="}
	rnd := rand.New(rand.NewSource(1))
	for n := 0; n < 300; n++ {
		var b strings.Builder
		for i := rnd.Intn(14); i >= 0; i-- {
			b.WriteString(alphabet[rnd.Intn(len(alphabet))])
		}
		c := b.String()
		v, st := Lookup(c, "A")
		bv, bst := bashRead(t, c, "A")
		if v != bv || st != bst {
			t.Errorf("Read(%q, A) = %q %d, bash %q %d", c, v, st, bv, bst)
		}
		r := bashref.Script(t, "", nil, `printf '%s' "$1" | _agent_vm_env_lines drop - A`, c)
		if got := Drop(c, "A"); got != r.Stdout {
			t.Errorf("Drop(%q, A) = %q, bash %q", c, got, r.Stdout)
		}
	}
}

func TestSQEscapeBash(t *testing.T) {
	for _, s := range []string{"", "plain", "O'Brien", "''", "a'b'c", "new\nline"} {
		r := bashref.Run(t, "", nil, "_agent_vm_sq_escape", s)
		if SQEscape(s) != r.Stdout {
			t.Errorf("SQEscape(%q) = %q, bash %q", s, SQEscape(s), r.Stdout)
		}
	}
}
