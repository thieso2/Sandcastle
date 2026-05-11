package cmd

import (
	"strings"
	"testing"

	"github.com/sandcastle/cli/api"
)

func TestResolveSandboxRefScoped(t *testing.T) {
	sandboxes := []api.Sandbox{
		{ID: 1, Name: "dev", ProjectName: "pool"},
		{ID: 2, Name: "dev", ProjectName: "sc"},
	}

	got, err := resolveSandboxRef(sandboxes, "sc:dev")
	if err != nil {
		t.Fatalf("resolveSandboxRef returned error: %v", err)
	}
	if got.ID != 2 {
		t.Fatalf("expected sandbox id 2, got %d", got.ID)
	}
}

func TestResolveSandboxRefUniqueBareName(t *testing.T) {
	sandboxes := []api.Sandbox{
		{ID: 1, Name: "cloud", ProjectName: "io26"},
		{ID: 2, Name: "dev", ProjectName: "sc"},
	}

	got, err := resolveSandboxRef(sandboxes, "dev")
	if err != nil {
		t.Fatalf("resolveSandboxRef returned error: %v", err)
	}
	if got.ID != 2 {
		t.Fatalf("expected sandbox id 2, got %d", got.ID)
	}
}

func TestResolveSandboxRefBlankProjectUsesBareName(t *testing.T) {
	sandboxes := []api.Sandbox{
		{ID: 1, Name: "dev"},
	}

	got, err := resolveSandboxRef(sandboxes, "dev")
	if err != nil {
		t.Fatalf("resolveSandboxRef returned error: %v", err)
	}
	if got.DisplayName() != "dev" {
		t.Fatalf("expected display name dev, got %q", got.DisplayName())
	}
}

func TestResolveSandboxRefAmbiguousBareName(t *testing.T) {
	sandboxes := []api.Sandbox{
		{ID: 2, Name: "dev", ProjectName: "sc"},
		{ID: 1, Name: "dev", ProjectName: "pool"},
	}

	_, err := resolveSandboxRef(sandboxes, "dev")
	if err == nil {
		t.Fatal("expected ambiguity error")
	}
	msg := err.Error()
	for _, want := range []string{"ambiguous", "pool:dev (id 1)", "sc:dev (id 2)"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("expected error to contain %q, got %q", want, msg)
		}
	}
}

func TestParseSandboxRefRejectsMalformedRefs(t *testing.T) {
	for _, input := range []string{":dev", "sc:", "a:b:c"} {
		if _, err := parseSandboxRef(input); err == nil {
			t.Fatalf("expected %q to be rejected", input)
		}
	}
}

func TestSandboxDNSNamePrefersPrimaryDNSName(t *testing.T) {
	sandbox := api.Sandbox{
		Hostname:       "dev-sc",
		PrimaryDNSName: "dev.sc.sandman",
	}

	if got := sandboxDNSName(sandbox); got != "dev.sc.sandman" {
		t.Fatalf("sandboxDNSName() = %q, want %q", got, "dev.sc.sandman")
	}
}

func TestSandboxDNSNameFallsBackToHostname(t *testing.T) {
	sandbox := api.Sandbox{Hostname: "dev-sc"}

	if got := sandboxDNSName(sandbox); got != "dev-sc" {
		t.Fatalf("sandboxDNSName() = %q, want %q", got, "dev-sc")
	}
}

func TestSandboxSummaryRowsIncludeRuntimeAddressingAndMounts(t *testing.T) {
	sandbox := api.Sandbox{
		Name:           "dev",
		FullName:       "thies-dev-pool",
		UserName:       "thies",
		Hostname:       "dev-pool",
		PrimaryDNSName: "dev.pool.hz",
		ProjectName:    "pool",
		ProjectPath:    "pool",
		HomePath:       "pool",
		DataPath:       "pool",
		Tailscale:      true,
		TailscaleIP:    "10.143.211.5",
		DockerEnabled:  true,
		CaddyEnabled:   true,
		VNCEnabled:     false,
	}

	got := map[string]string{}
	for _, row := range sandboxSummaryRows(sandbox) {
		got[row.label] = row.value
	}

	want := map[string]string{
		"user":      "thies",
		"project":   "pool",
		"subdir":    "pool",
		"home":      "persisted (pool)",
		"data":      "persisted:/persisted (pool)",
		"tailscale": "enabled (10.143.211.5)",
		"dns":       "dev.pool.hz",
		"docker":    "enabled",
		"caddy":     "enabled (dev.pool.hz)",
		"vnc":       "disabled",
		"settings":  "/etc/sandcastle/settings",
	}
	for label, value := range want {
		if got[label] != value {
			t.Fatalf("summary %q = %q, want %q", label, got[label], value)
		}
	}
}

func TestParseCpArg(t *testing.T) {
	tests := []struct {
		input       string
		wantSandbox string
		wantPath    string
	}{
		{"dev:~/file", "dev", "~/file"},
		{"sc:dev:~/file", "sc:dev", "~/file"},
		{"C:\\Users\\thies\\file.txt", "", "C:\\Users\\thies\\file.txt"},
		{"c:/Users/thies/file.txt", "", "c:/Users/thies/file.txt"},
		{"./local:file", "", "./local:file"},
	}

	for _, tt := range tests {
		gotSandbox, gotPath := parseCpArg(tt.input)
		if gotSandbox != tt.wantSandbox || gotPath != tt.wantPath {
			t.Fatalf("parseCpArg(%q) = (%q, %q), want (%q, %q)", tt.input, gotSandbox, gotPath, tt.wantSandbox, tt.wantPath)
		}
	}
}
