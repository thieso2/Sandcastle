package cmd

import (
	"fmt"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/sandcastle/cli/api"
	"github.com/sandcastle/cli/internal/config"
	"github.com/spf13/cobra"
)

var (
	sandboxImage      string
	sandboxPersistent bool
	sandboxSnapshot   string
	sandboxTailscale  bool
	sandboxNoConnect  bool
	sandboxRemove     bool
	sandboxHome       bool
	sandboxData       string
)

func init() {
	rootCmd.AddCommand(createCmd)
	rootCmd.AddCommand(listCmd)
	rootCmd.AddCommand(deleteCmd)
	rootCmd.AddCommand(startCmd)
	rootCmd.AddCommand(stopCmd)
	rootCmd.AddCommand(useCmd)
	rootCmd.AddCommand(setCmd)

	createCmd.Flags().StringVar(&sandboxImage, "image", "sandcastle-sandbox:latest", "Container image")
	createCmd.Flags().BoolVar(&sandboxPersistent, "persistent", false, "Enable persistent volume")
	createCmd.Flags().StringVar(&sandboxSnapshot, "snapshot", "", "Create from snapshot")
	createCmd.Flags().BoolVar(&sandboxTailscale, "tailscale", false, "Connect to Tailscale network")
	createCmd.Flags().BoolVarP(&sandboxNoConnect, "no-connect", "n", false, "Don't connect after creation")
	createCmd.Flags().BoolVar(&sandboxRemove, "rm", false, "Delete sandbox on exit (env: SANDCASTLE_RM)")
	createCmd.Flags().BoolVar(&sandboxHome, "home", false, "Mount persistent home directory (env: SANDCASTLE_HOME)")
	createCmd.Flags().StringVar(&sandboxData, "data", "", "Mount user data directory (or subpath) to /data (env: SANDCASTLE_DATA)")
	createCmd.Flags().Lookup("data").NoOptDefVal = "."
}

var createCmd = &cobra.Command{
	Use:   "create <name>",
	Short: "Create a new sandbox",
	Long: `Create a new sandbox.

Environment variables can set defaults for commonly used flags:
  SANDCASTLE_HOME=1    equivalent to --home
  SANDCASTLE_DATA=.    equivalent to --data (value is the subpath, "." or "1" for root)
  SANDCASTLE_RM=1      equivalent to --rm

Flags explicitly passed on the command line take precedence over environment variables.`,
	Args: cobra.ExactArgs(1),
	PreRun: func(cmd *cobra.Command, args []string) {
		if !cmd.Flags().Changed("home") && envTruthy("SANDCASTLE_HOME") {
			sandboxHome = true
		}
		if !cmd.Flags().Changed("rm") && envTruthy("SANDCASTLE_RM") {
			sandboxRemove = true
		}
		if !cmd.Flags().Changed("data") {
			if v := os.Getenv("SANDCASTLE_DATA"); v != "" {
				if v == "1" || v == "true" {
					v = "."
				}
				sandboxData = v
			}
		}
	},
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		sandbox, err := client.CreateSandbox(api.CreateSandboxRequest{
			Name:       args[0],
			Image:      sandboxImage,
			Persistent: sandboxPersistent,
			Snapshot:   sandboxSnapshot,
			Tailscale:  sandboxTailscale,
			MountHome:  sandboxHome,
			DataPath:   sandboxData,
			Temporary:  sandboxRemove,
		})
		if err != nil {
			return err
		}

		fmt.Printf("Sandbox %q created.\n", sandbox.Name)

		// Print active options (use local flags — they reflect what was actually requested)
		if sandboxHome || sandboxData != "" || sandboxPersistent || sandbox.Tailscale || sandboxRemove {
			if sandboxHome {
				fmt.Println("  Home:      mounted (~/ persisted)")
			}
			if sandboxData != "" {
				label := sandboxData
				if label == "." {
					label = "user data root"
				}
				fmt.Printf("  Data:      mounted (%s → /data)\n", label)
			}
			if sandboxPersistent {
				fmt.Println("  Volume:    persistent (/workspace)")
			}
			if sandbox.Tailscale {
				fmt.Println("  Tailscale: enabled")
			}
			if sandboxRemove {
				fmt.Println("  Cleanup:   auto-remove on exit")
			}
		}

		if sandboxNoConnect {
			return nil
		}

		// Auto-connect: set as active, wait for SSH, attach tmux
		_ = config.SetActiveSandbox(sandbox.Name)

		info, err := client.ConnectInfo(sandbox.ID)
		if err != nil {
			return err
		}

		if err := waitForSSH(info.Host, info.Port); err != nil {
			return err
		}

		sshErr := sshExec(info.Host, info.Port, info.User, "tmux new-session -A -s main")

		if sandboxRemove {
			// Re-fetch to check if user toggled to "keep" during the session
			current, fetchErr := client.GetSandbox(sandbox.ID)
			if fetchErr == nil && !current.Temporary {
				fmt.Printf("Sandbox %q was set to keep — skipping removal.\n", sandbox.Name)
			} else {
				fmt.Printf("Removing sandbox %q...\n", sandbox.Name)
				if err := client.DestroySandbox(sandbox.ID); err != nil {
					fmt.Fprintf(os.Stderr, "Warning: failed to delete sandbox: %v\n", err)
				} else {
					fmt.Printf("Sandbox %q deleted.\n", sandbox.Name)
				}
			}
		}

		return sshErr
	},
}

var listCmd = &cobra.Command{
	Use:     "list",
	Aliases: []string{"ls"},
	Short:   "List all sandboxes",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		sandboxes, err := client.ListSandboxes()
		if err != nil {
			return err
		}

		if len(sandboxes) == 0 {
			fmt.Println("No sandboxes.")
			return nil
		}

		active := config.ActiveSandbox()

		hasRoute := false
		for _, s := range sandboxes {
			if s.RouteURL != "" {
				hasRoute = true
				break
			}
		}

		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		if hasRoute {
			fmt.Fprintln(w, "NAME\tSTATUS\tPORT\tROUTE\tTAILSCALE IP\tIMAGE")
		} else {
			fmt.Fprintln(w, "NAME\tSTATUS\tPORT\tTAILSCALE IP\tIMAGE")
		}
		for _, s := range sandboxes {
			name := s.Name
			if s.Name == active {
				name += " *"
			}
			if s.Temporary {
				name += " (temp)"
			}
			tsIP := ""
			if s.TailscaleIP != "" {
				tsIP = s.TailscaleIP
			}
			if hasRoute {
				route := ""
				if s.RouteURL != "" {
					route = fmt.Sprintf("%s (:%d)", s.RouteURL, s.RoutePort)
				}
				fmt.Fprintf(w, "%s\t%s\t%d\t%s\t%s\t%s\n", name, s.Status, s.SSHPort, route, tsIP, s.Image)
			} else {
				fmt.Fprintf(w, "%s\t%s\t%d\t%s\t%s\n", name, s.Status, s.SSHPort, tsIP, s.Image)
			}
		}
		w.Flush()
		return nil
	},
}

var deleteCmd = &cobra.Command{
	Use:   "delete <name>",
	Short: "Delete a sandbox",
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

		if err := client.DestroySandbox(sandbox.ID); err != nil {
			return err
		}

		fmt.Printf("Sandbox %q deleted.\n", args[0])
		return nil
	},
}

var startCmd = &cobra.Command{
	Use:   "start <name>",
	Short: "Start a stopped sandbox",
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

		sandbox, err = client.StartSandbox(sandbox.ID)
		if err != nil {
			return err
		}

		fmt.Printf("Sandbox %q started.\n", sandbox.Name)
		return nil
	},
}

var stopCmd = &cobra.Command{
	Use:   "stop <name>",
	Short: "Stop a running sandbox",
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

		sandbox, err = client.StopSandbox(sandbox.ID)
		if err != nil {
			return err
		}

		fmt.Printf("Sandbox %q stopped.\n", sandbox.Name)
		return nil
	},
}

var useCmd = &cobra.Command{
	Use:   "use <name>",
	Short: "Set active sandbox for current directory",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		if err := config.SetActiveSandbox(args[0]); err != nil {
			return err
		}
		fmt.Printf("Active sandbox set to %q\n", args[0])
		return nil
	},
}

var setCmd = &cobra.Command{
	Use:   "set <name> <temp|keep>",
	Short: "Toggle sandbox between temporary and kept",
	Long: `Toggle a sandbox between temporary (auto-remove on exit) and kept.

  temp   Mark as temporary — will be removed when the CLI session exits
  keep   Mark as kept — will not be auto-removed`,
	Args: cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		sandbox, err := findSandboxByName(client, args[0])
		if err != nil {
			return err
		}

		mode := strings.ToLower(args[1])
		var temp bool
		switch mode {
		case "temp":
			temp = true
		case "keep":
			temp = false
		default:
			return fmt.Errorf("unknown mode %q: use \"temp\" or \"keep\"", args[1])
		}

		sandbox, err = client.UpdateSandbox(sandbox.ID, api.UpdateSandboxRequest{Temporary: &temp})
		if err != nil {
			return err
		}

		if temp {
			fmt.Printf("Sandbox %q set to temporary (will be removed on exit).\n", sandbox.Name)
		} else {
			fmt.Printf("Sandbox %q set to keep (will not be removed on exit).\n", sandbox.Name)
		}
		return nil
	},
}

func envTruthy(key string) bool {
	v := strings.ToLower(os.Getenv(key))
	return v == "1" || v == "true" || v == "yes"
}

func findSandboxByName(client *api.Client, name string) (*api.Sandbox, error) {
	sandboxes, err := client.ListSandboxes()
	if err != nil {
		return nil, err
	}
	for _, s := range sandboxes {
		if s.Name == name {
			return &s, nil
		}
	}
	return nil, fmt.Errorf("sandbox %q not found", name)
}
