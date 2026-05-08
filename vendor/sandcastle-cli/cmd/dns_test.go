package cmd

import (
	"reflect"
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
