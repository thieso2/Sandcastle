package api

import "time"

type Sandbox struct {
	ID                     int            `json:"id"`
	Name                   string         `json:"name"`
	FullName               string         `json:"full_name"`
	Hostname               string         `json:"hostname,omitempty"`
	Status                 string         `json:"status"`
	Image                  string         `json:"image"`
	SSHPort                int            `json:"ssh_port,omitempty"`
	ProjectName            string         `json:"project_name,omitempty"`
	MountHome              bool           `json:"mount_home"`
	HomePath               string         `json:"home_path,omitempty"`
	DataPath               string         `json:"data_path,omitempty"`
	ProjectPath            string         `json:"project_path,omitempty"`
	StorageMode            string         `json:"storage_mode,omitempty"`
	Temporary              bool           `json:"temporary"`
	Tailscale              bool           `json:"tailscale"`
	TailscaleIP            string         `json:"tailscale_ip,omitempty"`
	VNCEnabled             bool           `json:"vnc_enabled"`
	VNCGeometry            string         `json:"vnc_geometry,omitempty"`
	VNCDepth               int            `json:"vnc_depth,omitempty"`
	DockerEnabled          bool           `json:"docker_enabled"`
	SMBEnabled             bool           `json:"smb_enabled"`
	OIDCEnabled            bool           `json:"oidc_enabled"`
	GCPOIDCEnabled         bool           `json:"gcp_oidc_enabled"`
	GCPOIDCConfigID        int            `json:"gcp_oidc_config_id,omitempty"`
	GCPOIDCConfig          *GcpOidcConfig `json:"gcp_oidc_config,omitempty"`
	GCPServiceAccountEmail string         `json:"gcp_service_account_email,omitempty"`
	GCPPrincipalScope      string         `json:"gcp_principal_scope,omitempty"`
	GCPRoles               []string       `json:"gcp_roles,omitempty"`
	GCPOIDCConfigured      bool           `json:"gcp_oidc_configured"`
	Routes                 []SandboxRoute `json:"routes"`
	ConnectCommand         string         `json:"connect_command"`
	ImageBuiltAt           *time.Time     `json:"image_built_at,omitempty"`
	CreatedAt              time.Time      `json:"created_at"`
	ArchivedAt             *time.Time     `json:"archived_at,omitempty"`
}

// DisplayName returns "<project>:<name>" when the sandbox is bound to a
// project, else just the sandbox name. Use this anywhere the sandbox is
// surfaced to a human; keep using Name for identity / API lookups.
func (s Sandbox) DisplayName() string {
	if s.ProjectName == "" {
		return s.Name
	}
	return s.ProjectName + ":" + s.Name
}

type SandboxRoute struct {
	ID         int    `json:"id"`
	Domain     string `json:"domain,omitempty"`
	Port       int    `json:"port"`
	URL        string `json:"url,omitempty"`
	Mode       string `json:"mode"`
	PublicPort int    `json:"public_port,omitempty"`
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
	Name          string   `json:"name"`
	Label         string   `json:"label,omitempty"`
	SourceSandbox string   `json:"source_sandbox,omitempty"`
	Layers        []string `json:"layers,omitempty"`
	// Legacy field for backward compat
	Image       string `json:"image,omitempty"`
	DockerImage string `json:"docker_image,omitempty"`
	DockerSize  int64  `json:"docker_size,omitempty"`
	HomeSize    int64  `json:"home_size,omitempty"`
	DataSize    int64  `json:"data_size,omitempty"`
	TotalSize   int64  `json:"total_size,omitempty"`
	// Legacy size field
	Size int64 `json:"size,omitempty"`
	// Legacy sandbox field
	Sandbox   string    `json:"sandbox,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

type SnapshotRequest struct {
	Name       string   `json:"name,omitempty"`
	Label      string   `json:"label,omitempty"`
	Layers     []string `json:"layers,omitempty"`
	DataSubdir string   `json:"data_subdir,omitempty"`
}

type CreateSnapshotRequest struct {
	SandboxID  int      `json:"sandbox_id"`
	Name       string   `json:"name"`
	Label      string   `json:"label,omitempty"`
	Layers     []string `json:"layers,omitempty"`
	DataSubdir string   `json:"data_subdir,omitempty"`
}

type RestoreRequest struct {
	Snapshot string   `json:"snapshot"`
	Layers   []string `json:"layers,omitempty"`
}

type RouteRequest struct {
	Domain string `json:"domain,omitempty"`
	Port   int    `json:"port,omitempty"`
	Mode   string `json:"mode,omitempty"`
}

type RouteResponse struct {
	ID          int    `json:"id"`
	SandboxID   int    `json:"sandbox_id"`
	SandboxName string `json:"sandbox_name"`
	Domain      string `json:"domain,omitempty"`
	Port        int    `json:"port"`
	Mode        string `json:"mode"`
	PublicPort  int    `json:"public_port,omitempty"`
	URL         string `json:"url,omitempty"`
}

type CreateSandboxRequest struct {
	Name                   string   `json:"name"`
	Image                  string   `json:"image,omitempty"`
	Snapshot               string   `json:"snapshot,omitempty"`
	FromSnapshot           string   `json:"from_snapshot,omitempty"`
	RestoreLayers          []string `json:"restore_layers,omitempty"`
	ProjectID              int      `json:"project_id,omitempty"`
	ProjectName            string   `json:"project_name,omitempty"`
	ProjectPath            string   `json:"project_path,omitempty"`
	Tailscale              bool     `json:"tailscale,omitempty"`
	MountHome              bool     `json:"mount_home,omitempty"`
	HomePath               string   `json:"home_path,omitempty"`
	DataPath               string   `json:"data_path,omitempty"`
	StorageMode            string   `json:"storage_mode,omitempty"`
	Temporary              bool     `json:"temporary,omitempty"`
	VNCEnabled             bool     `json:"vnc_enabled"`
	VNCGeometry            string   `json:"vnc_geometry,omitempty"`
	VNCDepth               int      `json:"vnc_depth,omitempty"`
	DockerEnabled          bool     `json:"docker_enabled"`
	SMBEnabled             bool     `json:"smb_enabled,omitempty"`
	OIDCEnabled            *bool    `json:"oidc_enabled,omitempty"`
	GCPOIDCEnabled         bool     `json:"gcp_oidc_enabled,omitempty"`
	GCPOIDCConfigID        int      `json:"gcp_oidc_config_id,omitempty"`
	GCPServiceAccountEmail string   `json:"gcp_service_account_email,omitempty"`
	GCPPrincipalScope      string   `json:"gcp_principal_scope,omitempty"`
	GCPRoles               []string `json:"gcp_roles,omitempty"`
}

type UpdateSandboxRequest struct {
	Temporary              *bool     `json:"temporary,omitempty"`
	Name                   *string   `json:"name,omitempty"`
	OIDCEnabled            *bool     `json:"oidc_enabled,omitempty"`
	GCPOIDCEnabled         *bool     `json:"gcp_oidc_enabled,omitempty"`
	GCPOIDCConfigID        *int      `json:"gcp_oidc_config_id,omitempty"`
	GCPServiceAccountEmail *string   `json:"gcp_service_account_email,omitempty"`
	GCPPrincipalScope      *string   `json:"gcp_principal_scope,omitempty"`
	GCPRoles               *[]string `json:"gcp_roles,omitempty"`
}

type GcpOidcConfig struct {
	ID                         int           `json:"id"`
	Name                       string        `json:"name"`
	ProjectID                  string        `json:"project_id,omitempty"`
	ProjectNumber              string        `json:"project_number,omitempty"`
	DefaultServiceAccountEmail string        `json:"default_service_account_email,omitempty"`
	DefaultReadOnlyRoles       []string      `json:"default_read_only_roles,omitempty"`
	WorkloadIdentityPoolID     string        `json:"workload_identity_pool_id,omitempty"`
	WorkloadIdentityProviderID string        `json:"workload_identity_provider_id,omitempty"`
	WorkloadIdentityLocation   string        `json:"workload_identity_location,omitempty"`
	SandboxCount               int           `json:"sandbox_count,omitempty"`
	Setup                      *GcpOidcSetup `json:"setup,omitempty"`
	CreatedAt                  time.Time     `json:"created_at"`
	UpdatedAt                  time.Time     `json:"updated_at"`
}

type GcpOidcConfigRequest struct {
	Name                       string `json:"name,omitempty"`
	ProjectID                  string `json:"project_id,omitempty"`
	ProjectNumber              string `json:"project_number,omitempty"`
	WorkloadIdentityPoolID     string `json:"workload_identity_pool_id,omitempty"`
	WorkloadIdentityProviderID string `json:"workload_identity_provider_id,omitempty"`
	WorkloadIdentityLocation   string `json:"workload_identity_location,omitempty"`
}

type GcpOidcSetup struct {
	Configured                 bool              `json:"configured"`
	SandboxConfigured          bool              `json:"sandbox_configured"`
	Missing                    []string          `json:"missing,omitempty"`
	Issuer                     string            `json:"issuer,omitempty"`
	ConfigID                   int               `json:"config_id,omitempty"`
	ConfigName                 string            `json:"config_name,omitempty"`
	ProjectID                  string            `json:"project_id,omitempty"`
	ProjectNumber              string            `json:"project_number,omitempty"`
	DefaultServiceAccountEmail string            `json:"default_service_account_email,omitempty"`
	DefaultReadOnlyRoles       []string          `json:"default_read_only_roles,omitempty"`
	Location                   string            `json:"location,omitempty"`
	PoolID                     string            `json:"pool_id,omitempty"`
	ProviderID                 string            `json:"provider_id,omitempty"`
	ProviderResource           string            `json:"provider_resource,omitempty"`
	Audience                   string            `json:"audience,omitempty"`
	AttributeMapping           map[string]string `json:"attribute_mapping,omitempty"`
	AttributeMappingArg        string            `json:"attribute_mapping_arg,omitempty"`
	PrincipalScope             string            `json:"principal_scope,omitempty"`
	Principal                  string            `json:"principal,omitempty"`
	ServiceAccountEmail        string            `json:"service_account_email,omitempty"`
	ServiceAccountSource       string            `json:"service_account_source,omitempty"`
	Roles                      []string          `json:"roles,omitempty"`
	Commands                   GcpOidcCommands   `json:"commands,omitempty"`
	Shell                      string            `json:"shell,omitempty"`
	CredentialConfig           map[string]any    `json:"credential_config,omitempty"`
	Environment                map[string]string `json:"environment,omitempty"`
}

type GcpOidcCommands struct {
	EnableAPIs                  string   `json:"enable_apis,omitempty"`
	CreateDefaultServiceAccount string   `json:"create_default_service_account,omitempty"`
	GrantDefaultRoles           []string `json:"grant_default_roles,omitempty"`
	CreatePool                  string   `json:"create_pool,omitempty"`
	CreateProvider              string   `json:"create_provider,omitempty"`
	BindServiceAccount          string   `json:"bind_service_account,omitempty"`
	GrantRoles                  []string `json:"grant_roles,omitempty"`
	CreateCredentialConfig      string   `json:"create_credential_config,omitempty"`
}

type UpdateGcpIdentityRequest struct {
	GCPOIDCEnabled         *bool     `json:"gcp_oidc_enabled,omitempty"`
	GCPOIDCConfigID        *int      `json:"gcp_oidc_config_id,omitempty"`
	GCPServiceAccountEmail *string   `json:"gcp_service_account_email,omitempty"`
	GCPPrincipalScope      *string   `json:"gcp_principal_scope,omitempty"`
	GCPRoles               *[]string `json:"gcp_roles,omitempty"`
}

type GcpIdentityResponse struct {
	Sandbox Sandbox      `json:"sandbox"`
	Setup   GcpOidcSetup `json:"setup"`
}

type Project struct {
	ID                     int            `json:"id"`
	Name                   string         `json:"name"`
	Path                   string         `json:"path"`
	Image                  string         `json:"image"`
	Tailscale              bool           `json:"tailscale"`
	VNCEnabled             bool           `json:"vnc_enabled"`
	VNCGeometry            string         `json:"vnc_geometry,omitempty"`
	VNCDepth               int            `json:"vnc_depth,omitempty"`
	DockerEnabled          bool           `json:"docker_enabled"`
	SMBEnabled             bool           `json:"smb_enabled"`
	SSHStartTmux           bool           `json:"ssh_start_tmux"`
	DefaultProject         bool           `json:"default_project"`
	MountHome              bool           `json:"mount_home"`
	HomePath               string         `json:"home_path,omitempty"`
	DataPath               string         `json:"data_path,omitempty"`
	OIDCEnabled            bool           `json:"oidc_enabled"`
	GCPOIDCEnabled         bool           `json:"gcp_oidc_enabled"`
	GCPOIDCConfigID        int            `json:"gcp_oidc_config_id,omitempty"`
	GCPOIDCConfig          *GcpOidcConfig `json:"gcp_oidc_config,omitempty"`
	GCPServiceAccountEmail string         `json:"gcp_service_account_email,omitempty"`
	GCPPrincipalScope      string         `json:"gcp_principal_scope,omitempty"`
	GCPRoles               []string       `json:"gcp_roles,omitempty"`
	CreatedAt              time.Time      `json:"created_at"`
}

type CreateProjectRequest struct {
	Name                   string   `json:"name"`
	Path                   string   `json:"path"`
	Image                  string   `json:"image,omitempty"`
	Tailscale              bool     `json:"tailscale,omitempty"`
	VNCEnabled             bool     `json:"vnc_enabled"`
	VNCGeometry            string   `json:"vnc_geometry,omitempty"`
	VNCDepth               int      `json:"vnc_depth,omitempty"`
	DockerEnabled          bool     `json:"docker_enabled"`
	SMBEnabled             bool     `json:"smb_enabled,omitempty"`
	SSHStartTmux           bool     `json:"ssh_start_tmux"`
	MountHome              bool     `json:"mount_home,omitempty"`
	HomePath               string   `json:"home_path,omitempty"`
	DataPath               string   `json:"data_path,omitempty"`
	OIDCEnabled            bool     `json:"oidc_enabled,omitempty"`
	GCPOIDCEnabled         bool     `json:"gcp_oidc_enabled,omitempty"`
	GCPOIDCConfigID        int      `json:"gcp_oidc_config_id,omitempty"`
	GCPServiceAccountEmail string   `json:"gcp_service_account_email,omitempty"`
	GCPPrincipalScope      string   `json:"gcp_principal_scope,omitempty"`
	GCPRoles               []string `json:"gcp_roles,omitempty"`
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
	Running            bool               `json:"running"`
	ContainerID        string             `json:"container_id"`
	Network            string             `json:"network"`
	ConnectedSandboxes int                `json:"connected_sandboxes"`
	TailscaleIP        string             `json:"tailscale_ip"`
	Hostname           string             `json:"hostname"`
	Tailnet            string             `json:"tailnet"`
	Online             bool               `json:"online"`
	Sandboxes          []TailscaleSandbox `json:"sandboxes"`
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
