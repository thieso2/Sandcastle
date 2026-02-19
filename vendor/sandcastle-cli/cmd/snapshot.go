package cmd

import (
	"fmt"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/sandcastle/cli/api"
	"github.com/spf13/cobra"
)

var (
	snapshotLabel    string
	snapshotLayers   string
	snapshotDataSubdir string
	restoreLayers    string
)

func init() {
	rootCmd.AddCommand(snapshotCmd)
	snapshotCmd.AddCommand(snapshotCreateCmd)
	snapshotCmd.AddCommand(snapshotListCmd)
	snapshotCmd.AddCommand(snapshotShowCmd)
	snapshotCmd.AddCommand(snapshotDestroyCmd)
	snapshotCmd.AddCommand(snapshotDeleteCmd)
	snapshotCmd.AddCommand(snapshotRestoreCmd)

	snapshotCreateCmd.Flags().StringVarP(&snapshotLabel, "label", "l", "", "Human-readable description")
	snapshotCreateCmd.Flags().StringVar(&snapshotLayers, "layers", "", "Comma-separated layers: container,home,data,workspace (default: all available)")
	snapshotCreateCmd.Flags().StringVar(&snapshotDataSubdir, "data-subdir", "", "Snapshot only this subdir of the data mount")

	snapshotRestoreCmd.Flags().StringVar(&restoreLayers, "layers", "", "Comma-separated layers to restore (default: all stored layers)")
}

var snapshotCmd = &cobra.Command{
	Use:     "snapshot",
	Aliases: []string{"snap"},
	Short:   "Manage sandbox snapshots",
}

var snapshotCreateCmd = &cobra.Command{
	Use:   "create <sandbox> <name>",
	Short: "Create a composite snapshot of a sandbox",
	Args:  cobra.RangeArgs(1, 2),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		sandbox, err := findSandboxByName(client, args[0])
		if err != nil {
			return err
		}

		var name string
		if len(args) > 1 {
			name = args[1]
		}

		var layers []string
		if snapshotLayers != "" {
			layers = strings.Split(snapshotLayers, ",")
			for i, l := range layers {
				layers[i] = strings.TrimSpace(l)
			}
		}

		req := api.SnapshotRequest{
			Name:       name,
			Label:      snapshotLabel,
			Layers:     layers,
			DataSubdir: snapshotDataSubdir,
		}

		snap, err := client.SnapshotSandbox(sandbox.ID, req)
		if err != nil {
			return err
		}

		fmt.Printf("Snapshot %q created from sandbox %q\n", snap.Name, args[0])
		if len(snap.Layers) > 0 {
			fmt.Printf("Layers:  %s\n", strings.Join(snap.Layers, ", "))
		}
		if snap.DockerImage != "" {
			fmt.Printf("Image:   %s\n", snap.DockerImage)
		} else if snap.Image != "" {
			fmt.Printf("Image:   %s\n", snap.Image)
		}
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
		printServer(client)

		snapshots, err := client.ListSnapshots()
		if err != nil {
			return err
		}

		if len(snapshots) == 0 {
			fmt.Println("No snapshots.")
			return nil
		}

		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "NAME\tSOURCE\tLAYERS\tSIZE\tCREATED")
		for _, s := range snapshots {
			source := s.SourceSandbox
			if source == "" {
				source = s.Sandbox
			}
			if source == "" {
				source = "—"
			}
			layers := strings.Join(s.Layers, " ")
			if layers == "" && s.Image != "" {
				layers = "container"
			}
			size := s.TotalSize
			if size == 0 {
				size = s.Size
			}
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\n",
				s.Name,
				source,
				layers,
				humanBytes(size),
				s.CreatedAt.Format("2006-01-02 15:04"),
			)
		}
		w.Flush()
		return nil
	},
}

var snapshotShowCmd = &cobra.Command{
	Use:   "show <name>",
	Short: "Show details of a snapshot",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		snap, err := client.GetSnapshot(args[0])
		if err != nil {
			return err
		}

		fmt.Printf("Snapshot:       %s\n", snap.Name)
		if snap.Label != "" {
			fmt.Printf("Label:          %s\n", snap.Label)
		}
		source := snap.SourceSandbox
		if source == "" {
			source = snap.Sandbox
		}
		if source != "" {
			fmt.Printf("Source sandbox: %s\n", source)
		}
		fmt.Printf("Created:        %s\n\n", snap.CreatedAt.Format("2006-01-02 15:04:05"))

		if len(snap.Layers) > 0 {
			fmt.Println("Layers:")
			if containsLayer(snap.Layers, "container") {
				img := snap.DockerImage
				if img == "" {
					img = snap.Image
				}
				fmt.Printf("  container    %-50s  %s\n", img, humanBytes(snap.DockerSize))
			}
			if containsLayer(snap.Layers, "home") {
				fmt.Printf("  home         %-50s  %s\n", "(BTRFS snapshot)", humanBytes(snap.HomeSize))
			}
			if containsLayer(snap.Layers, "data") {
				fmt.Printf("  data         %-50s  %s\n", "(BTRFS snapshot)", humanBytes(snap.DataSize))
			}
			total := snap.TotalSize
			if total == 0 {
				total = snap.DockerSize + snap.HomeSize + snap.DataSize
			}
			fmt.Printf("\nTotal:         %s\n", humanBytes(total))
		}

		return nil
	},
}

var snapshotDestroyCmd = &cobra.Command{
	Use:   "destroy <name>",
	Short: "Destroy a snapshot",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return runSnapshotDelete(args[0])
	},
}

// snapshotDeleteCmd is an alias for destroy following the issue spec "snapshot delete"
var snapshotDeleteCmd = &cobra.Command{
	Use:   "delete <name>",
	Short: "Delete a snapshot",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return runSnapshotDelete(args[0])
	},
}

func runSnapshotDelete(name string) error {
	client, err := api.NewClient()
	if err != nil {
		return err
	}
	printServer(client)

	if err := client.DestroySnapshot(name); err != nil {
		return err
	}

	fmt.Printf("Snapshot %q deleted.\n", name)
	return nil
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
		printServer(client)

		sandbox, err := findSandboxByName(client, args[0])
		if err != nil {
			return err
		}

		// Accept both full image ref (sc-snap-user:name) and just the name
		snapName := args[1]
		if parts := strings.SplitN(snapName, ":", 2); len(parts) == 2 {
			snapName = parts[1]
		}

		var layers []string
		if restoreLayers != "" {
			layers = strings.Split(restoreLayers, ",")
			for i, l := range layers {
				layers[i] = strings.TrimSpace(l)
			}
		}

		sandbox, err = client.RestoreSandbox(sandbox.ID, snapName, layers)
		if err != nil {
			return err
		}

		fmt.Printf("Sandbox %q restored from snapshot %q\n", sandbox.Name, args[1])
		return nil
	},
}

func containsLayer(layers []string, layer string) bool {
	for _, l := range layers {
		if l == layer {
			return true
		}
	}
	return false
}

func humanBytes(b int64) string {
	if b == 0 {
		return "—"
	}
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(b)/float64(div), "KMGTPE"[exp])
}
