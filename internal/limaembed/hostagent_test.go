package limaembed

import (
	"os"
	"strings"
	"testing"
)

// The copy of limactl's hostagent command differs from it only as its
// header says: after a Lima upgrade, copy it again.
func TestHostagentCopy(t *testing.T) {
	upstream, err := os.ReadFile("../../third_party/lima/cmd/limactl/hostagent.go")
	if err != nil {
		t.Fatal(err)
	}
	ours, err := os.ReadFile("hostagent.go")
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Replace(string(upstream), "package main", "package limaembed", 1)
	want = strings.Replace(want, "WrapArgsError(cobra.ExactArgs(1))", "cobra.ExactArgs(1)", 1)
	// Our header: the comment block after the license lines.
	got := string(ours)
	start := strings.Index(got, "// Copied from")
	end := strings.Index(got, "package limaembed")
	if start < 0 || end < start {
		t.Fatal("hostagent.go lost its header")
	}
	got = got[:start] + got[end:]
	if got != want {
		t.Error("hostagent.go differs from third_party/lima/cmd/limactl/hostagent.go beyond its header: copy it again")
	}
}
