package cmd

import (
	"fmt"

	"github.com/sandcastle/cli/internal/config"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(configCmd)
	configCmd.AddCommand(setTokenCmd)
	configCmd.AddCommand(showConfigCmd)
}

var configCmd = &cobra.Command{
	Use:   "config",
	Short: "Configure CLI settings",
}

var setTokenCmd = &cobra.Command{
	Use:   "set-token <token>",
	Short: "Set the API token for the current server",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load()
		if err != nil {
			return err
		}

		cur := cfg.Current()
		if cur == nil {
			return fmt.Errorf("no current server — run: sandcastle server add <url>")
		}

		cur.Token = args[0]
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

		cur := cfg.Current()
		if cur == nil {
			fmt.Println("No current server configured.")
			fmt.Println("Run: sandcastle server add <url>")
			return nil
		}

		if cur.Alias != "" {
			fmt.Printf("Alias:  %s\n", cur.Alias)
		}
		fmt.Printf("Server: %s\n", cur.Server)
		fmt.Printf("Token:  %s\n", config.MaskToken(cur.Token))
		fmt.Printf("Config: %s\n", config.Path())
		return nil
	},
}
