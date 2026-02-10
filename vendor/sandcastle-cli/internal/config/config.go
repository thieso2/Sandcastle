package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

type ServerEntry struct {
	Alias  string `yaml:"alias,omitempty"`
	Server string `yaml:"server"`
	Token  string `yaml:"token,omitempty"`
}

type Config struct {
	CurrentServer string        `yaml:"current_server,omitempty"`
	Servers       []ServerEntry `yaml:"servers,omitempty"`

	// Unexported fields for detecting old-format config during migration.
	legacyServer string
	legacyToken  string
}

// legacyConfig is used only for unmarshaling old-format config files.
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
	cfg := &Config{}
	data, err := os.ReadFile(Path())
	if err != nil {
		if os.IsNotExist(err) {
			return cfg, nil
		}
		return nil, fmt.Errorf("reading config: %w", err)
	}

	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parsing config: %w", err)
	}

	// Auto-migrate old flat server/token format.
	if len(cfg.Servers) == 0 {
		var legacy legacyConfig
		if err := yaml.Unmarshal(data, &legacy); err == nil && legacy.Server != "" {
			cfg.legacyServer = legacy.Server
			cfg.legacyToken = legacy.Token
			entry := ServerEntry{
				Server: legacy.Server,
				Token:  legacy.Token,
			}
			cfg.Servers = []ServerEntry{entry}
			cfg.CurrentServer = legacy.Server
		}
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

// Current returns the active server entry, or nil if none is set.
func (c *Config) Current() *ServerEntry {
	if c.CurrentServer == "" {
		return nil
	}
	for i := range c.Servers {
		if c.Servers[i].Alias == c.CurrentServer || c.Servers[i].Server == c.CurrentServer {
			return &c.Servers[i]
		}
	}
	return nil
}

// FindServer looks up a server by alias first, then by URL.
func (c *Config) FindServer(aliasOrURL string) *ServerEntry {
	// Check alias first.
	for i := range c.Servers {
		if c.Servers[i].Alias != "" && c.Servers[i].Alias == aliasOrURL {
			return &c.Servers[i]
		}
	}
	// Then check URL.
	for i := range c.Servers {
		if c.Servers[i].Server == aliasOrURL {
			return &c.Servers[i]
		}
	}
	return nil
}

// AddServer appends a server entry. Sets it as current if it's the first one.
func (c *Config) AddServer(entry ServerEntry) {
	c.Servers = append(c.Servers, entry)
	if len(c.Servers) == 1 {
		if entry.Alias != "" {
			c.CurrentServer = entry.Alias
		} else {
			c.CurrentServer = entry.Server
		}
	}
}

// RemoveServer removes a server by alias or URL. Clears current if it matched.
func (c *Config) RemoveServer(aliasOrURL string) error {
	idx := -1
	for i := range c.Servers {
		if c.Servers[i].Alias == aliasOrURL || c.Servers[i].Server == aliasOrURL {
			idx = i
			break
		}
	}
	if idx == -1 {
		return fmt.Errorf("server not found: %s", aliasOrURL)
	}

	removed := c.Servers[idx]
	c.Servers = append(c.Servers[:idx], c.Servers[idx+1:]...)

	// Clear current if it pointed to the removed entry.
	if c.CurrentServer == removed.Alias || c.CurrentServer == removed.Server {
		c.CurrentServer = ""
	}

	return nil
}

// MaskToken returns a masked version of a token for display.
func MaskToken(token string) string {
	if token == "" {
		return "(not set)"
	}
	if len(token) > 12 {
		return token[:12] + "..."
	}
	return "(set)"
}

// NormalizeURL trims trailing slashes from a server URL.
func NormalizeURL(url string) string {
	return strings.TrimRight(url, "/")
}

// ActiveSandbox reads .sandcastle file in current directory for the active sandbox name.
func ActiveSandbox() string {
	data, err := os.ReadFile(".sandcastle")
	if err != nil {
		return ""
	}
	return string(data)
}

// SetActiveSandbox writes .sandcastle file in current directory.
func SetActiveSandbox(name string) error {
	return os.WriteFile(".sandcastle", []byte(name), 0o644)
}
