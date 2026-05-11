package dnsproxy

import (
	"context"
	"fmt"
	"io"
	"net"
	"strings"
	"time"

	"github.com/miekg/dns"
)

type Config struct {
	Listen    string
	Upstream  string
	Suffix    string
	Fallbacks map[string]string
	Verbose   bool
	Log       io.Writer
}

func Serve(ctx context.Context, cfg Config) error {
	host, _, err := net.SplitHostPort(cfg.Listen)
	if err != nil {
		return fmt.Errorf("invalid listen address: %w", err)
	}
	if host != "127.0.0.1" {
		return fmt.Errorf("installer-managed DNS proxy must listen on 127.0.0.1")
	}
	if _, _, err := net.SplitHostPort(cfg.Upstream); err != nil {
		return fmt.Errorf("invalid upstream address: %w", err)
	}

	handler := dns.HandlerFunc(func(w dns.ResponseWriter, req *dns.Msg) {
		handle(w, req, cfg)
	})

	udp := &dns.Server{Addr: cfg.Listen, Net: "udp", Handler: handler}
	tcp := &dns.Server{Addr: cfg.Listen, Net: "tcp", Handler: handler}

	errc := make(chan error, 2)
	go func() { errc <- udp.ListenAndServe() }()
	go func() { errc <- tcp.ListenAndServe() }()

	select {
	case <-ctx.Done():
		_ = udp.Shutdown()
		_ = tcp.Shutdown()
		return ctx.Err()
	case err := <-errc:
		_ = udp.Shutdown()
		_ = tcp.Shutdown()
		return err
	}
}

func handle(w dns.ResponseWriter, req *dns.Msg, cfg Config) {
	if cfg.Verbose && cfg.Log != nil && len(req.Question) > 0 {
		fmt.Fprintf(cfg.Log, "dns query %s from %s\n", req.Question[0].Name, w.RemoteAddr())
	}

	resp, err := exchange(req, cfg, w.RemoteAddr().Network())
	if err != nil {
		servfail := new(dns.Msg)
		servfail.SetRcode(req, dns.RcodeServerFailure)
		_ = w.WriteMsg(servfail)
		if cfg.Log != nil {
			fmt.Fprintf(cfg.Log, "dns upstream failure: %v\n", err)
		}
		return
	}
	_ = w.WriteMsg(resp)
}

func exchange(req *dns.Msg, cfg Config, network string) (*dns.Msg, error) {
	if rewritten, target, canonical := fallbackQuery(req, cfg); rewritten != nil {
		resp, _, err := (&dns.Client{Net: network, Timeout: 2 * time.Second}).Exchange(rewritten, target)
		if err != nil {
			return nil, err
		}
		return rewriteFallbackResponse(req, resp, canonical), nil
	}

	resp, _, err := (&dns.Client{Net: network, Timeout: 2 * time.Second}).Exchange(req, cfg.Upstream)
	return resp, err
}

func fallbackQuery(req *dns.Msg, cfg Config) (*dns.Msg, string, string) {
	if cfg.Suffix == "" || len(cfg.Fallbacks) == 0 || len(req.Question) != 1 {
		return nil, "", ""
	}

	suffix := normalizeName(cfg.Suffix)
	qname := normalizeName(req.Question[0].Name)
	if suffix == "" || qname == "" {
		return nil, "", ""
	}
	searchSuffix := "." + suffix
	if !strings.HasSuffix(qname, searchSuffix) {
		return nil, "", ""
	}
	canonical := strings.TrimSuffix(qname, searchSuffix)
	if canonical == "" || canonical == qname {
		return nil, "", ""
	}

	var bestSuffix, bestAddress string
	for fallbackSuffix, address := range cfg.Fallbacks {
		fallbackSuffix = normalizeName(fallbackSuffix)
		if fallbackSuffix == "" || fallbackSuffix == suffix || address == "" {
			continue
		}
		if canonical != fallbackSuffix && !strings.HasSuffix(canonical, "."+fallbackSuffix) {
			continue
		}
		if len(fallbackSuffix) > len(bestSuffix) {
			bestSuffix = fallbackSuffix
			bestAddress = address
		}
	}
	if bestAddress == "" {
		return nil, "", ""
	}

	rewritten := req.Copy()
	rewritten.Question[0].Name = dns.Fqdn(canonical)
	return rewritten, bestAddress, dns.Fqdn(canonical)
}

func rewriteFallbackResponse(original, resp *dns.Msg, canonical string) *dns.Msg {
	out := new(dns.Msg)
	out.SetReply(original)
	out.Rcode = resp.Rcode
	out.Authoritative = resp.Authoritative
	out.RecursionAvailable = resp.RecursionAvailable
	out.Compress = resp.Compress
	out.Ns = cloneRRs(resp.Ns)
	out.Extra = cloneRRs(resp.Extra)
	if resp.Rcode == dns.RcodeSuccess {
		out.Answer = append(out.Answer, &dns.CNAME{
			Hdr:    dns.RR_Header{Name: original.Question[0].Name, Rrtype: dns.TypeCNAME, Class: original.Question[0].Qclass, Ttl: 15},
			Target: canonical,
		})
	}
	out.Answer = append(out.Answer, cloneRRs(resp.Answer)...)
	return out
}

func cloneRRs(records []dns.RR) []dns.RR {
	if len(records) == 0 {
		return nil
	}
	out := make([]dns.RR, 0, len(records))
	for _, record := range records {
		out = append(out, dns.Copy(record))
	}
	return out
}

func normalizeName(name string) string {
	return strings.TrimSuffix(strings.TrimSpace(strings.ToLower(name)), ".")
}

func Probe(address, suffix string, timeout time.Duration) error {
	name := strings.TrimSuffix(suffix, ".") + "."
	q := new(dns.Msg)
	q.SetQuestion(name, dns.TypeSOA)
	q.RecursionDesired = false
	c := &dns.Client{Net: "udp", Timeout: timeout}
	resp, _, err := c.Exchange(q, address)
	if err != nil {
		return err
	}
	if resp.Id != q.Id {
		return fmt.Errorf("mismatched DNS transaction ID")
	}
	if resp.Rcode != dns.RcodeSuccess {
		return fmt.Errorf("unexpected DNS rcode %s", dns.RcodeToString[resp.Rcode])
	}
	if len(resp.Answer) == 0 {
		return fmt.Errorf("DNS response had no answers")
	}
	return nil
}
