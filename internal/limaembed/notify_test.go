package limaembed

import (
	"bytes"
	"strings"
	"testing"
)

// Events pass through as written; a forwarded port, or one refused because
// the host uses it, is told, once each.
func TestEventWatch(t *testing.T) {
	var out bytes.Buffer
	var told []string
	e := newEventWatch(&out, "proj-1a2b3c4d")
	e.notify = func(title, msg string) { told = append(told, title+": "+msg) }
	in := `{"status":{"running":true}}
{"status":{"portForward":{"type":"forwarding","protocol":"tcp","guestAddr":"127.0.0.1:5173","hostAddr":"127.0.0.1:5173"}}}
{"status":{"portForward":{"type":"failed","protocol":"tcp","guestAddr":"127.0.0.1:5432","hostAddr":"127.0.0.1:5432","error":"in use"}}}
{"status":{"portForward":{"type":"forwarding","hostAddr":"not an address"}}}
`
	// Split across writes, as a pipe may.
	e.Write([]byte(in[:40]))
	e.Write([]byte(in[40:]))
	if out.String() != in {
		t.Errorf("events changed: %q", out.String())
	}
	want := "agent-vm: proj-1a2b3c4d: The VM now serves 127.0.0.1:5173 on this machine.\n" +
		"agent-vm: proj-1a2b3c4d: Not forwarded: 127.0.0.1:5432 is in use on this machine."
	if strings.Join(told, "\n") != want {
		t.Errorf("told:\n%s", strings.Join(told, "\n"))
	}
}
