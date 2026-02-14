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
	MountHome        bool      `json:"mount_home"`
	DataPath         string    `json:"data_path,omitempty"`
	Temporary        bool      `json:"temporary"`
	Tailscale        bool           `json:"tailscale"`
	TailscaleIP      string         `json:"tailscale_ip,omitempty"`
	Routes           []SandboxRoute `json:"routes"`
	ConnectCommand   string         `json:"connect_command"`
	CreatedAt        time.Time `json:"created_at"`
}

type SandboxRoute struct {
	ID     int    `json:"id"`
	Domain string `json:"domain"`
	Port   int    `json:"port"`
	URL    string `json:"url"`
}

type ConnectInfo struct {
	Host        string `json:"host"`
	Port        int    `json:"port"`
	User        string `json:"user"`
	Command     string `json:"command"`
	TailscaleIP string `json:"tailscale_ip,omitempty"`
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

type ServerInfo struct {
	Version   string           `json:"version"`
	Rails     string           `json:"rails"`
	Ruby      string           `json:"ruby"`
	Host      ServerHostInfo   `json:"host"`
	Sandboxes map[string]int   `json:"sandboxes"`
	Docker    ServerDockerInfo `json:"docker"`
	Users     ServerUserCounts `json:"users"`
}

type ServerHostInfo struct {
	Memory    HostMemory `json:"memory"`
	Disk      HostDisk   `json:"disk"`
	Load      HostLoad   `json:"load"`
	CPUCount  int        `json:"cpu_count"`
	Uptime    string     `json:"uptime"`
	Processes int        `json:"processes"`
}

type HostMemory struct {
	TotalGB     float64 `json:"total_gb"`
	UsedGB      float64 `json:"used_gb"`
	AvailableGB float64 `json:"available_gb"`
	Percent     float64 `json:"percent"`
}

type HostDisk struct {
	TotalGB     float64 `json:"total_gb"`
	UsedGB      float64 `json:"used_gb"`
	AvailableGB float64 `json:"available_gb"`
	Percent     float64 `json:"percent"`
}

type HostLoad struct {
	One     float64 `json:"one"`
	Five    float64 `json:"five"`
	Fifteen float64 `json:"fifteen"`
}

type ServerDockerInfo struct {
	Version           string   `json:"version"`
	Containers        int      `json:"containers"`
	ContainersRunning int      `json:"containers_running"`
	Images            int      `json:"images"`
	Runtimes          []string `json:"runtimes"`
}

type ServerUserCounts struct {
	Total  int `json:"total"`
	Admins int `json:"admins"`
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

type RouteRequest struct {
	Domain string `json:"domain"`
	Port   int    `json:"port,omitempty"`
}

type RouteResponse struct {
	ID          int    `json:"id"`
	SandboxID   int    `json:"sandbox_id"`
	SandboxName string `json:"sandbox_name"`
	Domain      string `json:"domain"`
	Port        int    `json:"port"`
	URL         string `json:"url"`
}

type CreateSandboxRequest struct {
	Name       string `json:"name"`
	Image      string `json:"image,omitempty"`
	Persistent bool   `json:"persistent,omitempty"`
	Snapshot   string `json:"snapshot,omitempty"`
	Tailscale  bool   `json:"tailscale,omitempty"`
	MountHome  bool   `json:"mount_home,omitempty"`
	DataPath   string `json:"data_path,omitempty"`
	Temporary  bool   `json:"temporary,omitempty"`
}

type UpdateSandboxRequest struct {
	Temporary *bool `json:"temporary,omitempty"`
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

type TailscaleLoginResponse struct {
	LoginURL string `json:"login_url"`
}

type TailscaleLoginStatus struct {
	Status      string `json:"status"`
	TailscaleIP string `json:"tailscale_ip,omitempty"`
	Hostname    string `json:"hostname,omitempty"`
	Tailnet     string `json:"tailnet,omitempty"`
	Error       string `json:"error,omitempty"`
}

type TailscaleStatus struct {
	Running            bool                `json:"running"`
	ContainerID        string              `json:"container_id"`
	Network            string              `json:"network"`
	ConnectedSandboxes int                 `json:"connected_sandboxes"`
	TailscaleIP        string              `json:"tailscale_ip"`
	Hostname           string              `json:"hostname"`
	Tailnet            string              `json:"tailnet"`
	Online             bool                `json:"online"`
	Sandboxes          []TailscaleSandbox  `json:"sandboxes"`
}

type TailscaleSandbox struct {
	Name string `json:"name"`
	IP   string `json:"ip"`
}

type APIError struct {
	Error string `json:"error"`
}

// Device auth types

type DeviceCodeRequest struct {
	ClientName string `json:"client_name"`
}

type DeviceCodeResponse struct {
	DeviceCode      string `json:"device_code"`
	UserCode        string `json:"user_code"`
	VerificationURL string `json:"verification_url"`
	ExpiresIn       int    `json:"expires_in"`
	Interval        int    `json:"interval"`
}

type DeviceTokenRequest struct {
	DeviceCode string `json:"device_code"`
}

type DeviceTokenResponse struct {
	Token string `json:"token"`
	Error string `json:"error,omitempty"`
}
