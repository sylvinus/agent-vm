package limaembed

import (
	"crypto/sha256"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
)

// What Lima finds in <prefix>/share/lima next to limactl: the guest agent and
// the templates. Put in by the Makefile; see assets/README.
//
//go:embed all:assets
var embedded embed.FS

// Embedded is what agent-vm's own build embeds: the guest agent for this
// architecture, gzipped, and the templates, at the root.
func Embedded() fs.FS {
	sub, err := fs.Sub(embedded, "assets")
	if err != nil {
		return embedded
	}
	return sub
}

// Share is Lima's share/lima, written out of the binary.
type Share struct {
	// Dir holds templates/ and the guest agent.
	Dir string
	// GuestAgent is the guest agent for Linux guests of this host's
	// architecture, gzipped: Lima decompresses it.
	GuestAgent string
}

// Templates is where Lima reads templates from (LIMA_TEMPLATES_PATH).
func (s *Share) Templates() string {
	return filepath.Join(s.Dir, "templates")
}

// ErrNoAssets is returned by WriteShare when there is no guest agent: agent-vm
// was built without it (`go build` instead of `make`), or the program that
// embeds the library gave none (Options.Assets).
var ErrNoAssets = errors.New("no Lima guest agent in the assets: build agent-vm with make, or give Options.Assets the output of cmd/agent-vm-assets")

// WriteShare writes the files of assets (Embedded when nil) into
// dir/share/lima, each one that is missing or differs from the copy, and
// returns where they are. The files are checked on every call: a damaged
// guest agent never reaches a VM.
func WriteShare(dir string, assets fs.FS) (*Share, error) {
	if assets == nil {
		assets = Embedded()
	}
	agent := "lima-guestagent.Linux-" + guestArch() + ".gz"
	if _, err := fs.Stat(assets, agent); err != nil {
		return nil, ErrNoAssets
	}
	share := filepath.Join(dir, "share", "lima")
	err := fs.WalkDir(assets, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel := p
		if p == "." {
			rel = ""
		}
		if rel == "README" {
			return nil
		}
		dst := filepath.Join(share, filepath.FromSlash(rel))
		if d.IsDir() {
			return os.MkdirAll(dst, 0o700)
		}
		want, err := fs.ReadFile(assets, p)
		if err != nil {
			return err
		}
		return writeIfChanged(dst, want)
	})
	if err != nil {
		return nil, fmt.Errorf("writing Lima's files to %s: %w", share, err)
	}
	return &Share{Dir: share, GuestAgent: filepath.Join(share, agent)}, nil
}

func writeIfChanged(dst string, want []byte) error {
	if have, err := os.ReadFile(dst); err == nil && sha256.Sum256(have) == sha256.Sum256(want) {
		return nil
	}
	tmp := dst + ".tmp"
	if err := os.WriteFile(tmp, want, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, dst)
}

// guestArch is this host's architecture as Lima names guest agents.
func guestArch() string {
	switch runtime.GOARCH {
	case "amd64":
		return "x86_64"
	case "arm64":
		return "aarch64"
	default:
		return runtime.GOARCH
	}
}
