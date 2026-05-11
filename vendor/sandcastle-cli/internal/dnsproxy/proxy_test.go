package dnsproxy

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/miekg/dns"
)

func TestProxyForwardsUDP(t *testing.T) {
	upstream, upstreamAddr := startTestDNSServer(t, "udp")
	defer upstream.Shutdown()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	local := freeLocalAddr(t)
	go func() {
		_ = Serve(ctx, Config{Listen: local, Upstream: upstreamAddr})
	}()
	waitForDNS(t, local)

	msg := new(dns.Msg)
	msg.SetQuestion("sandcastle.test.", dns.TypeSOA)
	resp, _, err := (&dns.Client{Net: "udp", Timeout: time.Second}).Exchange(msg, local)
	if err != nil {
		t.Fatalf("udp exchange failed: %v", err)
	}
	if resp.Rcode != dns.RcodeSuccess || len(resp.Answer) != 1 {
		t.Fatalf("unexpected response: rcode=%d answers=%d", resp.Rcode, len(resp.Answer))
	}
}

func TestProxyReturnsServfailWhenUDPUpstreamUnavailable(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	local := freeLocalAddr(t)
	go func() {
		_ = Serve(ctx, Config{Listen: local, Upstream: freeLocalAddr(t)})
	}()
	waitForDNS(t, local)

	msg := new(dns.Msg)
	msg.SetQuestion("sandcastle.test.", dns.TypeSOA)
	resp, _, err := (&dns.Client{Net: "udp", Timeout: time.Second}).Exchange(msg, local)
	if err != nil {
		t.Fatalf("udp exchange failed: %v", err)
	}
	if resp.Rcode != dns.RcodeServerFailure {
		t.Fatalf("rcode=%d, want SERVFAIL", resp.Rcode)
	}
}

func TestProxyForwardsTCP(t *testing.T) {
	upstream, upstreamAddr := startTestDNSServer(t, "tcp")
	defer upstream.Shutdown()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	local := freeLocalAddr(t)
	go func() {
		_ = Serve(ctx, Config{Listen: local, Upstream: upstreamAddr})
	}()
	waitForDNS(t, local)

	msg := new(dns.Msg)
	msg.SetQuestion("sandcastle.test.", dns.TypeSOA)
	resp, _, err := (&dns.Client{Net: "tcp", Timeout: time.Second}).Exchange(msg, local)
	if err != nil {
		t.Fatalf("tcp exchange failed: %v", err)
	}
	if resp.Rcode != dns.RcodeSuccess || len(resp.Answer) != 1 {
		t.Fatalf("unexpected response: rcode=%d answers=%d", resp.Rcode, len(resp.Answer))
	}
}

func TestProxyRoutesSearchSuffixedQueryToFallback(t *testing.T) {
	primary, primaryAddr := startTestDNSServerWithHandler(t, "udp", func(w dns.ResponseWriter, r *dns.Msg) {
		resp := new(dns.Msg)
		resp.SetRcode(r, dns.RcodeNameError)
		_ = w.WriteMsg(resp)
	})
	defer primary.Shutdown()

	questions := make(chan string, 1)
	fallback, fallbackAddr := startTestDNSServerWithHandler(t, "udp", func(w dns.ResponseWriter, r *dns.Msg) {
		questions <- r.Question[0].Name
		resp := new(dns.Msg)
		resp.SetReply(r)
		resp.Answer = []dns.RR{&dns.A{
			Hdr: dns.RR_Header{Name: r.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 15},
			A:   net.ParseIP("10.143.211.4"),
		}}
		_ = w.WriteMsg(resp)
	})
	defer fallback.Shutdown()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	local := freeLocalAddr(t)
	go func() {
		_ = Serve(ctx, Config{
			Listen:    local,
			Upstream:  primaryAddr,
			Suffix:    "hz1",
			Fallbacks: map[string]string{"hz": fallbackAddr},
		})
	}()
	waitForDNS(t, local)

	msg := new(dns.Msg)
	msg.SetQuestion("dev.sc.hz.hz1.", dns.TypeA)
	resp, _, err := (&dns.Client{Net: "udp", Timeout: time.Second}).Exchange(msg, local)
	if err != nil {
		t.Fatalf("udp exchange failed: %v", err)
	}
	select {
	case got := <-questions:
		if want := "dev.sc.hz."; got != want {
			t.Fatalf("fallback got question %q, want %q", got, want)
		}
	case <-time.After(time.Second):
		t.Fatal("fallback did not receive a query")
	}
	if resp.Rcode != dns.RcodeSuccess {
		t.Fatalf("rcode=%d, want success", resp.Rcode)
	}
	if len(resp.Answer) != 2 {
		t.Fatalf("answers=%d, want cname + a: %#v", len(resp.Answer), resp.Answer)
	}
	cname, ok := resp.Answer[0].(*dns.CNAME)
	if !ok {
		t.Fatalf("first answer = %T, want CNAME", resp.Answer[0])
	}
	if cname.Hdr.Name != "dev.sc.hz.hz1." || cname.Target != "dev.sc.hz." {
		t.Fatalf("unexpected cname: %#v", cname)
	}
	a, ok := resp.Answer[1].(*dns.A)
	if !ok {
		t.Fatalf("second answer = %T, want A", resp.Answer[1])
	}
	if got := a.A.String(); got != "10.143.211.4" {
		t.Fatalf("A record = %s, want 10.143.211.4", got)
	}
}

func TestProbeRejectsZeroAnswerResponse(t *testing.T) {
	server, addr := startTestDNSServerWithHandler(t, "udp", func(w dns.ResponseWriter, r *dns.Msg) {
		resp := new(dns.Msg)
		resp.SetReply(r)
		_ = w.WriteMsg(resp)
	})
	defer server.Shutdown()

	if err := Probe(addr, "sandcastle.test", time.Second); err == nil {
		t.Fatal("Probe succeeded, want zero-answer failure")
	}
}

func startTestDNSServer(t *testing.T, netw string) (*dns.Server, string) {
	t.Helper()
	return startTestDNSServerWithHandler(t, netw, func(w dns.ResponseWriter, r *dns.Msg) {
		resp := new(dns.Msg)
		resp.SetReply(r)
		resp.Answer = []dns.RR{&dns.SOA{
			Hdr:     dns.RR_Header{Name: r.Question[0].Name, Rrtype: dns.TypeSOA, Class: dns.ClassINET, Ttl: 30},
			Ns:      "ns." + r.Question[0].Name,
			Mbox:    "hostmaster." + r.Question[0].Name,
			Serial:  1,
			Refresh: 60,
			Retry:   60,
			Expire:  60,
			Minttl:  30,
		}}
		_ = w.WriteMsg(resp)
	})
}

func startTestDNSServerWithHandler(t *testing.T, netw string, handler dns.HandlerFunc) (*dns.Server, string) {
	t.Helper()
	addr := freeLocalAddr(t)
	server := &dns.Server{Addr: addr, Net: netw, Handler: handler}
	go func() {
		_ = server.ListenAndServe()
	}()
	time.Sleep(20 * time.Millisecond)
	return server, addr
}

func freeLocalAddr(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	if err := ln.Close(); err != nil {
		t.Fatal(err)
	}
	return addr
}

func waitForDNS(t *testing.T, addr string) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, 20*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
}
