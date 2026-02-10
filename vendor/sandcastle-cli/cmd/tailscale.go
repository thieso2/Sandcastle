package cmd

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"github.com/sandcastle/cli/api"
	"github.com/spf13/cobra"
)

var tsAuthKey string

func init() {
	rootCmd.AddCommand(tailscaleCmd)
	tailscaleCmd.AddCommand(tsEnableCmd)
	tailscaleCmd.AddCommand(tsDisableCmd)
	tailscaleCmd.AddCommand(tsStatusCmd)

	tsEnableCmd.Flags().StringVar(&tsAuthKey, "auth-key", "", "Tailscale auth key (tskey-auth-...)")
}

var tailscaleCmd = &cobra.Command{
	Use:     "tailscale",
	Aliases: []string{"ts"},
	Short:   "Manage Tailscale auth key",
}

var tsEnableCmd = &cobra.Command{
	Use:   "enable",
	Short: "Store a Tailscale auth key for sandbox connectivity",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		authKey := tsAuthKey
		if authKey == "" {
			fmt.Println("Paste a reusable Tailscale auth key.")
			fmt.Println("Generate one at: Tailscale Admin > Settings > Keys")
			fmt.Println()
			fmt.Print("Auth key: ")
			scanner := bufio.NewScanner(os.Stdin)
			if scanner.Scan() {
				authKey = strings.TrimSpace(scanner.Text())
			}
			if authKey == "" {
				return fmt.Errorf("no auth key provided")
			}
		}

		if err := client.TailscaleUpdate(authKey); err != nil {
			return err
		}

		fmt.Println("Tailscale auth key saved.")
		fmt.Println("Create sandboxes with --tailscale to connect them to your tailnet.")
		return nil
	},
}

var tsDisableCmd = &cobra.Command{
	Use:   "disable",
	Short: "Remove stored Tailscale auth key",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		if err := client.TailscaleRemoveKey(); err != nil {
			return err
		}

		fmt.Println("Tailscale auth key removed.")
		return nil
	},
}

var tsStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show Tailscale configuration",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		cfg, err := client.TailscaleConfig()
		if err != nil {
			return err
		}

		if cfg.Configured {
			fmt.Println("Tailscale:      configured")
			fmt.Printf("Auth key set:   %v\n", cfg.AuthKeySet)
			fmt.Printf("Auto-connect:   %v\n", cfg.AutoConnect)
		} else {
			fmt.Println("Tailscale:      not configured")
			fmt.Println()
			fmt.Println("Run `sandcastle tailscale enable` to store an auth key.")
		}

		return nil
	},
}
