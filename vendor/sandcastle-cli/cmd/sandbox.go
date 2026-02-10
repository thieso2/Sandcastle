package cmd

import (
	"fmt"
	"os"
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
)

func init() {
	rootCmd.AddCommand(createCmd)
	rootCmd.AddCommand(listCmd)
	rootCmd.AddCommand(destroyCmd)
	rootCmd.AddCommand(startCmd)
	rootCmd.AddCommand(stopCmd)
	rootCmd.AddCommand(useCmd)

	createCmd.Flags().StringVar(&sandboxImage, "image", "sandcastle-sandbox", "Container image")
	createCmd.Flags().BoolVar(&sandboxPersistent, "persistent", false, "Enable persistent volume")
	createCmd.Flags().StringVar(&sandboxSnapshot, "snapshot", "", "Create from snapshot")
	createCmd.Flags().BoolVar(&sandboxTailscale, "tailscale", false, "Connect to Tailscale network")
}

var createCmd = &cobra.Command{
	Use:   "create <name>",
	Short: "Create a new sandbox",
	Args:  cobra.ExactArgs(1),
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
		})
		if err != nil {
			return err
		}

		fmt.Printf("Sandbox %q created (port %d)\n", sandbox.Name, sandbox.SSHPort)
		return nil
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
		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "NAME\tSTATUS\tPORT\tTAILSCALE IP\tIMAGE")
		for _, s := range sandboxes {
			marker := ""
			if s.Name == active {
				marker = " *"
			}
			tsIP := ""
			if s.TailscaleIP != "" {
				tsIP = s.TailscaleIP
			}
			fmt.Fprintf(w, "%s%s\t%s\t%d\t%s\t%s\n", s.Name, marker, s.Status, s.SSHPort, tsIP, s.Image)
		}
		w.Flush()
		return nil
	},
}

var destroyCmd = &cobra.Command{
	Use:   "destroy <name>",
	Short: "Destroy a sandbox",
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

		fmt.Printf("Sandbox %q destroyed.\n", args[0])
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
