// Package state is agent-vm's folder, ~/.agent-vm (AGENT_VM_STATE_DIR): the
// user's files (env, volumes, runtime.sh, setup.sh) and one folder per VM,
// vms/<name>, with what agent-vm knows of it.
package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/sylvinus/agent-vm/internal/paths"
)

// Dir is the state folder.
type Dir string

// Default is $AGENT_VM_STATE_DIR, made absolute so that the checks that keep
// shares away from it compare real locations, or ~/.agent-vm, spelled as
// paths.Host does.
func Default() (Dir, error) {
	if d := os.Getenv("AGENT_VM_STATE_DIR"); d != "" {
		abs, err := filepath.Abs(d)
		if err != nil {
			return "", err
		}
		return Dir(paths.Host(abs)), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return Dir(paths.Host(filepath.Join(home, ".agent-vm"))), nil
}

// Path is name in the folder.
func (d Dir) Path(name string) string {
	return paths.Host(filepath.Join(string(d), name))
}

// The files of a VM's folder.
const (
	MetaFile   = "metadata.json"
	PolicyFile = "policy.json"
	// LimaDir is Lima's own folder for the VM.
	LimaDir = "lima"
	// FileMountsDir holds the single files of ~/.agent-vm/volumes, staged.
	FileMountsDir = "file-mounts"
)

// VMs is the folder of every VM.
func (d Dir) VMs() string { return d.Path("vms") }

// VM is the folder of the VM name: nothing else of it is kept anywhere.
func (d Dir) VM(name string) string { return d.Path(filepath.Join("vms", name)) }

// Lima is Lima's folder for the VM name (its lima.yaml, disk, sockets).
func (d Dir) Lima(name string) string { return filepath.Join(d.VM(name), LimaDir) }

// FileMounts is where the staged single files of the VM name are.
func (d Dir) FileMounts(name string) string { return filepath.Join(d.VM(name), FileMountsDir) }

// Policy is the file with the policies the VM name boots with.
func (d Dir) Policy(name string) string { return filepath.Join(d.VM(name), PolicyFile) }

// LimaHome is Lima's own home: what is shared by every VM (_config with the
// SSH key, _networks), apart from the VMs.
func (d Dir) LimaHome() string { return d.Path("lima") }

// Read is the content of name in the folder, without its trailing newline,
// "" when there is none.
func (d Dir) Read(name string) string {
	b, err := os.ReadFile(d.Path(name))
	if err != nil {
		return ""
	}
	return strings.TrimSuffix(string(b), "\n")
}

// Write replaces name in the folder, made if need be, through a temporary
// file renamed over it: a reader sees the old content or the new, never part
// of it.
func (d Dir) Write(name string, data []byte) error {
	return writeAtomic(string(d), d.Path(name), data)
}

// writeAtomic replaces path, in the folder dir made if need be, through a
// temporary file of dir.
func writeAtomic(dir, path string, data []byte) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".tmp-"+filepath.Base(path)+"-*")
	if err != nil {
		return err
	}
	_, werr := tmp.Write(data)
	if err := errors.Join(werr, tmp.Chmod(0o644), tmp.Close()); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return nil
}

// WriteVM replaces name in the folder of the VM vm, made if need be.
func (d Dir) WriteVM(vm, name string, data []byte) error {
	return writeAtomic(d.VM(vm), filepath.Join(d.VM(vm), name), data)
}

// SchemaVersion is the version of metadata.json this agent-vm reads and
// writes.
const SchemaVersion = 1

// Metadata is what agent-vm knows of a VM, in vms/<name>/metadata.json. Only
// written under the VM's lock.
type Metadata struct {
	Schema int `json:"schema"`
	// Base is the template the VM was cloned from. In the template's own
	// file, it is the template itself, written last by setup: it says the
	// template can be cloned.
	Base *Base `json:"base,omitempty"`
	// Term is the $TERM whose terminfo the VM has.
	Term string `json:"term,omitempty"`
	// Bound is the folder a named VM that shares it belongs to, "-" for one
	// that shares nothing.
	Bound string `json:"bound,omitempty"`
	// ScratchPID is the process of the --scratch run the VM belongs to.
	ScratchPID int `json:"scratch_pid,omitempty"`
	// FileMounts are the single files of ~/.agent-vm/volumes to bind in the
	// VM: see mounts.FileMount.
	FileMounts []string `json:"file_mounts,omitempty"`
}

// Base is a template, as built or as cloned.
type Base struct {
	// Name is the template's VM name.
	Name string `json:"name"`
	// Built is when it was built, in Unix seconds.
	Built int64 `json:"built"`
	// BuiltBy is the agent-vm version that built it. Empty for 0.1.0's, which
	// has no sshfs: the shares need one. "0.1.0" in a VM migrated in place
	// by 0.2, which has.
	BuiltBy string `json:"built_by"`
}

// Meta is the metadata of the VM vm. A VM with no file, and one whose file
// cannot be read, have nothing known: the zero Metadata, and for the second,
// an error to say so.
func (d Dir) Meta(vm string) (Metadata, error) {
	p := filepath.Join(d.VM(vm), MetaFile)
	b, err := os.ReadFile(p)
	if errors.Is(err, os.ErrNotExist) {
		return Metadata{}, nil
	}
	if err != nil {
		return Metadata{}, err
	}
	var m Metadata
	if err := json.Unmarshal(b, &m); err != nil {
		return Metadata{}, fmt.Errorf("%s: %w", p, err)
	}
	if m.Schema > SchemaVersion {
		return Metadata{}, fmt.Errorf("%s: written by a newer agent-vm (schema %d, this one reads %d)", p, m.Schema, SchemaVersion)
	}
	return m, nil
}

// Known is the metadata of vm, nothing known when it cannot be read.
func (d Dir) Known(vm string) Metadata {
	m, _ := d.Meta(vm)
	return m
}

// UpdateMeta changes the metadata of vm with fn and writes it back. The
// caller holds the VM's lock. A file that cannot be read is replaced.
func (d Dir) UpdateMeta(vm string, fn func(*Metadata)) error {
	m := d.Known(vm)
	fn(&m)
	m.Schema = SchemaVersion
	b, err := json.MarshalIndent(m, "", " ")
	if err != nil {
		return err
	}
	return d.WriteVM(vm, MetaFile, append(b, '\n'))
}

// Forget removes the folder of vm, and with it all that is known of it: once
// the VM is deleted.
func (d Dir) Forget(vm string) error {
	return os.RemoveAll(d.VM(vm))
}

// Names are the folders of vms/, which hold a VM or what is left of one.
func (d Dir) Names() []string {
	ents, _ := os.ReadDir(d.VMs())
	var out []string
	for _, e := range ents {
		if e.IsDir() && !strings.HasPrefix(e.Name(), ".") {
			out = append(out, e.Name())
		}
	}
	return out
}

// HasLima reports whether Lima has made the VM: its lima.yaml is there. A
// folder without one is a creation that did not finish.
func (d Dir) HasLima(vm string) bool {
	_, err := os.Stat(filepath.Join(d.Lima(vm), "lima.yaml"))
	return err == nil
}

// BaseReady reports whether the template can be cloned: setup finished.
func (d Dir) BaseReady(template string) bool {
	b := d.Known(template).Base
	return b != nil && b.Built > 0
}

var builtByRe = regexp.MustCompile(`^[0-9A-Za-z.+-]+$`)

// BaseLabel is the base vm was cloned from, for `list`: the agent-vm version
// that built it, and the day, "-" when not known. The base template
// describes itself. 0.1.0 recorded no version: a base without one was built
// by it.
func (d Dir) BaseLabel(vm string) string {
	by, day := "0.1.0", "-"
	if b := d.Known(vm).Base; b != nil {
		if builtByRe.MatchString(b.BuiltBy) {
			by = b.BuiltBy
		}
		if b.Built > 0 {
			day = time.Unix(b.Built, 0).Format("2006-01-02")
		}
	}
	return by + " " + day
}
