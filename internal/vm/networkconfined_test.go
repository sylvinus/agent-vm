package vm

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"

	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype"
)

func TestNetworkConfined(t *testing.T) {
	yes := true
	for name, tc := range map[string]struct {
		networks []limatype.Network
		open     bool
	}{
		"none":         {nil, false},
		"shared":       {[]limatype.Network{{Lima: "user-v2"}}, true},
		"socket":       {[]limatype.Network{{Socket: "/tmp/vmnet.sock"}}, true},
		"vzNAT":        {[]limatype.Network{{VZNAT: &yes}}, true},
		"interface":    {[]limatype.Network{{Interface: "lima0"}}, true},
		"second entry": {[]limatype.Network{{Lima: "a"}, {Lima: "b"}}, true},
	} {
		err := NetworkConfined(&limatype.LimaYAML{Networks: tc.networks})
		if tc.open != errors.Is(err, ErrNetworkOpen) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

// Start refuses a VM whose config has a network, before booting anything.
func TestLimaStartRefusesNetworks(t *testing.T) {
	ctx := context.Background()
	l := newTestLima(t)
	none := []Mount{}
	if err := l.Create(ctx, "n-12345678", "template:debian-13", Settings{Mounts: &none}, io.Discard); err != nil {
		t.Fatal(err)
	}
	yamlPath := filepath.Join(os.Getenv("LIMA_INSTANCES_DIR"), "n-12345678", "lima", "lima.yaml")
	orig, _ := os.ReadFile(yamlPath)
	if err := os.WriteFile(yamlPath, append(orig, "\nnetworks:\n- lima: user-v2\n"...), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := l.Start(ctx, "n-12345678", io.Discard); !errors.Is(err, ErrNetworkOpen) {
		t.Fatalf("start: %v", err)
	}
}
