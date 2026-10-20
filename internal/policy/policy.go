// Package policy is what a VM boots with, in vms/<name>/policy.json: the
// network rules and the guarded files. Lima starts agent-vm again as the
// VM's hostagent, where both are enforced; the file is how they reach it, and
// the record of what the VM booted with.
package policy

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"crypto/sha256"
	"encoding/hex"

	"github.com/sylvinus/agent-vm/internal/guard"
	"github.com/sylvinus/agent-vm/internal/netguard"
)

// SchemaVersion is the version of the file this agent-vm reads and writes.
const SchemaVersion = 1

// The policies as values. The zero Network lets a VM reach the internet and
// nothing of this machine; the zero Guarded guards nothing (DefaultGuarded is
// agent-vm's list).
type (
	Network = netguard.Policy
	Rule    = netguard.Rule
	Guarded = guard.Config
)

// DefaultGuarded is agent-vm's list of files the host runs, which the VM may
// not write unasked.
func DefaultGuarded() Guarded { return guard.DefaultConfig() }

// New is a File for the policies given.
func New(app string, n *Network, g Guarded) *File {
	if n == nil {
		n = &Network{}
	}
	return &File{Schema: SchemaVersion, App: app, Network: n, Guarded: g}
}

// File is the policy file.
type File struct {
	Schema int `json:"schema"`
	// App names the program in what the user is shown.
	App     string           `json:"app,omitempty"`
	Network *netguard.Policy `json:"network"`
	Guarded guard.Config     `json:"guarded"`
}

// Current is the policies in force now, from agent-vm's files in the state
// folder and the environment: an unreadable file is an error.
func Current(stateDir, app string) (*File, error) {
	n, err := netguard.Load(stateDir)
	if err != nil {
		return nil, err
	}
	g, err := guard.LoadConfig(stateDir)
	if err != nil {
		return nil, err
	}
	return New(app, n, g), nil
}

// Write replaces the file at path, whole or not at all.
func Write(path string, f *File) error {
	b, err := json.MarshalIndent(f, "", " ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-policy-*")
	if err != nil {
		return err
	}
	_, werr := tmp.Write(append(b, '\n'))
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

// Read is the file at path. A hostagent that cannot read its policy must not
// run the VM open: the error stops it.
func Read(path string) (*File, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var f File
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if f.Schema != SchemaVersion {
		return nil, fmt.Errorf("%s: schema %d, this agent-vm reads %d", path, f.Schema, SchemaVersion)
	}
	if f.Network == nil {
		return nil, fmt.Errorf("%s: no network policy", path)
	}
	return &f, nil
}

// Fingerprint identifies the policies, the order of the rules and the
// comments of the files they came from not counting.
func (f *File) Fingerprint() string {
	c := *f
	n := &netguard.Policy{Open: f.Network.Open, Domains: append([]string(nil), f.Network.Domains...), Allow: append([]netguard.Rule(nil), f.Network.Allow...)}
	sort.Strings(n.Domains)
	sort.Slice(n.Allow, func(i, j int) bool {
		a, b := n.Allow[i], n.Allow[j]
		if a.Net.String() != b.Net.String() {
			return a.Net.String() < b.Net.String()
		}
		return a.Port < b.Port
	})
	c.Network = n
	b, _ := json.Marshal(c)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
