package dnsproxy

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"strings"
	"time"

	"github.com/miekg/dns"
)

type Config struct {
	Listen   string
	Upstream string
	Verbose  bool
	Log      io.Writer
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
		if cfg.Verbose && cfg.Log != nil && len(req.Question) > 0 {
			fmt.Fprintf(cfg.Log, "dns query %s from %s\n", req.Question[0].Name, w.RemoteAddr())
		}
		resp, _, err := (&dns.Client{Net: w.RemoteAddr().Network(), Timeout: 2 * time.Second}).Exchange(req, cfg.Upstream)
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
	})

	udp := &dns.Server{Addr: cfg.Listen, Net: "udp", Handler: handler}
	tcp := &dns.Server{Addr: cfg.Listen, Net: "tcp", Handler: dns.HandlerFunc(func(w dns.ResponseWriter, req *dns.Msg) {
		forwardTCP(w, req, cfg)
	})}

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

func forwardTCP(w dns.ResponseWriter, req *dns.Msg, cfg Config) {
	in, err := req.Pack()
	if err != nil {
		servfail := new(dns.Msg)
		servfail.SetRcode(req, dns.RcodeServerFailure)
		_ = w.WriteMsg(servfail)
		return
	}
	conn, err := net.DialTimeout("tcp", cfg.Upstream, 2*time.Second)
	if err != nil {
		servfail := new(dns.Msg)
		servfail.SetRcode(req, dns.RcodeServerFailure)
		_ = w.WriteMsg(servfail)
		return
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))

	var length [2]byte
	binary.BigEndian.PutUint16(length[:], uint16(len(in)))
	if _, err := conn.Write(append(length[:], in...)); err != nil {
		return
	}
	if _, err := io.ReadFull(conn, length[:]); err != nil {
		return
	}
	n := binary.BigEndian.Uint16(length[:])
	out := make([]byte, n)
	if _, err := io.ReadFull(conn, out); err != nil {
		return
	}
	resp := new(dns.Msg)
	if err := resp.Unpack(out); err != nil {
		return
	}
	_ = w.WriteMsg(resp)
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
