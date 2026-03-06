package cmd

import (
	"fmt"
	"os"
	"strings"

	"github.com/sandcastle/cli/internal/config"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(configCmd)
	configCmd.AddCommand(showConfigCmd)
	configCmd.AddCommand(configSetCmd)

	rootCmd.AddCommand(serverCmd)
	serverCmd.AddCommand(serverListCmd)
	serverCmd.AddCommand(serverUseCmd)
	serverCmd.AddCommand(serverRemoveCmd)

}

var configCmd = &cobra.Command{
	Use:   "config",
	Short: "Configure CLI settings",
}

var showConfigCmd = &cobra.Command{
	Use:   "show",
	Short: "Show current configuration",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load()
		if err != nil {
			return err
		}

		if cfg.CurrentServer == "" {
			fmt.Println("No server configured. Run: sandcastle login <url>")
			return nil
		}

		srv, ok := cfg.Servers[cfg.CurrentServer]
		if !ok {
			fmt.Printf("Current: %s (not found in servers)\n", cfg.CurrentServer)
			return nil
		}

		fmt.Printf("Server: %s (%s)\n", cfg.CurrentServer, srv.URL)
		if srv.Token != "" {
			if len(srv.Token) > 12 {
				fmt.Printf("Token:  %s...\n", srv.Token[:12])
			} else {
				fmt.Println("Token:  (set)")
			}
		} else {
			fmt.Println("Token:  (not set)")
		}
		fmt.Printf("Config: %s\n", config.Path())

		// Show effective preferences with source annotation
		prefs := cfg.LoadPreferences()
		fmt.Println()
		fmt.Println("Preferences (effective):")

		protocolSrc := sourceLabel(
			os.Getenv("SANDCASTLE_CONNECT_PROTOCOL") != "",
			cfg.Preferences.ConnectProtocol != "",
		)
		fmt.Printf("  connect_protocol: %-6s  [%s]\n", prefs.ConnectProtocol, protocolSrc)

		useTmuxVal := "true"
		if prefs.UseTmux != nil && !*prefs.UseTmux {
			useTmuxVal = "false"
		}
		tmuxSrc := sourceLabel(
			os.Getenv("SANDCASTLE_USE_TMUX") != "",
			cfg.Preferences.UseTmux != nil,
		)
		fmt.Printf("  use_tmux:         %-6s  [%s]\n", useTmuxVal, tmuxSrc)

		extraArgs := prefs.SSHExtraArgs
		if extraArgs == "" {
			extraArgs = "(not set)"
		}
		extraArgsSrc := sourceLabel(
			os.Getenv("SANDCASTLE_SSH_EXTRA_ARGS") != "",
			cfg.Preferences.SSHExtraArgs != "",
		)
		fmt.Printf("  ssh_extra_args:   %s  [%s]\n", extraArgs, extraArgsSrc)

		mountHomeVal := "false"
		if prefs.MountHome != nil && *prefs.MountHome {
			mountHomeVal = "true"
		}
		mountHomeSrc := sourceLabel(
			os.Getenv("SANDCASTLE_HOME") != "",
			cfg.Preferences.MountHome != nil,
		)
		fmt.Printf("  mount_home:       %-6s  [%s]\n", mountHomeVal, mountHomeSrc)

		dataPathVal := prefs.DataPath
		if dataPathVal == "" {
			dataPathVal = "(not set)"
		}
		dataPathSrc := sourceLabel(
			os.Getenv("SANDCASTLE_DATA") != "",
			cfg.Preferences.DataPath != "",
		)
		fmt.Printf("  data_path:        %s  [%s]\n", dataPathVal, dataPathSrc)

		return nil
	},
}

// sourceLabel returns "env", "config", or "default" to annotate where a value comes from.
func sourceLabel(fromEnv, fromConfig bool) string {
	if fromEnv {
		return "env"
	}
	if fromConfig {
		return "config"
	}
	return "default"
}

var configSetCmd = &cobra.Command{
	Use:   "set <key> <value>",
	Short: "Set a CLI preference",
	Long: `Set a CLI preference and save it to ~/.sandcastle/config.yaml.

Valid keys:
  connect_protocol   Connection protocol: "ssh" (default) or "mosh"
  use_tmux           Wrap connection in tmux: "true" (default) or "false"
  ssh_extra_args     Extra flags appended to the ssh/mosh invocation
  mount_home         Mount persistent home on create: "true" or "false" (default)
  data_path          Mount user data dir on create: "." (root), subpath, or "off"

ENV vars override config file values at runtime:
  SANDCASTLE_CONNECT_PROTOCOL, SANDCASTLE_USE_TMUX, SANDCASTLE_SSH_EXTRA_ARGS,
  SANDCASTLE_HOME, SANDCASTLE_DATA`,
	Args: cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		key, value := args[0], args[1]

		cfg, err := config.Load()
		if err != nil {
			return err
		}

		if err := cfg.SetPreference(key, value); err != nil {
			return err
		}

		if err := config.Save(cfg); err != nil {
			return err
		}

		fmt.Printf("Set %s = %s\n", key, value)
		return nil
	},
}

// Server management commands

var serverCmd = &cobra.Command{
	Use:   "server",
	Short: "Manage configured servers",
}

var serverListCmd = &cobra.Command{
	Use:     "list",
	Short:   "List configured servers",
	Aliases: []string{"ls"},
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load()
		if err != nil {
			return err
		}

		if len(cfg.Servers) == 0 {
			fmt.Println("No servers configured. Run: sandcastle login <url>")
			return nil
		}

		for alias, srv := range cfg.Servers {
			marker := "  "
			if alias == cfg.CurrentServer {
				marker = "* "
			}
			tokenStatus := "no token"
			if srv.Token != "" {
				tokenStatus = "authenticated"
			}
			fmt.Printf("%s%-12s %s (%s)\n", marker, alias, srv.URL, tokenStatus)
		}
		return nil
	},
}

var serverUseCmd = &cobra.Command{
	Use:   "use <alias>",
	Short: "Set the active server",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		alias := args[0]
		cfg, err := config.Load()
		if err != nil {
			return err
		}

		// Allow using URL as alias — find matching server
		if _, ok := cfg.Servers[alias]; !ok {
			for a, srv := range cfg.Servers {
				if srv.URL == strings.TrimRight(alias, "/") {
					alias = a
					break
				}
			}
		}

		if _, ok := cfg.Servers[alias]; !ok {
			return fmt.Errorf("server %q not found — run: sandcastle server list", alias)
		}

		cfg.CurrentServer = alias
		if err := config.Save(cfg); err != nil {
			return err
		}

		fmt.Printf("Switched to %s (%s)\n", alias, cfg.Servers[alias].URL)
		return nil
	},
}

var serverRemoveCmd = &cobra.Command{
	Use:     "remove <alias>",
	Short:   "Remove a configured server",
	Aliases: []string{"rm"},
	Args:    cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		alias := args[0]
		cfg, err := config.Load()
		if err != nil {
			return err
		}

		if _, ok := cfg.Servers[alias]; !ok {
			return fmt.Errorf("server %q not found", alias)
		}

		delete(cfg.Servers, alias)
		if cfg.CurrentServer == alias {
			cfg.CurrentServer = ""
			// Set first remaining server as current
			for a := range cfg.Servers {
				cfg.CurrentServer = a
				break
			}
		}

		if err := config.Save(cfg); err != nil {
			return err
		}

		fmt.Printf("Removed server %s\n", alias)
		return nil
	},
}
