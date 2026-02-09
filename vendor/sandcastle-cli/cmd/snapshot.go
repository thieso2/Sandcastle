package cmd

import (
	"fmt"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/sandcastle/cli/api"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(snapshotCmd)
	snapshotCmd.AddCommand(snapshotCreateCmd)
	snapshotCmd.AddCommand(snapshotListCmd)
	snapshotCmd.AddCommand(snapshotDestroyCmd)
	snapshotCmd.AddCommand(snapshotRestoreCmd)
}

var snapshotCmd = &cobra.Command{
	Use:     "snapshot",
	Aliases: []string{"snap"},
	Short:   "Manage sandbox snapshots",
}

var snapshotCreateCmd = &cobra.Command{
	Use:   "create <sandbox> [name]",
	Short: "Create a snapshot of a sandbox",
	Args:  cobra.RangeArgs(1, 2),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		sandbox, err := findSandboxByName(client, args[0])
		if err != nil {
			return err
		}

		var name string
		if len(args) > 1 {
			name = args[1]
		}

		snap, err := client.SnapshotSandbox(sandbox.ID, name)
		if err != nil {
			return err
		}

		fmt.Printf("Snapshot %q created from sandbox %q\n", snap.Name, args[0])
		fmt.Printf("Image: %s\n", snap.Image)
		return nil
	},
}

var snapshotListCmd = &cobra.Command{
	Use:     "list",
	Aliases: []string{"ls"},
	Short:   "List all snapshots",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		snapshots, err := client.ListSnapshots()
		if err != nil {
			return err
		}

		if len(snapshots) == 0 {
			fmt.Println("No snapshots.")
			return nil
		}

		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "NAME\tIMAGE\tSIZE\tCREATED")
		for _, s := range snapshots {
			fmt.Fprintf(w, "%s\t%s\t%d MB\t%s\n",
				s.Name,
				s.Image,
				s.Size/1024/1024,
				s.CreatedAt.Format("2006-01-02 15:04"),
			)
		}
		w.Flush()
		return nil
	},
}

var snapshotDestroyCmd = &cobra.Command{
	Use:   "destroy <name>",
	Short: "Destroy a snapshot",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		if err := client.DestroySnapshot(args[0]); err != nil {
			return err
		}

		fmt.Printf("Snapshot %q destroyed.\n", args[0])
		return nil
	},
}

var snapshotRestoreCmd = &cobra.Command{
	Use:   "restore <sandbox> <snapshot>",
	Short: "Restore a sandbox from a snapshot",
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		sandbox, err := findSandboxByName(client, args[0])
		if err != nil {
			return err
		}

		// Accept both full image ref (sc-snap-user:name) and just the name
		snapName := args[1]
		if parts := strings.SplitN(snapName, ":", 2); len(parts) == 2 {
			snapName = parts[1]
		}

		sandbox, err = client.RestoreSandbox(sandbox.ID, snapName)
		if err != nil {
			return err
		}

		fmt.Printf("Sandbox %q restored from snapshot %q\n", sandbox.Name, args[1])
		return nil
	},
}
