// Command agent-vm-assets makes the files a program that embeds agentvm gives
// to Options.Assets: Lima's guest agent for Linux, gzipped, and Lima's
// templates.
//
//	go run github.com/sylvinus/agent-vm/cmd/agent-vm-assets -o assets/
//
// Run from the program's module, at build time (go generate); embed the
// folder:
//
//	//go:embed all:assets
//	var assetsFS embed.FS
//
//	assets, _ := fs.Sub(assetsFS, "assets") // Options.Assets
//
// The guest agent is built for the architecture of the machine that runs the
// program, unless -arch names others (aarch64, x86_64: both for a program
// built for macOS and Linux hosts of both).
package main

import (
	"bytes"
	"compress/gzip"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const module = "github.com/sylvinus/agent-vm"

func main() {
	out := flag.String("o", "assets", "folder to fill")
	arch := flag.String("arch", "", "guest architectures, comma-separated (aarch64, x86_64); this machine's by default")
	flag.Parse()
	if err := run(*out, *arch); err != nil {
		fmt.Fprintf(os.Stderr, "agent-vm-assets: %v\n", err)
		os.Exit(1)
	}
}

func goArch(a string) (string, error) {
	switch a {
	case "aarch64", "arm64":
		return "arm64", nil
	case "x86_64", "amd64":
		return "amd64", nil
	}
	return "", fmt.Errorf("unknown architecture %q (aarch64, x86_64)", a)
}

func run(out, archs string) error {
	if archs == "" {
		archs = map[string]string{"arm64": "aarch64", "amd64": "x86_64"}[runtime.GOARCH]
		if archs == "" {
			return fmt.Errorf("no guest agent for %s: name -arch", runtime.GOARCH)
		}
	}
	dir, err := goOutput("list", "-m", "-f", "{{.Dir}}", module)
	if err != nil {
		return fmt.Errorf("where is %s? Run this from a module that requires it: %w", module, err)
	}
	version, err := limaVersion(filepath.Join(dir, "third_party", "SOURCES"))
	if err != nil {
		return err
	}
	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}
	tmp, err := os.MkdirTemp("", "agent-vm-assets")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	for _, a := range strings.Split(archs, ",") {
		a = strings.TrimSpace(a)
		ga, err := goArch(a)
		if err != nil {
			return err
		}
		if err := buildGuestAgent(tmp, out, dir, a, ga, version); err != nil {
			return err
		}
	}
	dst := filepath.Join(out, "templates")
	if err := os.RemoveAll(dst); err != nil {
		return err
	}
	return copyTree(filepath.Join(dir, "third_party", "lima", "templates"), dst)
}

// limaVersion is the version of Lima that SOURCES records: the one its guest
// agent reports.
func limaVersion(sources string) (string, error) {
	b, err := os.ReadFile(sources)
	if err != nil {
		return "", err
	}
	for _, l := range strings.Split(string(b), "\n") {
		if f := strings.Fields(l); len(f) >= 4 && f[0] == "lima" && !strings.HasPrefix(l, "#") {
			return f[3], nil
		}
	}
	return "", fmt.Errorf("no lima in %s", sources)
}

// buildGuestAgent builds Lima's guest agent for the Linux guest of arch. From
// the folder of agent-vm's own module, with its go.sum: the program's module
// does not import the agent, so its go.sum has none of the agent's modules.
func buildGuestAgent(tmp, out, dir, arch, goarch, version string) error {
	bin := filepath.Join(tmp, "lima-guestagent."+arch)
	cmd := exec.Command("go", "build", "-trimpath", "-buildvcs=false",
		"-ldflags", "-s -w -X "+module+"/third_party/lima/pkg/version.Version="+version,
		"-o", bin, "./third_party/lima/cmd/lima-guestagent")
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0", "GOOS=linux", "GOARCH="+goarch, "GOWORK=off")
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("building the guest agent for %s: %w", arch, err)
	}
	b, err := os.ReadFile(bin)
	if err != nil {
		return err
	}
	var z bytes.Buffer
	// No name, no time: the same bytes every time.
	w, _ := gzip.NewWriterLevel(&z, gzip.BestCompression)
	if _, err := w.Write(b); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(out, "lima-guestagent.Linux-"+arch+".gz"), z.Bytes(), 0o644)
}

func goOutput(args ...string) (string, error) {
	cmd := exec.Command("go", args...)
	cmd.Stderr = os.Stderr
	b, err := cmd.Output()
	return strings.TrimSpace(string(b)), err
}

func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, p)
		if err != nil {
			return err
		}
		t := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(t, 0o755)
		}
		in, err := os.Open(p)
		if err != nil {
			return err
		}
		defer in.Close()
		o, err := os.OpenFile(t, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
		if err != nil {
			return err
		}
		_, err = io.Copy(o, in)
		if err := closeAfter(o, err); err != nil {
			return fmt.Errorf("%s: %w", t, err)
		}
		return nil
	})
}

func closeAfter(f *os.File, err error) error {
	if cerr := f.Close(); err == nil {
		return cerr
	}
	return err
}
