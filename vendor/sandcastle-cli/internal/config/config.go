package config

import (
	"fmt"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

type Config struct {
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
