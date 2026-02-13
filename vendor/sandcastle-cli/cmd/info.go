package cmd

import (
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/sandcastle/cli/api"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(infoCmd)
}

var infoCmd = &cobra.Command{
	Use:   "info",
	Short: "Show server information",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		info, err := client.Info()
		if err != nil {
			return err
		}

		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)

		fmt.Fprintln(w)
		fmt.Fprintf(w, "Version:\t%s\n", info.Version)
		fmt.Fprintf(w, "Rails:\t%s\n", info.Rails)
		fmt.Fprintf(w, "Ruby:\t%s\n", info.Ruby)
		fmt.Fprintf(w, "Docker:\t%s\n", info.Docker.Version)

		fmt.Fprintln(w)
		fmt.Fprintf(w, "Uptime:\t%s\n", info.Host.Uptime)
		fmt.Fprintf(w, "CPUs:\t%d\n", info.Host.CPUCount)
		fmt.Fprintf(w, "Load:\t%.2f / %.2f / %.2f\n", info.Host.Load.One, info.Host.Load.Five, info.Host.Load.Fifteen)

		fmt.Fprintln(w)
		fmt.Fprintf(w, "Memory:\t%.1f / %.1f GB (%.0f%% used)\n", info.Host.Memory.UsedGB, info.Host.Memory.TotalGB, info.Host.Memory.Percent)
		fmt.Fprintf(w, "Disk:\t%.1f / %.1f GB (%.0f%% used)\n", info.Host.Disk.UsedGB, info.Host.Disk.TotalGB, info.Host.Disk.Percent)

		fmt.Fprintln(w)
		fmt.Fprintf(w, "Sandboxes:\t%d running, %d stopped, %d total\n",
			info.Sandboxes["running"], info.Sandboxes["stopped"], info.Sandboxes["total"])
		fmt.Fprintf(w, "Containers:\t%d running, %d total\n",
			info.Docker.ContainersRunning, info.Docker.Containers)
		fmt.Fprintf(w, "Images:\t%d\n", info.Docker.Images)
		fmt.Fprintf(w, "Users:\t%d (%d admins)\n", info.Users.Total, info.Users.Admins)

		w.Flush()
		return nil
	},
}
