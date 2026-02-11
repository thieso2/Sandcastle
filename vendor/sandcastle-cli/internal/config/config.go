package config

import (
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

type ServerConfig struct {
	URL      string `yaml:"url"`
	Token    string `yaml:"token"`
	Insecure bool   `yaml:"insecure,omitempty"`
}

type Config struct {
	CurrentServer string                  `yaml:"current_server"`
	Servers       map[string]ServerConfig `yaml:"servers"`
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
