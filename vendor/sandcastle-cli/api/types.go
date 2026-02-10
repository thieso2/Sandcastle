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
	ID         int        `json:"id"`
	Name       string     `json:"name"`
	Prefix     string     `json:"prefix"`
	MaskedToken string    `json:"masked_token"`
	RawToken   string     `json:"raw_token,omitempty"`
	LastUsedAt *time.Time `json:"last_used_at"`
	ExpiresAt  *time.Time `json:"expires_at"`
	CreatedAt  time.Time  `json:"created_at"`
}

type SystemStatus struct {
	Docker    map[string]any   `json:"docker"`
	Sandboxes map[string]int   `json:"sandboxes"`
	Resources []map[string]any `json:"resources"`
}

type Snapshot struct {
	Name      string    `json:"name"`
	Image     string    `json:"image"`
	Sandbox   string    `json:"sandbox"`
	Size      int64     `json:"size"`
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

type TailscaleEnableRequest struct {
	AuthKey string `json:"auth_key"`
}

type TailscaleStatus struct {
	Running            bool   `json:"running"`
	ContainerID        string `json:"container_id"`
	Network            string `json:"network"`
	ConnectedSandboxes int    `json:"connected_sandboxes"`
	TailscaleIP        string `json:"tailscale_ip"`
	Hostname           string `json:"hostname"`
	Tailnet            string `json:"tailnet"`
	Online             bool   `json:"online"`
}

type APIError struct {
	Error string `json:"error"`
}
