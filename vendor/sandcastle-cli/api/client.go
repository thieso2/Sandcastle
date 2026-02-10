package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	"github.com/sandcastle/cli/internal/config"
)

type Client struct {
	BaseURL    string
	Token      string
	HTTPClient *http.Client
}

func NewClient() (*Client, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, err
	}
	srv, err := cfg.CurrentServerConfig()
	if err != nil {
		return nil, err
	}
	return &Client{
		BaseURL:    srv.URL,
		Token:      srv.Token,
		HTTPClient: &http.Client{},
	}, nil
}

func NewClientWithToken(baseURL, token string) *Client {
	return &Client{
		BaseURL:    baseURL,
		Token:      token,
		HTTPClient: &http.Client{},
	}
}

func (c *Client) do(method, path string, body any, result any) error {
	var bodyReader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("marshaling request: %w", err)
		}
		bodyReader = bytes.NewReader(data)
	}

	req, err := http.NewRequest(method, c.BaseURL+path, bodyReader)
	if err != nil {
		return fmt.Errorf("creating request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("reading response: %w", err)
	}

	if resp.StatusCode >= 400 {
		var apiErr APIError
		if json.Unmarshal(respBody, &apiErr) == nil && apiErr.Error != "" {
			return fmt.Errorf("API error (%d): %s", resp.StatusCode, apiErr.Error)
		}
		return fmt.Errorf("API error (%d): %s", resp.StatusCode, string(respBody))
	}

	if result != nil {
		if err := json.Unmarshal(respBody, result); err != nil {
			return fmt.Errorf("parsing response: %w", err)
		}
	}
	return nil
}

// doWithStatus is like do but returns the HTTP status code along with the response body.
func (c *Client) doWithStatus(method, path string, body any) (int, []byte, error) {
	var bodyReader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return 0, nil, fmt.Errorf("marshaling request: %w", err)
		}
		bodyReader = bytes.NewReader(data)
	}

	req, err := http.NewRequest(method, c.BaseURL+path, bodyReader)
	if err != nil {
		return 0, nil, fmt.Errorf("creating request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return 0, nil, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, nil, fmt.Errorf("reading response: %w", err)
	}

	return resp.StatusCode, respBody, nil
}

// Device Auth

func (c *Client) RequestDeviceCode(clientName string) (*DeviceCodeResponse, error) {
	var resp DeviceCodeResponse
	err := c.do("POST", "/api/auth/device_code", DeviceCodeRequest{ClientName: clientName}, &resp)
	return &resp, err
}

func (c *Client) PollDeviceToken(deviceCode string) (token string, pending bool, err error) {
	status, body, err := c.doWithStatus("POST", "/api/auth/device_token", DeviceTokenRequest{DeviceCode: deviceCode})
	if err != nil {
		return "", false, err
	}

	switch status {
	case 200:
		var resp DeviceTokenResponse
		if err := json.Unmarshal(body, &resp); err != nil {
			return "", false, fmt.Errorf("parsing response: %w", err)
		}
		return resp.Token, false, nil
	case 428: // Precondition Required — authorization_pending
		return "", true, nil
	default:
		var apiErr APIError
		if json.Unmarshal(body, &apiErr) == nil && apiErr.Error != "" {
			return "", false, fmt.Errorf("%s", apiErr.Error)
		}
		return "", false, fmt.Errorf("unexpected status %d: %s", status, string(body))
	}
}

// Sandboxes

func (c *Client) ListSandboxes() ([]Sandbox, error) {
	var sandboxes []Sandbox
	err := c.do("GET", "/api/sandboxes", nil, &sandboxes)
	return sandboxes, err
}

func (c *Client) GetSandbox(id int) (*Sandbox, error) {
	var s Sandbox
	err := c.do("GET", fmt.Sprintf("/api/sandboxes/%d", id), nil, &s)
	return &s, err
}

func (c *Client) CreateSandbox(req CreateSandboxRequest) (*Sandbox, error) {
	var s Sandbox
	err := c.do("POST", "/api/sandboxes", req, &s)
	return &s, err
}

func (c *Client) DestroySandbox(id int) error {
	return c.do("DELETE", fmt.Sprintf("/api/sandboxes/%d", id), nil, nil)
}

func (c *Client) StartSandbox(id int) (*Sandbox, error) {
	var s Sandbox
	err := c.do("POST", fmt.Sprintf("/api/sandboxes/%d/start", id), nil, &s)
	return &s, err
}

func (c *Client) StopSandbox(id int) (*Sandbox, error) {
	var s Sandbox
	err := c.do("POST", fmt.Sprintf("/api/sandboxes/%d/stop", id), nil, &s)
	return &s, err
}

func (c *Client) ConnectInfo(id int) (*ConnectInfo, error) {
	var info ConnectInfo
	err := c.do("POST", fmt.Sprintf("/api/sandboxes/%d/connect", id), nil, &info)
	return &info, err
}

// Routes

func (c *Client) AddRoute(sandboxID int, req RouteRequest) (*RouteResponse, error) {
	var r RouteResponse
	err := c.do("POST", fmt.Sprintf("/api/sandboxes/%d/route", sandboxID), req, &r)
	return &r, err
}

func (c *Client) GetRoute(sandboxID int) (*RouteResponse, error) {
	var r RouteResponse
	err := c.do("GET", fmt.Sprintf("/api/sandboxes/%d/route", sandboxID), nil, &r)
	return &r, err
}

func (c *Client) RemoveRoute(sandboxID int) error {
	return c.do("DELETE", fmt.Sprintf("/api/sandboxes/%d/route", sandboxID), nil, nil)
}

// Snapshots

func (c *Client) SnapshotSandbox(id int, name string) (*Snapshot, error) {
	var s Snapshot
	err := c.do("POST", fmt.Sprintf("/api/sandboxes/%d/snapshot", id), SnapshotRequest{Name: name}, &s)
	return &s, err
}

func (c *Client) RestoreSandbox(id int, snapshot string) (*Sandbox, error) {
	var s Sandbox
	err := c.do("POST", fmt.Sprintf("/api/sandboxes/%d/restore", id), RestoreRequest{Snapshot: snapshot}, &s)
	return &s, err
}

func (c *Client) ListSnapshots() ([]Snapshot, error) {
	var snapshots []Snapshot
	err := c.do("GET", "/api/snapshots", nil, &snapshots)
	return snapshots, err
}

func (c *Client) DestroySnapshot(name string) error {
	return c.do("DELETE", fmt.Sprintf("/api/snapshots/%s", name), nil, nil)
}

// Tokens

func (c *Client) CreateToken(req CreateTokenRequest) (*Token, error) {
	var t Token
	err := c.do("POST", "/api/tokens", req, &t)
	return &t, err
}

func (c *Client) ListTokens() ([]Token, error) {
	var tokens []Token
	err := c.do("GET", "/api/tokens", nil, &tokens)
	return tokens, err
}

func (c *Client) DestroyToken(id int) error {
	return c.do("DELETE", fmt.Sprintf("/api/tokens/%d", id), nil, nil)
}

// Users (admin)

func (c *Client) ListUsers() ([]User, error) {
	var users []User
	err := c.do("GET", "/api/users", nil, &users)
	return users, err
}

func (c *Client) CreateUser(req CreateUserRequest) (*User, error) {
	var u User
	err := c.do("POST", "/api/users", req, &u)
	return &u, err
}

func (c *Client) DestroyUser(id int) error {
	return c.do("DELETE", fmt.Sprintf("/api/users/%d", id), nil, nil)
}

// Status

func (c *Client) Status() (*SystemStatus, error) {
	var s SystemStatus
	err := c.do("GET", "/api/status", nil, &s)
	return &s, err
}

// Tailscale

func (c *Client) TailscaleEnable(authKey string) error {
	return c.do("POST", "/api/tailscale/enable", TailscaleEnableRequest{AuthKey: authKey}, nil)
}

func (c *Client) TailscaleLogin() (*TailscaleLoginResponse, error) {
	var resp TailscaleLoginResponse
	err := c.do("POST", "/api/tailscale/login", nil, &resp)
	return &resp, err
}

func (c *Client) TailscaleLoginStatus() (*TailscaleLoginStatus, error) {
	var s TailscaleLoginStatus
	err := c.do("GET", "/api/tailscale/login_status", nil, &s)
	return &s, err
}

func (c *Client) TailscaleDisable() error {
	return c.do("DELETE", "/api/tailscale/disable", nil, nil)
}

func (c *Client) TailscaleStatus() (*TailscaleStatus, error) {
	var s TailscaleStatus
	err := c.do("GET", "/api/tailscale/status", nil, &s)
	return &s, err
}

func (c *Client) TailscaleConnect(sandboxID int) (*Sandbox, error) {
	var s Sandbox
	err := c.do("POST", fmt.Sprintf("/api/sandboxes/%d/tailscale_connect", sandboxID), nil, &s)
	return &s, err
}

func (c *Client) TailscaleDisconnect(sandboxID int) (*Sandbox, error) {
	var s Sandbox
	err := c.do("DELETE", fmt.Sprintf("/api/sandboxes/%d/tailscale_disconnect", sandboxID), nil, &s)
	return &s, err
}
