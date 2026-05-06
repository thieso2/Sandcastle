package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	defaultEnvFile      = "/etc/sandcastle/oidc.env"
	defaultTokenFile    = "/run/sandcastle/oidc-token"
	defaultTokenURL     = "http://sandcastle-web:80/internal/oidc/token"
	defaultGCPTokenFile = "/run/sandcastle/oidc/gcp.jwt"
	defaultGCPCacheFile = "/run/sandcastle/oidc/gcp-executable-cache.json"
)

type runtimeConfig struct {
	TokenEndpoint string
	TokenFile     string
}

type tokenResponse struct {
	Token     string `json:"token"`
	ExpiresAt string `json:"expires_at"`
	Issuer    string `json:"issuer"`
	Subject   string `json:"subject"`
}

type executableResponse struct {
	Version        int    `json:"version"`
	Success        bool   `json:"success"`
	TokenType      string `json:"token_type,omitempty"`
	IDToken        string `json:"id_token,omitempty"`
	ExpirationTime int64  `json:"expiration_time,omitempty"`
	Code           string `json:"code,omitempty"`
	Message        string `json:"message,omitempty"`
}

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		usage(stderr)
		return errors.New("missing command")
	}

	switch args[0] {
	case "token":
		return runToken(args[1:], stdout, stderr)
	case "gcp":
		return runGCP(args[1:], stdout, stderr)
	case "-h", "--help", "help":
		usage(stdout)
		return nil
	default:
		usage(stderr)
		return fmt.Errorf("unknown command: %s", args[0])
	}
}

func runToken(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("token", flag.ContinueOnError)
	fs.SetOutput(stderr)
	audience := fs.String("audience", "", "OIDC audience")
	envFile := fs.String("env-file", defaultEnvFile, "Sandcastle OIDC env file")
	tokenFile := fs.String("token-file", "", "runtime token file")
	endpoint := fs.String("endpoint", "", "token endpoint URL")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *audience == "" {
		return errors.New("--audience is required")
	}

	cfg := loadRuntimeConfig(*envFile)
	applyOverrides(&cfg, *tokenFile, *endpoint)
	resp, err := requestOIDCToken(cfg, *audience)
	if err != nil {
		return err
	}
	fmt.Fprintln(stdout, resp.Token)
	return nil
}

func runGCP(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		return errors.New("gcp requires a subcommand: write-config, executable, or refresh")
	}

	switch args[0] {
	case "write-config":
		return runGCPWriteConfig(args[1:], stdout, stderr)
	case "refresh":
		return runGCPRefresh(args[1:], stdout, stderr)
	case "executable":
		return runGCPExecutable(args[1:], stdout, stderr)
	default:
		return fmt.Errorf("unknown gcp subcommand: %s", args[0])
	}
}

func runGCPWriteConfig(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("gcp write-config", flag.ContinueOnError)
	fs.SetOutput(stderr)
	audience := fs.String("audience", "", "GCP workload identity provider resource name")
	output := fs.String("output", "", "credential config output path")
	serviceAccount := fs.String("service-account", "", "optional service account email to impersonate")
	mode := fs.String("mode", "executable", "credential source mode: executable or file")
	tokenFile := fs.String("token-file", defaultGCPTokenFile, "subject token file path referenced by the config")
	cacheFile := fs.String("executable-cache-file", defaultGCPCacheFile, "executable response cache file path")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *audience == "" {
		return errors.New("--audience is required")
	}
	if *output == "" {
		return errors.New("--output is required")
	}

	config := map[string]any{
		"type":               "external_account",
		"audience":           *audience,
		"subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
		"token_url":          "https://sts.googleapis.com/v1/token",
	}
	switch *mode {
	case "executable":
		config["credential_source"] = map[string]any{
			"executable": map[string]any{
				"command":        "/usr/local/bin/sandcastle-oidc gcp executable --audience=" + shellQuote(*audience),
				"timeout_millis": 30000,
				"output_file":    *cacheFile,
			},
		}
	case "file":
		config["credential_source"] = map[string]any{
			"file": *tokenFile,
			"format": map[string]any{
				"type": "text",
			},
		}
	default:
		return errors.New("--mode must be executable or file")
	}
	if *serviceAccount != "" {
		config["service_account_impersonation_url"] = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/" + *serviceAccount + ":generateAccessToken"
	}

	body, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return err
	}
	if err := writeFile(*output, append(body, '\n'), 0o600); err != nil {
		return err
	}
	fmt.Fprintln(stdout, *output)
	return nil
}

func runGCPRefresh(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("gcp refresh", flag.ContinueOnError)
	fs.SetOutput(stderr)
	audience := fs.String("audience", "", "GCP workload identity provider resource name")
	outputTokenFile := fs.String("output-token-file", defaultGCPTokenFile, "token file to write")
	envFile := fs.String("env-file", defaultEnvFile, "Sandcastle OIDC env file")
	tokenFile := fs.String("token-file", "", "runtime token file")
	endpoint := fs.String("endpoint", "", "token endpoint URL")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *audience == "" {
		return errors.New("--audience is required")
	}

	cfg := loadRuntimeConfig(*envFile)
	applyOverrides(&cfg, *tokenFile, *endpoint)
	resp, err := requestOIDCToken(cfg, *audience)
	if err != nil {
		return err
	}
	if err := writeFile(*outputTokenFile, []byte(resp.Token+"\n"), 0o600); err != nil {
		return err
	}
	fmt.Fprintln(stdout, *outputTokenFile)
	return nil
}

func runGCPExecutable(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("gcp executable", flag.ContinueOnError)
	fs.SetOutput(stderr)
	audience := fs.String("audience", "", "GCP workload identity provider resource name")
	envFile := fs.String("env-file", defaultEnvFile, "Sandcastle OIDC env file")
	tokenFile := fs.String("token-file", "", "runtime token file")
	endpoint := fs.String("endpoint", "", "token endpoint URL")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *audience == "" {
		return errors.New("--audience is required")
	}

	cfg := loadRuntimeConfig(*envFile)
	applyOverrides(&cfg, *tokenFile, *endpoint)
	resp, err := requestOIDCToken(cfg, *audience)
	if err != nil {
		writeExecutableResponse(stdout, executableResponse{
			Version: 1,
			Success: false,
			Code:    "OIDC_TOKEN_REQUEST_FAILED",
			Message: err.Error(),
		})
		return err
	}

	expiresAt, err := time.Parse(time.RFC3339, resp.ExpiresAt)
	if err != nil {
		writeExecutableResponse(stdout, executableResponse{
			Version: 1,
			Success: false,
			Code:    "OIDC_TOKEN_RESPONSE_INVALID",
			Message: "invalid expires_at: " + err.Error(),
		})
		return err
	}

	return writeExecutableResponse(stdout, executableResponse{
		Version:        1,
		Success:        true,
		TokenType:      "urn:ietf:params:oauth:token-type:jwt",
		IDToken:        resp.Token,
		ExpirationTime: expiresAt.Unix(),
	})
}

func loadRuntimeConfig(envFile string) runtimeConfig {
	cfg := runtimeConfig{
		TokenEndpoint: defaultTokenURL,
		TokenFile:     defaultTokenFile,
	}
	values := parseEnvFile(envFile)
	if v := values["SANDCASTLE_OIDC_TOKEN_ENDPOINT"]; v != "" {
		cfg.TokenEndpoint = v
	}
	if v := values["SANDCASTLE_OIDC_TOKEN_FILE"]; v != "" {
		cfg.TokenFile = v
	}
	if v := os.Getenv("SANDCASTLE_OIDC_TOKEN_ENDPOINT"); v != "" {
		cfg.TokenEndpoint = v
	}
	if v := os.Getenv("SANDCASTLE_OIDC_TOKEN_FILE"); v != "" {
		cfg.TokenFile = v
	}
	return cfg
}

func applyOverrides(cfg *runtimeConfig, tokenFile, endpoint string) {
	if tokenFile != "" {
		cfg.TokenFile = tokenFile
	}
	if endpoint != "" {
		cfg.TokenEndpoint = endpoint
	}
}

func parseEnvFile(path string) map[string]string {
	values := map[string]string{}
	body, err := os.ReadFile(path)
	if err != nil {
		return values
	}
	for _, line := range strings.Split(string(body), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		values[strings.TrimSpace(key)] = strings.Trim(strings.TrimSpace(value), `"'`)
	}
	return values
}

func requestOIDCToken(cfg runtimeConfig, audience string) (*tokenResponse, error) {
	runtimeToken, err := os.ReadFile(cfg.TokenFile)
	if err != nil {
		return nil, fmt.Errorf("reading runtime token: %w", err)
	}

	requestBody, err := json.Marshal(map[string]string{"audience": audience})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest("POST", cfg.TokenEndpoint, bytes.NewReader(requestBody))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(runtimeToken)))
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("requesting OIDC token: %w", err)
	}
	defer resp.Body.Close()

	responseBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("OIDC token request failed (%d): %s", resp.StatusCode, strings.TrimSpace(string(responseBody)))
	}

	var parsed tokenResponse
	if err := json.Unmarshal(responseBody, &parsed); err != nil {
		return nil, fmt.Errorf("parsing OIDC token response: %w", err)
	}
	if parsed.Token == "" {
		return nil, errors.New("OIDC token response did not include token")
	}
	return &parsed, nil
}

func writeFile(path string, content []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, content, mode)
}

func writeExecutableResponse(w io.Writer, resp executableResponse) error {
	body, err := json.Marshal(resp)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(w, string(body))
	return err
}

func shellQuote(value string) string {
	if value == "" {
		return "''"
	}
	if strings.IndexFunc(value, func(r rune) bool {
		return !(r == '/' || r == ':' || r == '-' || r == '_' || r == '.' || r == '@' || r == '=' || r == '+' ||
			(r >= '0' && r <= '9') || (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z'))
	}) == -1 {
		return value
	}
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func usage(w io.Writer) {
	fmt.Fprintln(w, `Usage:
  sandcastle-oidc token --audience <audience>
  sandcastle-oidc gcp write-config --audience <provider> --output <path> [--service-account <email>]
  sandcastle-oidc gcp executable --audience <provider>
  sandcastle-oidc gcp refresh --audience <provider> [--output-token-file <path>]`)
}
