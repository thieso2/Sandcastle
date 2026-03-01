package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

type ServerConfig struct {
	URL      string `yaml:"url"`
	Token    string `yaml:"token"`
	Insecure bool   `yaml:"insecure,omitempty"`
}

// Preferences holds user-configurable CLI behaviour. Each field can be
// overridden by a SANDCASTLE_<KEY> environment variable at runtime.
type Preferences struct {
	ConnectProtocol string `yaml:"connect_protocol,omitempty"` // "ssh" (default) | "mosh"
	UseTmux         *bool  `yaml:"use_tmux,omitempty"`         // default true
	SSHExtraArgs    string `yaml:"ssh_extra_args,omitempty"`   // extra flags for ssh/mosh
}

type Config struct {
	CurrentServer string                  `yaml:"current_server"`
	Servers       map[string]ServerConfig `yaml:"servers"`
	Preferences   Preferences             `yaml:"preferences,omitempty"`
}

// legacyConfig is the old flat format for migration.
type legacyConfig struct {
	Server string `yaml:"server"`
	Token  string `yaml:"token"`
}

func Dir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".sandcastle")
}

func Path() string {
	return filepath.Join(Dir(), "config.yaml")
}

func Load() (*Config, error) {
	cfg := &Config{Servers: make(map[string]ServerConfig)}
	data, err := os.ReadFile(Path())
	if err != nil {
		if os.IsNotExist(err) {
			return cfg, nil
		}
		return nil, fmt.Errorf("reading config: %w", err)
	}

	// Try new format first
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parsing config: %w", err)
	}

	// Migrate legacy flat format
	if cfg.Servers == nil || len(cfg.Servers) == 0 {
		var legacy legacyConfig
		if err := yaml.Unmarshal(data, &legacy); err == nil && legacy.Server != "" {
			cfg.Servers = map[string]ServerConfig{
				"default": {URL: legacy.Server, Token: legacy.Token},
			}
			cfg.CurrentServer = "default"
			// Save migrated config
			_ = Save(cfg)
		}
	}

	if cfg.Servers == nil {
		cfg.Servers = make(map[string]ServerConfig)
	}

	return cfg, nil
}

func Save(cfg *Config) error {
	if err := os.MkdirAll(Dir(), 0o700); err != nil {
		return fmt.Errorf("creating config dir: %w", err)
	}
	data, err := yaml.Marshal(cfg)
	if err != nil {
		return fmt.Errorf("marshaling config: %w", err)
	}
	if err := os.WriteFile(Path(), data, 0o600); err != nil {
		return fmt.Errorf("writing config: %w", err)
	}
	return nil
}

// CurrentServerConfig returns the active server's URL and token.
func (c *Config) CurrentServerConfig() (ServerConfig, error) {
	if c.CurrentServer == "" {
		return ServerConfig{}, fmt.Errorf("no server configured — run: sandcastle login <url>")
	}
	srv, ok := c.Servers[c.CurrentServer]
	if !ok {
		return ServerConfig{}, fmt.Errorf("server %q not found in config — run: sandcastle login <url>", c.CurrentServer)
	}
	return srv, nil
}

// SetServer adds or updates a server and sets it as current.
func (c *Config) SetServer(alias, url, token string, insecure bool) {
	if c.Servers == nil {
		c.Servers = make(map[string]ServerConfig)
	}
	c.Servers[alias] = ServerConfig{URL: url, Token: token, Insecure: insecure}
	c.CurrentServer = alias
}

// LoadPreferences returns effective preferences with env vars overlaid.
// Priority: ENV var > config file preference > built-in default.
func (c *Config) LoadPreferences() Preferences {
	p := c.Preferences

	if v := os.Getenv("SANDCASTLE_CONNECT_PROTOCOL"); v != "" {
		p.ConnectProtocol = v
	}
	if v := os.Getenv("SANDCASTLE_USE_TMUX"); v != "" {
		b := strings.ToLower(v) == "true" || v == "1"
		p.UseTmux = &b
	}
	if v := os.Getenv("SANDCASTLE_SSH_EXTRA_ARGS"); v != "" {
		p.SSHExtraArgs = v
	}

	// Apply built-in defaults
	if p.ConnectProtocol == "" {
		p.ConnectProtocol = "ssh"
	}
	if p.UseTmux == nil {
		t := true
		p.UseTmux = &t
	}

	return p
}

// SetPreference sets a named preference by string value and validates it.
func (c *Config) SetPreference(key, value string) error {
	switch key {
	case "connect_protocol":
		if value != "ssh" && value != "mosh" {
			return fmt.Errorf("connect_protocol must be 'ssh' or 'mosh', got %q", value)
		}
		c.Preferences.ConnectProtocol = value
	case "use_tmux":
		switch strings.ToLower(value) {
		case "true", "1", "yes":
			t := true
			c.Preferences.UseTmux = &t
		case "false", "0", "no":
			f := false
			c.Preferences.UseTmux = &f
		default:
			return fmt.Errorf("use_tmux must be 'true' or 'false', got %q", value)
		}
	case "ssh_extra_args":
		c.Preferences.SSHExtraArgs = value
	default:
		return fmt.Errorf("unknown preference %q; valid keys: connect_protocol, use_tmux, ssh_extra_args", key)
	}
	return nil
}

