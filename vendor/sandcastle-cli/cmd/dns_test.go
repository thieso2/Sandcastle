package cmd

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/sandcastle/cli/api"
)

func TestHostsNamesForRecordsUsesFQDNAsCanonicalAndDropsAmbiguousAliases(t *testing.T) {
	records := []api.DNSRecord{
		{Name: "tubu.sc.sandman", IP: "10.206.10.3", SandboxID: 93, Expand: true},
		{Name: "admin.tubu.sc.sandman", IP: "10.206.10.3", SandboxID: 93, Expand: true},
		{Name: "cloud.io26.sandman", IP: "10.206.10.6", SandboxID: 95, Expand: true},
		{Name: "admin.cloud.io26.sandman", IP: "10.206.10.6", SandboxID: 95, Expand: true},
	}

	got := hostsNamesForRecords(records)
	want := [][]string{
		{"tubu.sc.sandman", "tubu", "tubu.sc"},
		{"admin.tubu.sc.sandman", "admin.tubu", "admin.tubu.sc"},
		{"cloud.io26.sandman", "cloud", "cloud.io26"},
		{"admin.cloud.io26.sandman", "admin.cloud", "admin.cloud.io26"},
	}

	if !reflect.DeepEqual(got, want) {
		t.Fatalf("hostsNamesForRecords() = %#v, want %#v", got, want)
	}
}

func TestHostsNamesForRecordsDoesNotExpandFQDNAliases(t *testing.T) {
	records := []api.DNSRecord{
		{Name: "www.example.com", IP: "10.206.10.7", SandboxID: 100, Expand: false},
	}

	got := hostsNamesForRecords(records)
	want := [][]string{{"www.example.com"}}

	if !reflect.DeepEqual(got, want) {
		t.Fatalf("hostsNamesForRecords() = %#v, want %#v", got, want)
	}
}

func TestRenderResolverFileUsesLocalProxyMetadata(t *testing.T) {
	content := renderResolverFile(dnsProxyState{
		Suffix:          "sandcastle.test",
		LocalAddress:    "127.0.0.1:15432",
		UpstreamAddress: "100.64.0.2:53",
		ServerAlias:     "dev",
		ServerURL:       "https://sandcastle.test",
	})

	for _, want := range []string{
		resolverMarker,
		"# sandcastle_resolver_version: 2",
		"# sandcastle_server_alias: dev",
		"# sandcastle_server_url: https://sandcastle.test",
		"# sandcastle_upstream: 100.64.0.2:53",
		"domain sandcastle.test",
		"nameserver 127.0.0.1",
		"port 15432",
		"search_order 1",
	} {
		if !strings.Contains(content, want) {
			t.Fatalf("resolver content missing %q:\n%s", want, content)
		}
	}
}

func TestParseResolverFileStates(t *testing.T) {
	dir := t.TempDir()
	old := resolverRoot
	resolverRoot = dir
	t.Cleanup(func() { resolverRoot = old })

	info, err := parseResolverFile("sandcastle.test")
	if err != nil {
		t.Fatal(err)
	}
	if info.State != "missing" {
		t.Fatalf("state=%q, want missing", info.State)
	}

	if err := os.WriteFile(filepath.Join(dir, "sandcastle.test"), []byte("nameserver 1.1.1.1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	info, err = parseResolverFile("sandcastle.test")
	if err != nil {
		t.Fatal(err)
	}
	if info.State != "unmanaged" {
		t.Fatalf("state=%q, want unmanaged", info.State)
	}

	if err := os.WriteFile(filepath.Join(dir, "sandcastle.test"), []byte(resolverMarker+"\n# Server: sandcastle.test\nnameserver 100.64.0.2\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	info, err = parseResolverFile("sandcastle.test")
	if err != nil {
		t.Fatal(err)
	}
	if info.State != "legacy" || !info.Legacy {
		t.Fatalf("state=%q legacy=%t, want legacy", info.State, info.Legacy)
	}

	if err := os.WriteFile(filepath.Join(dir, "sandcastle.test"), []byte(renderResolverFile(dnsProxyState{
		Suffix:          "sandcastle.test",
		LocalAddress:    "127.0.0.1:15432",
		UpstreamAddress: "100.64.0.2:53",
		ServerAlias:     "dev",
		ServerURL:       "https://sandcastle.test",
	})), 0o600); err != nil {
		t.Fatal(err)
	}
	info, err = parseResolverFile("sandcastle.test")
	if err != nil {
		t.Fatal(err)
	}
	if info.State != "proxy" || info.Nameserver != "127.0.0.1" || info.Port != 15432 || info.Upstream != "100.64.0.2:53" {
		t.Fatalf("unexpected proxy parse: %#v", info)
	}
}

func TestDNSStatePreservesSearchAndRoundTripsProxy(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	state := &dnsState{
		Version: 2,
		Search: map[string]map[string]managedSearchDomain{
			"Wi-Fi": {"sandcastle.test": {AddedBySandcastle: true}},
		},
		Proxies: map[string]dnsProxyState{
			"sandcastle.test": {
				Suffix:          "sandcastle.test",
				LocalAddress:    "127.0.0.1:15432",
				UpstreamAddress: "100.64.0.2:53",
				ServerAlias:     "dev",
			},
		},
	}
	if err := saveDNSState(state); err != nil {
		t.Fatal(err)
	}
	got, err := loadDNSState()
	if err != nil {
		t.Fatal(err)
	}
	if !got.Search["Wi-Fi"]["sandcastle.test"].AddedBySandcastle {
		t.Fatalf("search state not preserved: %#v", got.Search)
	}
	if got.Proxies["sandcastle.test"].UpstreamAddress != "100.64.0.2:53" {
		t.Fatalf("proxy state not preserved: %#v", got.Proxies)
	}
}

func TestResolveUninstallTargetRequiresSuffixWhenMultipleProxiesExist(t *testing.T) {
	state := &dnsState{Proxies: map[string]dnsProxyState{
		"one.test": {},
		"two.test": {},
	}}
	if _, _, err := resolveUninstallTarget("", state); err == nil {
		t.Fatal("resolveUninstallTarget succeeded without suffix for multiple proxies")
	}
	suffix, _, err := resolveUninstallTarget("one.test.", state)
	if err != nil {
		t.Fatal(err)
	}
	if suffix != "one.test" {
		t.Fatalf("suffix=%q, want one.test", suffix)
	}
}

func TestRenderLaunchAgentUsesProxyServeCommandAndLogs(t *testing.T) {
	content := renderLaunchAgent(dnsProxyState{
		LocalAddress:    "127.0.0.1:15432",
		UpstreamAddress: "100.64.0.2:53",
		LaunchdLabel:    "dev.sandcastle.dns.sandcastle-test.abcdef12",
		StdoutLogPath:   "/tmp/sandcastle.out.log",
		StderrLogPath:   "/tmp/sandcastle.err.log",
	}, "/opt/homebrew/bin/sandcastle")

	for _, want := range []string{
		"<string>dev.sandcastle.dns.sandcastle-test.abcdef12</string>",
		"<string>/opt/homebrew/bin/sandcastle</string>",
		"<string>dns</string>",
		"<string>proxy</string>",
		"<string>serve</string>",
		"<string>127.0.0.1:15432</string>",
		"<string>100.64.0.2:53</string>",
		"<key>RunAtLoad</key>",
		"<key>KeepAlive</key>",
		"<string>/tmp/sandcastle.out.log</string>",
		"<string>/tmp/sandcastle.err.log</string>",
	} {
		if !strings.Contains(content, want) {
			t.Fatalf("launch agent missing %q:\n%s", want, content)
		}
	}
}
