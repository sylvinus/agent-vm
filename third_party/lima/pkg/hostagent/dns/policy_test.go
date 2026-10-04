// SPDX-FileCopyrightText: Copyright The Lima Authors
// SPDX-License-Identifier: Apache-2.0

package dns

import (
	"net"
	"runtime"
	"testing"

	"github.com/miekg/dns"
	"gotest.tools/v3/assert"
)

// A name Names refuses gets NXDOMAIN, without a lookup; one it allows is
// answered, and Answered told of its addresses.
func TestNamesAnswered(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip()
	}
	h, err := NewHandler(HandlerOptions{StaticHosts: map[string]string{"ok.test": "192.0.2.1", "no.test": "192.0.2.2"}})
	assert.NilError(t, err)
	told := map[string][]net.IP{}
	Names = func(name string) bool { return name == "ok.test" }
	Answered = func(name string, ips []net.IP) { told[name] = ips }
	t.Cleanup(func() { Names, Answered = nil, nil })

	w := new(TestResponseWriter)
	req := new(dns.Msg)
	req.SetQuestion("no.test.", dns.TypeA)
	h.ServeDNS(w, req)
	assert.Equal(t, dnsResult.Rcode, dns.RcodeNameError)
	assert.Equal(t, len(dnsResult.Answer), 0)

	req = new(dns.Msg)
	req.SetQuestion("ok.test.", dns.TypeA)
	h.ServeDNS(w, req)
	assert.Equal(t, dnsResult.Rcode, dns.RcodeSuccess)
	assert.Equal(t, len(dnsResult.Answer), 1)
	assert.Equal(t, told["ok.test"][0].String(), "192.0.2.1")
	_, asked := told["no.test"]
	assert.Assert(t, !asked)
}
