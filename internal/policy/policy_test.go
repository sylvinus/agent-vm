package policy

import (
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCurrentWriteRead(t *testing.T) {
	st := t.TempDir()
	os.WriteFile(filepath.Join(st, "network"), []byte("allow 10.0.0.5:8080 # a\nallow 192.168.1.0/24\nallow localhost:11434\ndomain Example.com\n"), 0o644)
	os.WriteFile(filepath.Join(st, "guarded"), []byte("Makefile\n!.envrc\n"), 0o644)
	t.Setenv("AGENT_VM_GUARDED_WRITES", "deny")
	t.Setenv("AGENT_VM_UNSAFE_OPEN_NETWORK", "")

	f, err := Current(st, "agent-vm")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "vm", "policy.json")
	if err := Write(path, f); err != nil {
		t.Fatal(err)
	}
	if ents, _ := os.ReadDir(filepath.Dir(path)); len(ents) != 1 {
		t.Errorf("left behind: %v", ents)
	}
	got, err := Read(path)
	if err != nil {
		t.Fatal(err)
	}
	if got.Fingerprint() != f.Fingerprint() || got.App != "agent-vm" || !got.Guarded.Deny {
		t.Errorf("round trip: %+v", got)
	}
	// What the hostagent decides with is what was written.
	if !got.Network.Allows("tcp", netip.MustParseAddrPort("10.0.0.5:8080")) || got.Network.Allows("tcp", netip.MustParseAddrPort("10.0.0.5:22")) ||
		!got.Network.Allows("tcp", netip.MustParseAddrPort("127.0.0.1:11434")) || !got.Network.Name("a.example.com") || got.Network.Name("other.org") {
		t.Errorf("network: %+v", got.Network)
	}
	if _, ok := got.Guarded.Paths["Makefile"]; !ok {
		t.Error("user's guarded path lost")
	}
	if _, ok := got.Guarded.Paths[".envrc"]; ok {
		t.Error("removed default kept")
	}
	if _, ok := got.Guarded.Paths[".vscode/tasks.json"]; !ok {
		t.Error("default lost")
	}
}

func TestFingerprint(t *testing.T) {
	st := t.TempDir()
	write := func(network string) string {
		os.WriteFile(filepath.Join(st, "network"), []byte(network), 0o644)
		f, err := Current(st, "agent-vm")
		if err != nil {
			t.Fatal(err)
		}
		return f.Fingerprint()
	}
	a := write("allow 10.0.0.1\nallow 10.0.0.2\n")
	if write("# c\nallow 10.0.0.2\nallow 10.0.0.1  # x\n") != a {
		t.Error("order or comments changed it")
	}
	if write("allow 10.0.0.1\n") == a {
		t.Error("a rule less, the same")
	}
	if write("allow 10.0.0.1\nallow 10.0.0.2\ndomain a.org\n") == a {
		t.Error("a domain more, the same")
	}
	t.Setenv("AGENT_VM_UNSAFE_OPEN_NETWORK", "1")
	if write("allow 10.0.0.1\nallow 10.0.0.2\n") == a {
		t.Error("open network, the same")
	}
}

func TestReadRefuses(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "policy.json")
	if _, err := Read(p); !os.IsNotExist(err) {
		t.Errorf("missing: %v", err)
	}
	for body, want := range map[string]string{
		"{":                         "policy.json",
		`{"schema":2,"network":{}}`: "schema 2",
		`{"schema":1}`:              "no network policy",
		`{"schema":1,"network":{"allow":[{"net":"nope"}]}}`: "policy.json",
	} {
		os.WriteFile(p, []byte(body), 0o644)
		if _, err := Read(p); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: %v", body, err)
		}
	}
}
