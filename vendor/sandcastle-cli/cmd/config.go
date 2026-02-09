package cmd

import (
	"fmt"
	"strings"

	"github.com/sandcastle/cli/internal/config"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(configCmd)
	configCmd.AddCommand(setServerCmd)
	configCmd.AddCommand(setTokenCmd)
	configCmd.AddCommand(showConfigCmd)
}

var configCmd = &cobra.Command{
	Use:   "config",
	Short: "Configure CLI settings",
}

var setServerCmd = &cobra.Command{
	Use:   "set-server <url>",
	Short: "Set the Sandcastle server URL",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load()
		if err != nil {
			return err
		}

		server := strings.TrimRight(args[0], "/")
		cfg.Server = server
		if err := config.Save(cfg); err != nil {
			return err
		}

		fmt.Printf("Server set to %s\n", server)
		return nil
	},
}

var setTokenCmd = &cobra.Command{
	Use:   "set-token <token>",
	Short: "Set the API token manually",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load()
		if err != nil {
			return err
		}

		cfg.Token = args[0]
		if err := config.Save(cfg); err != nil {
			return err
		}

		fmt.Println("Token saved.")
		return nil
	},
}

var showConfigCmd = &cobra.Command{
	Use:   "show",
	Short: "Show current configuration",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load()
		if err != nil {
			return err
		}

		fmt.Printf("Server: %s\n", cfg.Server)
		if cfg.Token != "" {
			// Show only prefix for security
			if len(cfg.Token) > 12 {
				fmt.Printf("Token:  %s...\n", cfg.Token[:12])
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
