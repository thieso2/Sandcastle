package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTokenCommandRequestsToken(t *testing.T) {
	dir := t.TempDir()
	runtimeTokenPath := filepath.Join(dir, "runtime-token")
	envPath := filepath.Join(dir, "oidc.env")
	if err := os.WriteFile(runtimeTokenPath, []byte("runtime-secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer runtime-secret" {
			t.Fatalf("unexpected authorization header: %q", r.Header.Get("Authorization"))
		}
		var body map[string]string
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if body["audience"] != "aud" {
			t.Fatalf("unexpected audience: %q", body["audience"])
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"token":"jwt","expires_at":"2026-01-01T00:00:00Z","issuer":"issuer","subject":"sub"}`))
	}))
	defer server.Close()

	env := "SANDCASTLE_OIDC_TOKEN_ENDPOINT=" + server.URL + "\nSANDCASTLE_OIDC_TOKEN_FILE=" + runtimeTokenPath + "\n"
	if err := os.WriteFile(envPath, []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	err := run([]string{"token", "--audience", "aud", "--env-file", envPath}, &stdout, &stderr)
	if err != nil {
		t.Fatalf("run failed: %v\nstderr: %s", err, stderr.String())
	}
	if strings.TrimSpace(stdout.String()) != "jwt" {
		t.Fatalf("unexpected stdout: %q", stdout.String())
	}
}

func TestGCPWriteConfig(t *testing.T) {
	output := filepath.Join(t.TempDir(), "gcp.json")

	var stdout, stderr bytes.Buffer
	err := run([]string{
		"gcp", "write-config",
		"--audience", "//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/provider",
		"--output", output,
		"--mode", "file",
		"--token-file", "/tmp/gcp.jwt",
		"--service-account", "sa@example.iam.gserviceaccount.com",
	}, &stdout, &stderr)
	if err != nil {
		t.Fatalf("run failed: %v\nstderr: %s", err, stderr.String())
	}

	body, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	var config map[string]any
	if err := json.Unmarshal(body, &config); err != nil {
		t.Fatal(err)
	}
	if config["type"] != "external_account" {
		t.Fatalf("unexpected type: %v", config["type"])
	}
	source := config["credential_source"].(map[string]any)
	if source["file"] != "/tmp/gcp.jwt" {
		t.Fatalf("unexpected credential source file: %v", source["file"])
	}
	if !strings.Contains(config["service_account_impersonation_url"].(string), "sa@example.iam.gserviceaccount.com") {
		t.Fatalf("missing service account URL: %v", config["service_account_impersonation_url"])
	}
}

func TestGCPWriteConfigDefaultsToExecutableSource(t *testing.T) {
	output := filepath.Join(t.TempDir(), "gcp.json")

	var stdout, stderr bytes.Buffer
	err := run([]string{
		"gcp", "write-config",
		"--audience", "//iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/providers/provider",
		"--output", output,
	}, &stdout, &stderr)
	if err != nil {
		t.Fatalf("run failed: %v\nstderr: %s", err, stderr.String())
	}

	body, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	var config map[string]any
	if err := json.Unmarshal(body, &config); err != nil {
		t.Fatal(err)
	}
	source := config["credential_source"].(map[string]any)
	executable := source["executable"].(map[string]any)
	command := executable["command"].(string)
	if !strings.Contains(command, "/usr/local/bin/sandcastle-oidc gcp executable --audience=") {
		t.Fatalf("unexpected executable command: %q", command)
	}
	if executable["output_file"] != defaultGCPCacheFile {
		t.Fatalf("unexpected output file: %v", executable["output_file"])
	}
}

func TestGCPRefreshWritesTokenFile(t *testing.T) {
	dir := t.TempDir()
	runtimeTokenPath := filepath.Join(dir, "runtime-token")
	envPath := filepath.Join(dir, "oidc.env")
	outputTokenPath := filepath.Join(dir, "gcp.jwt")
	if err := os.WriteFile(runtimeTokenPath, []byte("runtime-secret"), 0o600); err != nil {
		t.Fatal(err)
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"token":"fresh-jwt"}`))
	}))
	defer server.Close()

	env := "SANDCASTLE_OIDC_TOKEN_ENDPOINT=" + server.URL + "\nSANDCASTLE_OIDC_TOKEN_FILE=" + runtimeTokenPath + "\n"
	if err := os.WriteFile(envPath, []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	err := run([]string{
		"gcp", "refresh",
		"--audience", "aud",
		"--env-file", envPath,
		"--output-token-file", outputTokenPath,
	}, &stdout, &stderr)
	if err != nil {
		t.Fatalf("run failed: %v\nstderr: %s", err, stderr.String())
	}

	body, err := os.ReadFile(outputTokenPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(body)) != "fresh-jwt" {
		t.Fatalf("unexpected token file body: %q", string(body))
	}
}

func TestGCPExecutableWritesGoogleExternalAccountResponse(t *testing.T) {
	dir := t.TempDir()
	runtimeTokenPath := filepath.Join(dir, "runtime-token")
	envPath := filepath.Join(dir, "oidc.env")
	if err := os.WriteFile(runtimeTokenPath, []byte("runtime-secret"), 0o600); err != nil {
		t.Fatal(err)
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"token":"fresh-jwt","expires_at":"2026-01-01T00:00:00Z"}`))
	}))
	defer server.Close()

	env := "SANDCASTLE_OIDC_TOKEN_ENDPOINT=" + server.URL + "\nSANDCASTLE_OIDC_TOKEN_FILE=" + runtimeTokenPath + "\n"
	if err := os.WriteFile(envPath, []byte(env), 0o600); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	err := run([]string{
		"gcp", "executable",
		"--audience", "aud",
		"--env-file", envPath,
	}, &stdout, &stderr)
	if err != nil {
		t.Fatalf("run failed: %v\nstderr: %s", err, stderr.String())
	}

	var response executableResponse
	if err := json.Unmarshal(stdout.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if !response.Success || response.IDToken != "fresh-jwt" {
		t.Fatalf("unexpected executable response: %+v", response)
	}
	if response.TokenType != "urn:ietf:params:oauth:token-type:jwt" {
		t.Fatalf("unexpected token type: %q", response.TokenType)
	}
	if response.ExpirationTime != 1767225600 {
		t.Fatalf("unexpected expiration: %d", response.ExpirationTime)
	}
}
