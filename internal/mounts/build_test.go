package mounts

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/bashref"
	"github.com/sylvinus/agent-vm/internal/vm"
)

func TestBuildBash(t *testing.T) {
	for _, writable := range []bool{true, false} {
		for _, cache := range []string{"", "1"} {
			var gs, bs sandbox
			for _, s := range []*sandbox{&gs, &bs} {
				*s = newSandbox(t)
				os.WriteFile(filepath.Join(s.state, "volumes"), []byte(strings.Join([]string{
					s.root + "/data/a:/mnt/a:rw",
					s.root + "/data/b",
					s.root + "/data/file.txt:/etc/f.txt",
					s.root + "/data/file.txt:/etc/g.txt:rw",
					s.root + "/data/a:sub/inside:ro",
				}, "\n")+"\n"), 0o644)
			}
			t.Setenv("AGENT_VM_SSHFS_CACHE", cache)
			var warn bytes.Buffer
			mounts, files := Build(Shares{
				VM: "t-00000000", Dir: gs.proj, Writable: writable, Names: []string{".git", ".hg"},
				Entries: Entries(filepath.Join(gs.state, "volumes"), gs.proj, gs.home, gs.refs(), &warn), StateDir: gs.state, Warn: &warn,
			})
			w := "true"
			if !writable {
				w = "false"
			}
			r := bashref.Script(t, "", []string{"HOME=" + bs.home, "AGENT_VM_STATE_DIR=" + bs.state, "AGENT_VM_SSHFS_CACHE=" + cache},
				`_agent_vm_build_mounts_json t-00000000 "$1" "$2" '[".git", ".hg"]'; echo; cat "$AGENT_VM_STATE_DIR/.agent-vm-file-mounts-t-00000000"`, bs.proj, w)
			jsonPart, cached, _ := strings.Cut(r.Stdout, "\n")
			var want []vm.Mount
			if err := json.Unmarshal([]byte(jsonPart), &want); err != nil {
				t.Fatalf("bash JSON %q: %v", jsonPart, err)
			}
			norm := func(ms []vm.Mount, root string) []vm.Mount {
				var out []vm.Mount
				for _, m := range ms {
					m.Location = strings.ReplaceAll(m.Location, root, "ROOT")
					m.MountPoint = strings.ReplaceAll(m.MountPoint, root, "ROOT")
					out = append(out, m)
				}
				return out
			}
			if !reflect.DeepEqual(norm(mounts, gs.root), norm(want, bs.root)) {
				g, _ := json.Marshal(norm(mounts, gs.root))
				b, _ := json.Marshal(norm(want, bs.root))
				t.Errorf("writable %v cache %q:\n go:   %s\n bash: %s", writable, cache, g, b)
			}
			var lines []string
			for _, f := range files {
				lines = append(lines, strings.ReplaceAll(f.Line(), gs.root, "ROOT"))
			}
			if strings.Join(lines, "\n") != strings.TrimSuffix(strings.ReplaceAll(cached, bs.root, "ROOT"), "\n") {
				t.Errorf("file mounts: %q, bash %q", lines, cached)
			}
			if strings.ReplaceAll(warn.String(), gs.root, "ROOT") != strings.ReplaceAll(r.Stderr, bs.root, "ROOT") {
				t.Errorf("warnings: %q, bash %q", warn.String(), r.Stderr)
			}
			if fi, err := os.Stat(gs.state + "/file-mounts/t-00000000/0/file.txt"); err != nil || !fi.Mode().IsRegular() {
				t.Error("the file was not staged")
			}
		}
	}
}
