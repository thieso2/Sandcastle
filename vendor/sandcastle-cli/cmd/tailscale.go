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
	tailscaleCmd.AddCommand(tsConnectCmd)
	tailscaleCmd.AddCommand(tsDisconnectCmd)

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

		if len(status.Sandboxes) > 0 {
			fmt.Println()
			w = tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
			fmt.Fprintln(w, "SANDBOX\tBRIDGE IP\tSSH COMMAND")
			for _, sb := range status.Sandboxes {
				sshCmd := "—"
				if sb.IP != "" {
					sshCmd = fmt.Sprintf("ssh %s", sb.IP)
				}
				fmt.Fprintf(w, "%s\t%s\t%s\n", sb.Name, valueOrDash(sb.IP), sshCmd)
			}
			w.Flush()
		}

		return nil
	},
}

var tsConnectCmd = &cobra.Command{
	Use:   "connect <sandbox>",
	Short: "Connect a sandbox to Tailscale network",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		sandbox, err := findSandboxByName(client, args[0])
		if err != nil {
			return err
		}

		sandbox, err = client.TailscaleConnect(sandbox.ID)
		if err != nil {
			return err
		}

		fmt.Printf("Sandbox %q connected to Tailscale.\n", sandbox.Name)
		fmt.Println("Run `sandcastle ts status` to see the bridge IP.")
		return nil
	},
}

var tsDisconnectCmd = &cobra.Command{
	Use:   "disconnect <sandbox>",
	Short: "Disconnect a sandbox from Tailscale network",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		sandbox, err := findSandboxByName(client, args[0])
		if err != nil {
			return err
		}

		sandbox, err = client.TailscaleDisconnect(sandbox.ID)
		if err != nil {
			return err
		}

		fmt.Printf("Sandbox %q disconnected from Tailscale.\n", sandbox.Name)
		return nil
	},
}

func valueOrDash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}
