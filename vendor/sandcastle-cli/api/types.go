package api

import "time"

type Sandbox struct {
	ID               int       `json:"id"`
	Name             string    `json:"name"`
	FullName         string    `json:"full_name"`
	Status           string    `json:"status"`
	Image            string    `json:"image"`
	SSHPort          int       `json:"ssh_port"`
	PersistentVolume bool      `json:"persistent_volume"`
	Tailscale        bool      `json:"tailscale"`
	TailscaleIP      string    `json:"tailscale_ip,omitempty"`
	ConnectCommand   string    `json:"connect_command"`
	CreatedAt        time.Time `json:"created_at"`
}

type ConnectInfo struct {
	Host    string `json:"host"`
	Port    int    `json:"port"`
	User    string `json:"user"`
	Command string `json:"command"`
}

type User struct {
	ID           int       `json:"id"`
	Name         string    `json:"name"`
	EmailAddress string    `json:"email_address"`
	Admin        bool      `json:"admin"`
	Status       string    `json:"status"`
	SandboxCount int       `json:"sandbox_count"`
	CreatedAt    time.Time `json:"created_at"`
}

type Token struct {
	ID          int        `json:"id"`
	Name        string     `json:"name"`
	Prefix      string     `json:"prefix"`
	MaskedToken string     `json:"masked_token"`
	RawToken    string     `json:"raw_token,omitempty"`
	LastUsedAt  *time.Time `json:"last_used_at"`
	ExpiresAt   *time.Time `json:"expires_at"`
	CreatedAt   time.Time  `json:"created_at"`
}

type SystemStatus struct {
	Incus     map[string]any   `json:"incus"`
	Sandboxes map[string]int   `json:"sandboxes"`
	Resources []map[string]any `json:"resources"`
}

type Snapshot struct {
	Name      string    `json:"name"`
	Sandbox   string    `json:"sandbox"`
	CreatedAt time.Time `json:"created_at"`
}

type SnapshotRequest struct {
	Name string `json:"name,omitempty"`
}

type RestoreRequest struct {
	Snapshot string `json:"snapshot"`
}

type CreateSandboxRequest struct {
	Name       string `json:"name"`
	Image      string `json:"image,omitempty"`
	Persistent bool   `json:"persistent,omitempty"`
	Snapshot   string `json:"snapshot,omitempty"`
	Tailscale  bool   `json:"tailscale,omitempty"`
}

type CreateTokenRequest struct {
	EmailAddress string `json:"email_address"`
	Password     string `json:"password"`
	Name         string `json:"name"`
}

type CreateUserRequest struct {
	Name                 string `json:"name"`
	EmailAddress         string `json:"email_address"`
	Password             string `json:"password"`
	PasswordConfirmation string `json:"password_confirmation"`
	SSHPublicKey         string `json:"ssh_public_key,omitempty"`
	Admin                bool   `json:"admin,omitempty"`
}

type TailscaleConfig struct {
	Configured bool `json:"configured"`
	AutoConnect bool `json:"auto_connect"`
	AuthKeySet bool `json:"auth_key_set"`
}

type TailscaleUpdateRequest struct {
	AuthKey string `json:"auth_key"`
}

type APIError struct {
	Error string `json:"error"`
}
