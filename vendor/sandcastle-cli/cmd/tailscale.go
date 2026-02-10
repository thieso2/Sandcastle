package cmd

import (
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/sandcastle/cli/api"
	"github.com/spf13/cobra"
	"golang.org/x/term"
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
	Short:   "Manage Tailscale connectivity",
}

var tsEnableCmd = &cobra.Command{
	Use:   "enable",
	Short: "Enable Tailscale sidecar",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		authKey := tsAuthKey
		if authKey == "" {
			fmt.Print("Tailscale auth key: ")
			key, err := term.ReadPassword(int(os.Stdin.Fd()))
			fmt.Println()
			if err != nil {
				return fmt.Errorf("reading auth key: %w", err)
			}
			authKey = string(key)
		}

		if err := client.TailscaleEnable(authKey); err != nil {
			return err
		}

		fmt.Println("Tailscale enabled. Approve subnet routes in the Tailscale admin console.")
		return nil
	},
}

var tsDisableCmd = &cobra.Command{
	Use:   "disable",
	Short: "Disable Tailscale sidecar",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		if err := client.TailscaleDisable(); err != nil {
			return err
		}

		fmt.Println("Tailscale disabled.")
		return nil
	},
}

var tsStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show Tailscale status",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		status, err := client.TailscaleStatus()
		if err != nil {
			return err
		}

		state := "offline"
		if status.Running && status.Online {
			state = "online"
		} else if status.Running {
			state = "running"
		}

		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintf(w, "State:\t%s\n", state)
		fmt.Fprintf(w, "Tailscale IP:\t%s\n", valueOrDash(status.TailscaleIP))
		fmt.Fprintf(w, "Hostname:\t%s\n", valueOrDash(status.Hostname))
		fmt.Fprintf(w, "Tailnet:\t%s\n", valueOrDash(status.Tailnet))
		fmt.Fprintf(w, "Network:\t%s\n", valueOrDash(status.Network))
		fmt.Fprintf(w, "Container:\t%s\n", valueOrDash(status.ContainerID))
		fmt.Fprintf(w, "Connected sandboxes:\t%d\n", status.ConnectedSandboxes)
		w.Flush()
		return nil
	},
}

func valueOrDash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}
