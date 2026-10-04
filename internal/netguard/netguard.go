// Package netguard decides what a VM may reach on the network: the internet,
// never this machine, its local networks or the other VMs (through this
// machine's loopback, where their ports are forwarded), unless the user
// allows it in ~/.agent-vm/network. It runs in the hostagent, where every
// connection the guest opens is made (Lima's per-instance netstack).
package netguard

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// FileName is the policy's file in agent-vm's state folder.
const FileName = "network"

// resolvedFor is how long an address answered for an allowed domain stays
// reachable: a connection pool may reuse it well after the lookup.
const resolvedFor = 30 * time.Minute

// Policy is what the VMs may reach. The zero Policy is the default: the
// internet only.
type Policy struct {
	// Open turns isolation off (AGENT_VM_UNSAFE_OPEN_NETWORK=1).
	Open bool
	// Allow are reachable whatever else: an address or network, every port
	// when Port is 0.
	Allow []Rule
	// Domains, when any, are the only names of the internet the VMs may
	// reach, subdomains included: an address is reachable once agent-vm's
	// DNS gave it for one of them.
	Domains []string

	mu       sync.Mutex
	resolved map[netip.Addr]time.Time
	own      []netip.Prefix
	ownAt    time.Time
}

// Rule is an allow line: a network, and a port or 0 for every one.
type Rule struct {
	Net  netip.Prefix
	Port uint16
}

// Load reads the policy from the state folder's network file (none: the
// default), and AGENT_VM_UNSAFE_OPEN_NETWORK.
func Load(stateDir string) (*Policy, error) {
	p := &Policy{Open: os.Getenv("AGENT_VM_UNSAFE_OPEN_NETWORK") == "1"}
	f, err := os.Open(stateDir + "/" + FileName)
	if errors.Is(err, os.ErrNotExist) {
		return p, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for n := 1; sc.Scan(); n++ {
		line, _, _ := strings.Cut(sc.Text(), "#")
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		if len(fields) != 2 {
			return nil, fmt.Errorf("%s/%s, line %d: want 'allow <address>' or 'domain <name>'", stateDir, FileName, n)
		}
		switch fields[0] {
		case "allow":
			rules, err := parseAllow(fields[1])
			if err != nil {
				return nil, fmt.Errorf("%s/%s, line %d: %v", stateDir, FileName, n, err)
			}
			p.Allow = append(p.Allow, rules...)
		case "domain":
			d := strings.ToLower(strings.TrimSuffix(strings.TrimPrefix(fields[1], "*."), "."))
			if d == "" || strings.ContainsAny(d, "/:*") {
				return nil, fmt.Errorf("%s/%s, line %d: %q is not a domain name", stateDir, FileName, n, fields[1])
			}
			p.Domains = append(p.Domains, d)
		default:
			return nil, fmt.Errorf("%s/%s, line %d: unknown %q (allow, domain)", stateDir, FileName, n, fields[0])
		}
	}
	return p, sc.Err()
}

// parseAllow reads 10.0.0.5, 10.0.0.5:8080, [::1]:8080, 192.168.1.0/24,
// localhost:11434 (127.0.0.1 and ::1).
func parseAllow(s string) ([]Rule, error) {
	if pf, err := netip.ParsePrefix(s); err == nil {
		return []Rule{{Net: pf.Masked()}}, nil
	}
	host, port := s, uint16(0)
	if h, p, err := net.SplitHostPort(s); err == nil {
		n, err := strconv.ParseUint(p, 10, 16)
		if err != nil || n == 0 {
			return nil, fmt.Errorf("bad port in %q", s)
		}
		host, port = h, uint16(n)
	}
	if host == "localhost" {
		return []Rule{
			{Net: netip.PrefixFrom(netip.MustParseAddr("127.0.0.1"), 32), Port: port},
			{Net: netip.PrefixFrom(netip.IPv6Loopback(), 128), Port: port},
		}, nil
	}
	a, err := netip.ParseAddr(host)
	if err != nil {
		return nil, fmt.Errorf("%q is not an address, an address:port or a network", s)
	}
	a = a.Unmap()
	return []Rule{{Net: netip.PrefixFrom(a, a.BitLen()), Port: port}}, nil
}

var cgnat = netip.MustParsePrefix("100.64.0.0/10")

// internal reports whether a is of this machine or its local networks.
func internal(a netip.Addr) bool {
	return a.IsLoopback() || a.IsPrivate() || a.IsLinkLocalUnicast() || a.IsLinkLocalMulticast() ||
		a.IsInterfaceLocalMulticast() || a.IsMulticast() || a.IsUnspecified() || cgnat.Contains(a) ||
		a.Is4() && (a.As4()[0] == 0 || a == netip.AddrFrom4([4]byte{255, 255, 255, 255}))
}

// Allows reports whether the guest may reach dst over network.
func (p *Policy) Allows(network string, dst netip.AddrPort) bool {
	if p.Open {
		return true
	}
	a := dst.Addr().Unmap()
	for _, r := range p.Allow {
		if r.Net.Contains(a) && (r.Port == 0 || r.Port == dst.Port()) {
			return true
		}
	}
	if internal(a) || p.ownAddress(a) {
		return false
	}
	if len(p.Domains) == 0 {
		return true
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	until, ok := p.resolved[a]
	return ok && time.Now().Before(until)
}

// ownAddress reports whether a is an address of this machine (a public one
// included): what listens on all its interfaces is reached there. Read again
// every few seconds, as interfaces come and go.
func (p *Policy) ownAddress(a netip.Addr) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if time.Since(p.ownAt) > 5*time.Second {
		p.own = p.own[:0]
		if addrs, err := net.InterfaceAddrs(); err == nil {
			for _, ad := range addrs {
				if n, ok := ad.(*net.IPNet); ok {
					if ip, ok := netip.AddrFromSlice(n.IP); ok {
						p.own = append(p.own, netip.PrefixFrom(ip.Unmap(), ip.Unmap().BitLen()))
					}
				}
			}
		}
		p.ownAt = time.Now()
	}
	for _, o := range p.own {
		if o.Contains(a) {
			return true
		}
	}
	return false
}

// Name reports whether the guest may resolve name: with Domains, those and
// their subdomains only.
func (p *Policy) Name(name string) bool {
	if p.Open || len(p.Domains) == 0 {
		return true
	}
	name = strings.ToLower(strings.TrimSuffix(name, "."))
	for _, d := range p.Domains {
		if name == d || strings.HasSuffix(name, "."+d) {
			return true
		}
	}
	return false
}

// Answered records the addresses given for an allowed name: reachable for
// resolvedFor.
func (p *Policy) Answered(name string, ips []net.IP) {
	if !p.Name(name) {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.resolved == nil {
		p.resolved = map[netip.Addr]time.Time{}
	}
	until := time.Now().Add(resolvedFor)
	for _, ip := range ips {
		if a, ok := netip.AddrFromSlice(ip); ok {
			p.resolved[a.Unmap()] = until
		}
	}
}
