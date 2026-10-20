package dns

import (
	"context"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/sylvinus/agent-vm/third_party/gvisor-tap-vsock/pkg/types"
	"github.com/foxcpp/go-mockdns"
	"github.com/miekg/dns"
	"github.com/onsi/ginkgo"
	"github.com/onsi/gomega"
	log "github.com/sirupsen/logrus"
	"github.com/stretchr/testify/require"
)

func TestSuite(t *testing.T) {
	gomega.RegisterFailHandler(ginkgo.Fail)
	ginkgo.RunSpecs(t, "gvisor-tap-vsock dns suit")
}

var _ = ginkgo.Describe("dns add test", func() {
	var server *Server

	ginkgo.BeforeEach(func() {
		server, _ = New(nil, nil, []types.Zone{})
	})

	ginkgo.It("should add dns zone with ip", func() {
		req := types.Zone{
			Name:      "internal.",
			DefaultIP: net.ParseIP("192.168.0.1"),
		}
		server.addZone(req)

		gomega.Expect(server.handler.zones).To(gomega.Equal([]types.Zone{req}))
	})

	ginkgo.It("should add dns zone with record", func() {
		req := types.Zone{
			Name: "internal.",
			Records: []types.Record{{
				Name: "crc.testiing",
				IP:   net.ParseIP("192.168.0.2"),
			}},
		}
		server.addZone(req)

		gomega.Expect(server.handler.zones).To(gomega.Equal([]types.Zone{req}))
	})

	ginkgo.It("should add dns zone with record and ip", func() {
		ipReq := types.Zone{
			Name:      "dynamic.internal.",
			DefaultIP: net.ParseIP("192.168.0.1"),
		}
		recordReq := types.Zone{
			Name: "internal.",
			Records: []types.Record{{
				Name: "crc.testiing",
				IP:   net.ParseIP("192.168.0.2"),
			}},
		}
		server.addZone(ipReq)
		server.addZone(recordReq)

		gomega.Expect(server.handler.zones).To(gomega.Equal([]types.Zone{ipReq, recordReq}))
	})

	ginkgo.It("should add new zone to existing zone with default ip", func() {
		ipReq := types.Zone{
			Name:      "internal.",
			DefaultIP: net.ParseIP("192.168.0.1"),
		}
		server.addZone(ipReq)
		recordReq := types.Zone{
			Name: "internal.",
			Records: []types.Record{{
				Name: "crc.testing",
				IP:   net.ParseIP("192.168.0.2"),
			}},
		}
		server.addZone(recordReq)

		gomega.Expect(server.handler.zones).To(gomega.Equal([]types.Zone{{
			Name: "internal.",
			Records: []types.Record{{
				Name: "crc.testing",
				IP:   net.ParseIP("192.168.0.2"),
			}},
		}}))
	})

	ginkgo.It("should add new zone to existing zone with records", func() {
		ipReq := types.Zone{
			Name: "internal.",
			Records: []types.Record{{
				Name: "crc.testing",
				IP:   net.ParseIP("192.168.0.2"),
			}},
		}
		server.addZone(ipReq)
		recordReq := types.Zone{
			Name: "internal.",
			Records: []types.Record{{
				Name: "crc.testing",
				IP:   net.ParseIP("192.168.0.3"),
			}},
		}
		server.addZone(recordReq)

		gomega.Expect(server.handler.zones).To(gomega.Equal([]types.Zone{{
			Name: "internal.",
			Records: []types.Record{{
				Name: "crc.testing",
				IP:   net.ParseIP("192.168.0.3"),
			}, {
				Name: "crc.testing",
				IP:   net.ParseIP("192.168.0.2"),
			}},
		}}))
	})

	ginkgo.It("should add new zone to existing zone with records", func() {
		ipReq := types.Zone{
			Name: "internal.",
			Records: []types.Record{{
				Name: "crc.testing",
				IP:   net.ParseIP("192.168.0.2"),
			}},
		}
		server.addZone(ipReq)
		recordReq := types.Zone{
			Name: "internal.",
			Records: []types.Record{{
				Name: "crc.testing",
				IP:   net.ParseIP("192.168.0.3"),
			}},
		}
		server.addZone(recordReq)

		gomega.Expect(server.handler.zones).To(gomega.Equal([]types.Zone{{
			Name: "internal.",
			Records: []types.Record{{
				Name: "crc.testing",
				IP:   net.ParseIP("192.168.0.3"),
			}, {
				Name: "crc.testing",
				IP:   net.ParseIP("192.168.0.2"),
			}},
		}}))
	})

	ginkgo.It("should retain the order of zones", func() {
		server, _ = New(nil, nil, []types.Zone{
			{
				Name:      "crc.testing.",
				DefaultIP: net.ParseIP("192.168.127.2"),
			},
			{
				Name: "testing.",
				Records: []types.Record{
					{
						Name: "host",
						IP:   net.ParseIP("192.168.127.3"),
					},
				},
			},
		})
		server.addZone(types.Zone{
			Name: "testing.",
			Records: []types.Record{
				{
					Name: "gateway",
					IP:   net.ParseIP("192.168.127.1"),
				},
			},
		})
		gomega.Expect(server.handler.zones).To(gomega.Equal([]types.Zone{
			{
				Name:      "crc.testing.",
				DefaultIP: net.ParseIP("192.168.127.2"),
			},
			{
				Name: "testing.",
				Records: []types.Record{
					{
						Name: "gateway",
						IP:   net.ParseIP("192.168.127.1"),
					},
					{
						Name: "host",
						IP:   net.ParseIP("192.168.127.3"),
					},
				},
			},
		}))
	})

	ginkgo.It("Should pass DNS requests to default system DNS server", func() {
		m := &dns.Msg{
			MsgHdr: dns.MsgHdr{
				Authoritative:     false,
				AuthenticatedData: false,
				CheckingDisabled:  false,
				RecursionDesired:  true,
				Opcode:            0,
			},
			Question: make([]dns.Question, 1),
		}

		m.Question[0] = dns.Question{
			Name:   "redhat.com.",
			Qtype:  1,
			Qclass: 1,
		}

		server.handler.addAnswers(m)

		gomega.Expect(m.Answer[0].Header().Name).To(gomega.Equal("redhat.com."))
		gomega.Expect(m.Answer[0].String()).To(gomega.SatisfyAny(gomega.ContainSubstring("34.235.198.240"), gomega.ContainSubstring("52.200.142.250")))
	})

})

var _ = ginkgo.Describe("TXT records", func() {

	var cleanup func()
	var vsockResolver *net.Resolver
	var upstream upstreamResolver

	const longTxtDomain = "long.txt.test."         // 20230601._domainkey.gmail.com
	const multipleTxtDomain = "multiple.txt.test." // google.com

	ginkgo.BeforeEach(func() {
		var nameserver string
		var err error

		const txt = "abcdefghijklmnopqrstuvwxyz012456789"
		const longTxt = txt + txt + txt + txt + txt + txt + txt + txt
		upstream = &mockdns.Resolver{
			Zones: map[string]mockdns.Zone{
				longTxtDomain: {
					TXT: []string{longTxt},
				},
				multipleTxtDomain: {
					TXT: []string{"AAAAAAA", "BBBBBBB"},
				},
			},
		}

		nameserver, cleanup, err = startDNSServer(upstream)
		gomega.Expect(err).To(gomega.BeNil())
		time.Sleep(100 * time.Millisecond)

		vsockResolver = &net.Resolver{
			PreferGo: true,
			Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
				d := net.Dialer{}
				return d.DialContext(ctx, network, nameserver)
			},
		}
	})

	ginkgo.AfterEach(func() {
		if cleanup != nil {
			cleanup()
			// TODO port conflict race condition.
			time.Sleep(100 * time.Millisecond)
		}
	})

	ginkgo.When("There are long TXT Records", func() {

		hasLongString := func(records []string) bool {
			for _, txt := range records {
				if len(txt) > 255 {
					return true
				}
			}
			return false
		}
		ginkgo.It("Should produce the same result as upstream Resolver", func() {

			upstreamRecords, err := upstream.LookupTXT(context.Background(), longTxtDomain)
			gomega.Expect(err).To(gomega.BeNil())
			gomega.Expect(hasLongString(upstreamRecords)).To(gomega.BeTrue(), "Expected at least one TXT string longer than 255 bytes")

			vsockRecords, err := vsockResolver.LookupTXT(context.Background(), longTxtDomain)
			gomega.Expect(err).To(gomega.BeNil())

			gomega.Expect(vsockRecords).To(gomega.Equal(upstreamRecords))

		})

	})

	ginkgo.When("there are multiple TXT Records", func() {
		ginkgo.It("Should produce the same result as upstream Resolver", func() {
			upstreamRecords, err := upstream.LookupTXT(context.Background(), multipleTxtDomain)
			gomega.Expect(err).To(gomega.BeNil())
			gomega.Expect(len(upstreamRecords)).To(gomega.BeNumerically(">", 1), "Expected more than one TXT record")

			vsockRecords, err := vsockResolver.LookupTXT(context.Background(), multipleTxtDomain)
			gomega.Expect(err).To(gomega.BeNil())

			gomega.Expect(vsockRecords).To(gomega.ConsistOf(upstreamRecords))

		})
	})

})

type ARecord struct {
	name        string
	expectedIPs []string
}

func TestDNS(t *testing.T) {
	log.Infof("starting test DNS servers")

	upstream := &mockdns.Resolver{
		Zones: map[string]mockdns.Zone{
			"redhat.com.": {
				A: []string{"52.200.142.250", "34.235.198.240"},
			},
		},
	}

	nameserver, cleanup, err := startDNSServer(upstream)
	require.NoError(t, err)
	defer cleanup()
	time.Sleep(100 * time.Millisecond)
	log.Infof("test DNS servers started")

	r := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			d := net.Dialer{
				Timeout: time.Millisecond * time.Duration(10000),
			}
			log.Infof("dialing %s %s", network, nameserver)

			return d.DialContext(ctx, network, nameserver)
		},
	}
	redhatdotcom := ARecord{
		name:        "redhat.com",
		expectedIPs: []string{"52.200.142.250"},
	}
	record := redhatdotcom
	{
		log.Infof("looking up %s", record.name)
		ipGvisor, err := r.LookupHost(context.Background(), record.name)
		require.NoError(t, err)
		require.Subset(t, ipGvisor, record.expectedIPs)
		log.Infof("ip gvisor: %+v", ipGvisor)

		ipGo, err := net.LookupHost(record.name)
		require.NoError(t, err)
		log.Infof("ip go: %+v", ipGo)
		require.Subset(t, ipGvisor, ipGo)
	}
}

func startDNSServer(upstream upstreamResolver) (string, func(), error) {
	udpConn, err := net.ListenPacket("udp", "127.0.0.1:5354")
	if err != nil {
		return "", nil, err
	}

	tcpLn, err := net.Listen("tcp", "127.0.0.1:5354")
	if err != nil {
		return "", nil, err
	}

	server, err := NewWithUpstreamResolver(udpConn, tcpLn, nil, upstream)
	if err != nil {
		return "", nil, err
	}

	go func() {
		if err := server.Serve(); err != nil {
			log.Errorf("serve UDP error: %T %s", err, err)
		}
	}()
	go func() {
		if err := server.ServeTCP(); err != nil {
			log.Errorf("serve TCP error: %T %s", err, err)
		}
	}()
	return "127.0.0.1:5354", func() {
		udpConn.Close()
		tcpLn.Close()
	}, nil
}

type countingResolver struct {
	upstreamResolver
	mu    sync.Mutex
	asked []string
}

func (c *countingResolver) LookupIPAddr(ctx context.Context, host string) ([]net.IPAddr, error) {
	c.mu.Lock()
	c.asked = append(c.asked, host)
	c.mu.Unlock()
	return c.upstreamResolver.LookupIPAddr(ctx, host)
}

func TestPolicy(t *testing.T) {
	upstream := &countingResolver{upstreamResolver: &mockdns.Resolver{
		Zones: map[string]mockdns.Zone{
			"ok.test.": {A: []string{"192.0.2.1"}},
			"no.test.": {A: []string{"192.0.2.2"}},
		},
	}}
	udpConn, err := net.ListenPacket("udp", "127.0.0.1:0")
	require.NoError(t, err)
	defer udpConn.Close()
	tcpLn, err := net.Listen("tcp", "127.0.0.1:0")
	require.NoError(t, err)
	defer tcpLn.Close()
	server, err := NewWithUpstreamResolver(udpConn, tcpLn, nil, upstream)
	require.NoError(t, err)

	var mu sync.Mutex
	told := map[string][]net.IP{}
	server.SetPolicy(
		func(name string) bool { return name == "ok.test" },
		func(name string, ips []net.IP) {
			mu.Lock()
			defer mu.Unlock()
			told[name] = ips
		})
	go func() { _ = server.Serve() }()
	go func() { _ = server.ServeTCP() }()
	time.Sleep(100 * time.Millisecond)

	for _, proto := range []string{"udp", "tcp"} {
		c := &dns.Client{Net: proto}
		addr := udpConn.LocalAddr().String()
		if proto == "tcp" {
			addr = tcpLn.Addr().String()
		}

		q := new(dns.Msg)
		q.SetQuestion("NO.test.", dns.TypeA)
		r, _, err := c.Exchange(q, addr)
		require.NoError(t, err, proto)
		require.Equal(t, dns.RcodeNameError, r.Rcode, proto)
		require.Empty(t, r.Answer, proto)

		q = new(dns.Msg)
		q.SetQuestion("ok.test.", dns.TypeA)
		r, _, err = c.Exchange(q, addr)
		require.NoError(t, err, proto)
		require.Equal(t, dns.RcodeSuccess, r.Rcode, proto)
		require.Len(t, r.Answer, 1, proto)

	}

	// One refused question refuses the message.
	m := new(dns.Msg)
	m.Question = []dns.Question{
		{Name: "ok.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET},
		{Name: "no.test.", Qtype: dns.TypeA, Qclass: dns.ClassINET},
	}
	server.handler.addAnswers(m)
	require.Equal(t, dns.RcodeNameError, m.Rcode)
	require.Empty(t, m.Answer)

	mu.Lock()
	defer mu.Unlock()
	require.Equal(t, []net.IP{net.ParseIP("192.0.2.1").To4()}, told["ok.test"])
	require.NotContains(t, told, "no.test")
	upstream.mu.Lock()
	defer upstream.mu.Unlock()
	for _, host := range upstream.asked {
		require.Equal(t, "ok.test.", host, "a refused name was looked up")
	}
}
