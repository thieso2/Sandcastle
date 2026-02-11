package cmd

import (
	"fmt"
	"strings"

	"github.com/sandcastle/cli/internal/config"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(configCmd)
	configCmd.AddCommand(showConfigCmd)

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
		return nil
	},
}

// Server management commands

var serverCmd = &cobra.Command{
	Use:   "server",
	Short: "Manage configured servers",
}

var serverListCmd = &cobra.Command{
	Use:   "list",
	Short: "List configured servers",
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
	Use:   "remove <alias>",
	Short: "Remove a configured server",
	Aliases: []string{"rm"},
	Args:  cobra.ExactArgs(1),
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
