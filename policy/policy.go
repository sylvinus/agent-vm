// Package policy holds what a VM may reach and what it may not change
// unasked, as values, and the parsers of agent-vm's files that make them.
// A program that embeds agentvm gives them as Options.Network and
// Options.Guarded; the engine writes them to each VM's folder when it boots,
// where the VM's host agent reads them.
//
// This package is experimental until a program other than agent-vm has used
// it.
package policy

import (
	"io"
	"net/netip"

	"github.com/sylvinus/agent-vm/internal/guard"
	"github.com/sylvinus/agent-vm/internal/netguard"
)

// Network is what the VMs may reach. The zero Network is the default: the
// internet only, never the host, its local networks or the other VMs.
//
//   - Open turns the isolation off: the VMs reach the host and its networks.
//     Unsafe; for a program that has to.
//   - Allow lists addresses and networks reachable whatever else, on every
//     port or one.
//   - Domains, when any, are the only names of the internet the VMs may reach,
//     subdomains included. Experimental: do not rely on it alone to confine a
//     VM.
type Network = netguard.Policy

// Rule is an allow line: a network, and a port or 0 for every one.
type Rule = netguard.Rule

// NewRule allows addr, a port of it (0: every port).
func NewRule(prefix netip.Prefix, port uint16) Rule { return Rule{Net: prefix, Port: port} }

// Guarded are the files the host runs without asking (direnv's .envrc, the
// editor's tasks, git hooks' config) that a VM may not write unasked: Paths,
// relative, each with why it matters ("" for one the program added), matched
// anywhere in a written path as whole names. Deny refuses what is guarded
// without a dialog, for a program no one is at.
type Guarded = guard.Config

// DefaultGuarded is agent-vm's list.
func DefaultGuarded() Guarded { return guard.DefaultConfig() }

// ParseNetwork reads agent-vm's network file: `allow 10.0.0.5:8080`, `allow
// 192.168.1.0/24`, `allow localhost:11434` and `domain example.com` lines,
// with comments. name is the file's, for the messages.
func ParseNetwork(r io.Reader, name string) (*Network, error) {
	return netguard.Parse(r, name)
}

// ParseGuarded adds the lines of agent-vm's guarded file to g (the paths
// already there, DefaultGuarded's say, stay): one path a line, `!path`
// removes one.
func ParseGuarded(r io.Reader, g *Guarded) error {
	return g.ParseList(r)
}
