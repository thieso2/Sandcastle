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
